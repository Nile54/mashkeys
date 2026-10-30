import Foundation

struct SpectrumFrame {
    let energy: Float
    let share: Float
    let seconds: Double
    let time: Double
}

struct SongSyncSample {
    let frame: SpectrumFrame
    let allowed: Bool
}

struct SongSyncRecommendation {
    let sensitivity: Double
    let audibleSeconds: Double
    let visiblePulses: Int
}

enum SongSyncError: String, Error {
    case insufficientAudio = "Not enough music in this beat source. Play a stronger section and try again."
    case noRhythm = "No clear rhythm yet. Keep your setting, or sync during a beat-heavy section."
}

/// Replays only short-lived spectral measurements, never PCM, against the same
/// detector and recovery timing used by live lighting. This is a visual tuning
/// heuristic for the sampled section, not song recognition or a BPM guarantee.
enum SongSensitivityTuner {
    static func recommend(_ samples: [SongSyncSample], source: BeatSource) throws -> SongSyncRecommendation {
        let usable = samples.filter {
            $0.allowed && $0.frame.energy.isFinite && $0.frame.energy >= 1e-7 &&
            $0.frame.share.isFinite && $0.frame.share >= 0.04 &&
            $0.frame.seconds > 0 && $0.frame.seconds.isFinite && $0.frame.time.isFinite
        }
        let audible = usable.reduce(0.0) { $0 + $1.frame.seconds }
        guard audible >= 3 else { throw SongSyncError.insufficientAudio }
        let levels = usable.map { $0.frame.energy }.sorted()
        guard levels[Int(Double(levels.count - 1) * 0.90)] > levels[Int(Double(levels.count - 1) * 0.10)] * 1.12 else {
            throw SongSyncError.noRhythm
        }

        func hits(at sensitivity: Double) -> [AudioHit] {
            var detector = BeatDetector()
            detector.settings = ReactionSettings(source: source, sensitivity: sensitivity)
            var found: [AudioHit] = []
            for sample in samples {
                let f = sample.frame
                guard f.seconds.isFinite, f.seconds > 0 else { continue }
                // Excluded speech must not establish a rhythm or volume baseline.
                let energy: Float = sample.allowed ? f.energy : 0
                if let hit = detector.observe(energy: energy, bandShare: sample.allowed ? f.share : 0,
                                              seconds: f.seconds, time: f.time) { found.append(hit) }
            }
            return found
        }
        let probe = hits(at: 1)
        guard probe.count >= 4 else { throw SongSyncError.noRhythm }
        let gaps = zip(probe.dropFirst(), probe).map { $0.time - $1.time }.filter { $0 >= 0.10 && $0 <= 2 }.sorted()
        guard gaps.count >= 3 else { throw SongSyncError.noRhythm }
        let spacing = max(0.25, min(1.5, gaps[gaps.count / 2]))
        // Leave room for full fades instead of forcing a flash on every crest.
        let targetRate = max(0.55, min(1.8, 1 / (spacing * 1.8)))
        let anchors = hits(at: 0.3)
        var best: (score: Double, result: SongSyncRecommendation)?

        for step in 0...20 {
            let sensitivity = Double(step) / 20
            let settings = ReactionSettings(source: source, sensitivity: sensitivity)
            let detected = step == 20 ? probe : hits(at: sensitivity)
            guard detected.count >= 3 else { continue }
            var timing = RiseTiming(), endsAt = -Double.infinity
            var visible = 0, interrupted = 0
            for hit in detected {
                let duration = timing.duration(for: hit, reaction: settings)
                if hit.time >= endsAt || hit.isDrop {
                    if hit.time < endsAt { interrupted += 1 }
                    visible += 1; endsAt = hit.time + duration
                }
            }
            let rate = Double(visible) / audible
            let missed = anchors.isEmpty ? 0 : Double(anchors.filter { anchor in
                !detected.contains { abs($0.time - anchor.time) < 0.03 }
            }.count) / Double(anchors.count)
            let skipped = 1 - Double(visible) / Double(detected.count)
            let score = 2 * abs(log((rate + 0.1) / (targetRate + 0.1))) + 1.5 * missed + 0.2 * skipped +
                0.15 * Double(interrupted) / Double(detected.count) + 0.08 * abs(sensitivity - 0.5)
            let result = SongSyncRecommendation(sensitivity: sensitivity, audibleSeconds: audible, visiblePulses: visible)
            if best == nil || score < best!.score { best = (score, result) }
        }
        guard let best else { throw SongSyncError.noRhythm }
        return best.result
    }
}

enum SongSyncStatus: Equatable {
    case ready
    case listening(Double)
    case analysing
    case finished(Int)
    case message(String)

    var isBusy: Bool {
        switch self { case .listening, .analysing: return true; default: return false }
    }
}

/// Audio-only playback-boundary heuristic. Quiet gaps re-arm it, and continuous
/// music is rechecked about once a minute for gapless playlists. It does not read
/// browser tabs or track metadata. A manual edit holds automation until a gap.
struct AutomaticSyncPolicy {
    private(set) var enabled = false
    private var armed = true
    private var manualHold = false
    private var quietSeconds = 0.0
    private var activeSeconds = 0.0
    private var sessionStart: Double?
    private var peaks: [Double] = []
    private var lastRequest = -Double.infinity
    private var probe = BeatDetector()

    mutating func reset(enabled: Bool) {
        self = AutomaticSyncPolicy(); self.enabled = enabled
        probe.settings = ReactionSettings(sensitivity: 1)
    }

    mutating func holdForCurrentMusic() { manualHold = true; armed = false }

    mutating func observe(_ frame: SpectrumFrame, allowed: Bool, busy: Bool) -> Bool {
        guard enabled else { return false }
        let usable = allowed && frame.energy >= 1e-7 && frame.share >= 0.04
        if !usable {
            quietSeconds += frame.seconds
            if quietSeconds >= 2 && (sessionStart != nil || manualHold) {
                sessionStart = nil; activeSeconds = 0; peaks = []
                armed = true; manualHold = false
                probe = BeatDetector(); probe.settings = ReactionSettings(sensitivity: 1)
            }
            return false
        }
        quietSeconds = 0
        if sessionStart == nil { sessionStart = frame.time }
        activeSeconds = min(4, activeSeconds + frame.seconds)
        if let hit = probe.observe(energy: frame.energy, bandShare: frame.share, seconds: frame.seconds, time: frame.time) {
            peaks.append(hit.time)
        }
        peaks.removeAll { frame.time - $0 > 8 }
        if peaks.count > 16 { peaks.removeFirst(peaks.count - 16) }
        guard !busy, !manualHold, activeSeconds >= 0.3,
              frame.time - (sessionStart ?? frame.time) >= 1, peaks.count >= 2,
              frame.time - lastRequest >= 12,
              armed || frame.time - lastRequest >= 60 else { return false }
        armed = false; lastRequest = frame.time
        return true
    }
}

/// The callback only appends bounded spectral frames using a non-blocking lock.
/// Candidate replay happens on a worker; results are delivered on the main queue
/// only if the request is still current. Cancellation never changes sensitivity.
final class SongSyncCoordinator {
    static let duration = 8.0
    private let mutex = NSLock()
    private let worker: DispatchQueue
    private var phase: SongSyncStatus = .ready
    private var generation: UInt64 = 0
    private var startedAt = 0.0
    private var received = 0.0
    private var source: BeatSource = .bass
    private var samples: [SongSyncSample] = []
    private var completion: ((SongSyncRecommendation) -> Void)?
    private var automation = AutomaticSyncPolicy()
    private var automaticGeneration: UInt64 = 0
    private var automaticPending = false
    private var automaticRequest: (() -> Void)?
    private var isAutomaticRequest = false

    init(worker: DispatchQueue = DispatchQueue(label: "io.github.Nile54.MashKeys.song-sync", qos: .userInitiated)) {
        self.worker = worker
    }

    var status: SongSyncStatus { mutex.lock(); defer { mutex.unlock() }; return phase }

    func begin(source: BeatSource, automatic: Bool = false, at now: Double = ProcessInfo.processInfo.systemUptime,
               completion: @escaping (SongSyncRecommendation) -> Void) {
        mutex.lock(); defer { mutex.unlock() }
        generation &+= 1; self.source = source; self.completion = completion
        isAutomaticRequest = automatic
        automaticGeneration &+= 1; automaticPending = false
        if !automatic { automation.holdForCurrentMusic() }
        samples = []; samples.reserveCapacity(8192)
        received = 0; startedAt = now; phase = .listening(0)
    }

    func configureAutomatic(_ enabled: Bool, rearm: Bool = false, request: @escaping () -> Void) {
        mutex.lock(); defer { mutex.unlock() }
        automaticRequest = request
        if enabled != automation.enabled || rearm {
            automaticGeneration &+= 1; automaticPending = false
            automation.reset(enabled: enabled)
            if phase.isBusy && !isAutomaticRequest { automation.holdForCurrentMusic() }
        }
        if !enabled && phase.isBusy && isAutomaticRequest {
            generation &+= 1; phase = .message("Auto-sync off. Sensitivity unchanged.")
            samples = []; completion = nil
        }
    }

    func holdAutomaticForCurrentMusic() {
        mutex.lock(); defer { mutex.unlock() }
        automaticGeneration &+= 1; automaticPending = false
        automation.holdForCurrentMusic()
    }

    func reset() {
        mutex.lock(); defer { mutex.unlock() }
        generation &+= 1; phase = .ready; samples = []; completion = nil
        automaticGeneration &+= 1; automaticPending = false
    }

    func cancel(_ message: String = "Sync cancelled. Sensitivity unchanged.", holdAutomatic: Bool = false, rearmAutomatic: Bool = false) {
        mutex.lock(); defer { mutex.unlock() }
        automaticGeneration &+= 1; automaticPending = false
        if rearmAutomatic { automation.reset(enabled: automation.enabled) }
        if holdAutomatic { automation.holdForCurrentMusic() }
        guard phase.isBusy else { return }
        generation &+= 1; phase = .message(message); samples = []; completion = nil
    }

    @discardableResult func poll(at now: Double = ProcessInfo.processInfo.systemUptime) -> SongSyncStatus {
        mutex.lock(); defer { mutex.unlock() }
        if phase.isBusy && now - startedAt >= 14 {
            generation &+= 1; phase = .message("No usable audio received. Check playback and try again.")
            samples = []; completion = nil
        }
        return phase
    }

    func observe(_ frame: SpectrumFrame, allowed: Bool) {
        guard frame.seconds.isFinite, frame.seconds > 0, frame.time.isFinite,
              frame.energy.isFinite, frame.energy >= 0, frame.share.isFinite, frame.share >= 0 else { return }
        guard mutex.try() else { return }
        if automation.observe(frame, allowed: allowed, busy: phase.isBusy || automaticPending) {
            automaticPending = true
            let ticket = automaticGeneration
            DispatchQueue.main.async { [weak self] in self?.requestAutomatic(ticket: ticket) }
        }
        guard case .listening = phase else { mutex.unlock(); return }
        guard samples.count < 8192 else {
            generation &+= 1; phase = .message("Audio rate is too high for sync. Sensitivity unchanged.")
            samples = []; completion = nil; mutex.unlock(); return
        }
        samples.append(SongSyncSample(frame: frame, allowed: allowed))
        received += frame.seconds
        guard received >= Self.duration else {
            phase = .listening(min(1, received / Self.duration)); mutex.unlock(); return
        }
        let captured = samples, source = self.source, ticket = generation
        samples = []; phase = .analysing
        mutex.unlock()
        worker.async { [weak self] in
            let result = Result { try SongSensitivityTuner.recommend(captured, source: source) }
            DispatchQueue.main.async { [weak self] in self?.finish(result, ticket: ticket) }
        }
    }

    private func requestAutomatic(ticket: UInt64) {
        mutex.lock()
        guard automaticGeneration == ticket, automation.enabled, automaticPending, !phase.isBusy else {
            mutex.unlock(); return
        }
        automaticPending = false
        let callback = automaticRequest
        mutex.unlock(); callback?()
    }

    private func finish(_ result: Result<SongSyncRecommendation, Error>, ticket: UInt64) {
        mutex.lock()
        guard ticket == generation, phase == .analysing else { mutex.unlock(); return }
        let callback = completion; completion = nil
        switch result {
        case .success(let recommendation):
            phase = .finished(Int((recommendation.sensitivity * 100).rounded()))
            mutex.unlock(); callback?(recommendation)
        case .failure(let error):
            phase = .message((error as? SongSyncError)?.rawValue ?? "Could not sync. Sensitivity unchanged.")
            mutex.unlock()
        }
    }
}
