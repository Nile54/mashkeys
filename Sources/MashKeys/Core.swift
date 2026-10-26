import Foundation

enum BeatSource: String, CaseIterable {
    case bass, mids, treble, fullMix

    var title: String {
        switch self {
        case .bass: return "Bass / kicks (20–150 Hz)"
        case .mids: return "Mids / vocals (250–2,000 Hz)"
        case .treble: return "Treble / hi-hats (2–16 kHz)"
        case .fullMix: return "Full mix (20 Hz–20 kHz)"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .bass: return 20...150
        case .mids: return 250...2000
        case .treble: return 2000...16000
        case .fullMix: return 20...20000
        }
    }
}

struct ReactionSettings: Equatable {
    let source: BeatSource
    let sensitivity: Double

    init(source: BeatSource = .bass, sensitivity: Double = 0.5) {
        self.source = source
        self.sensitivity = sensitivity.isFinite ? max(0, min(1, sensitivity)) : 0.5
    }

    // Midpoint exactly preserves the previous bass tuning.
    var prominence: Float {
        Float(sensitivity <= 0.5 ? 2.2 - 1.56 * sensitivity : 1.42 - 0.6 * (sensitivity - 0.5))
    }
    var minimumGap: Double { sensitivity <= 0.5 ? 0.42 - 0.56 * sensitivity : 0.14 - 0.08 * (sensitivity - 0.5) }
    var minimumShare: Float { Float(0.10 + (0.5 - sensitivity) * 0.10) }
    var recoveryScale: Double { pow(1.7, (0.5 - sensitivity) * 2) }

    static func load(from defaults: UserDefaults) -> ReactionSettings {
        ReactionSettings(source: BeatSource(rawValue: defaults.string(forKey: "beatSource") ?? "") ?? .bass,
                         sensitivity: defaults.object(forKey: "sensitivity") as? Double ?? 0.5)
    }
}

/// The audio callback takes a tiny snapshot without waiting on the settings UI.
final class ReactionControl {
    private let mutex = NSLock()
    private var value: ReactionSettings
    init(_ value: ReactionSettings = ReactionSettings()) { self.value = value }
    func replace(_ value: ReactionSettings) { mutex.lock(); self.value = value; mutex.unlock() }
    func snapshot(or fallback: ReactionSettings) -> ReactionSettings {
        guard mutex.try() else { return fallback }
        defer { mutex.unlock() }
        return value
    }
}

struct AudioHit {
    let time: Double
    let volume: Float
    let isDrop: Bool
}

/// Eight recent musical crests provide context without recognizing a track.
struct ContrastTracker {
    private var levels: [Float] = []
    private var spacings: [Double] = []
    private var previous: Double?
    private var accentedAt = -Double.infinity

    mutating func accent(level: Float, position: Float, prominence: Float, at time: Double) -> Bool {
        guard level.isFinite, level > 0, time.isFinite else { return false }
        let gap = previous.map { time - $0 }
        defer {
            previous = time
            levels.append(level)
            if levels.count > 8 { levels.removeFirst() }
            if let gap, gap > 0, gap < 10 {
                spacings.append(gap)
                if spacings.count > 8 { spacings.removeFirst() }
            }
        }
        guard levels.count >= 3, time - accentedAt >= 1.5 else { return false }
        let ordered = levels.sorted()
        let usualLevel = ordered[ordered.count / 2]
        let gaps = spacings.sorted()
        let usualGap = gaps.isEmpty ? 0.5 : gaps[gaps.count / 2]
        let lift = level > 1.8 * usualLevel
        let returning = (gap ?? 0) >= max(1, 1.8 * usualGap)
            && position >= 0.75 && prominence > 1.8 && level >= usualLevel * 0.85
        guard lift || returning else { return false }
        accentedAt = time
        levels.removeAll(keepingCapacity: true)
        return true
    }
}

/// Detects crests in the selected frequency-band envelope.
struct BeatDetector {
    var settings = ReactionSettings()
    private var dbHistory = [Float](repeating: 0, count: 512)
    private var historyIndex = 0
    private var historyCount = 0
    private var historyElapsed = 0.0
    private var floorDB: Float = -80
    private var ceilingDB: Float = -60
    private var background: Float = 0
    private var trough: Float = 0
    private var crest: Float = 0
    private var crestShare: Float = 0
    private var rising = false
    private var silence = 0.0
    private var firedAt = -Double.infinity
    private var contrast = ContrastTracker()

    mutating func observe(energy: Float, bandShare: Float, seconds: Double, time: Double) -> AudioHit? {
        guard energy.isFinite, bandShare.isFinite, seconds > 0, time.isFinite else { return nil }
        if energy < 1e-7 {
            silence += seconds
            background = 0; trough = 0; crest = 0; rising = false
            if silence >= 2 { historyCount = 0; historyIndex = 0 }
            return nil
        }
        silence = 0
        historyElapsed += seconds
        if bandShare >= settings.minimumShare * 0.8 && (historyCount == 0 || historyElapsed >= 2048.0 / 44100.0) {
            historyElapsed = 0
            dbHistory[historyIndex % dbHistory.count] = 20 * log10(energy)
            historyIndex += 1
            historyCount = min(historyCount + 1, dbHistory.count)
            if historyCount == 16 || historyIndex % 5 == 0 {
                let sorted = dbHistory.prefix(historyCount).sorted()
                floorDB = sorted[Int(Double(historyCount - 1) * 0.10)]
                ceilingDB = max(floorDB + 8, sorted[Int(Double(historyCount - 1) * 0.98)])
            }
        }
        if background == 0 {
            background = energy * 0.5
            if bandShare >= settings.minimumShare { rising = true; crest = energy; crestShare = bandShare }
        }
        background += Float(1 - exp(-seconds / 0.7)) * (energy - background)
        if rising {
            if energy > crest { crest = energy; crestShare = bandShare }
        } else {
            trough = trough == 0 ? energy : min(trough, energy)
            if energy >= trough * 1.03 { rising = true; crest = energy; crestShare = bandShare }
        }
        guard rising, energy < crest * 0.985 else { return nil }
        rising = false; trough = energy
        let prominence = crest / max(background, 1e-8)
        guard historyCount > 0, crestShare >= settings.minimumShare, prominence > settings.prominence, time - firedAt >= settings.minimumGap else { return nil }
        firedAt = time
        let db = 20 * log10(max(crest, 1e-8))
        let volume: Float = historyCount < 16 ? 0.5 : max(0, min(1, (db - floorDB) / max(8, ceilingDB - floorDB)))
        return AudioHit(time: time, volume: volume,
                       isDrop: contrast.accent(level: crest, position: volume, prominence: prominence, at: time))
    }
}

struct RiseTiming {
    private var last: Double?
    private var gaps: [Double] = []
    private var pace = 0.75

    mutating func duration(for hit: AudioHit, reaction: ReactionSettings = ReactionSettings()) -> Double {
        if let last {
            let gap = hit.time - last
            if gap <= 0 || gap > 3 { gaps.removeAll(keepingCapacity: true); pace = 0.75 }
            else if gap >= 0.09 {
                gaps.append(gap)
                if gaps.count > 5 { gaps.removeFirst() }
                let ordered = gaps.sorted()
                let typical = ordered[ordered.count / 2]
                let spacing = gap < typical ? gap : 0.65 * gap + 0.35 * typical
                let target = max(0.2, min(1.25, spacing * 0.82))
                pace += (target - pace) * (target < pace ? 0.8 : 0.55)
            }
        }
        last = hit.time
        let volume = hit.volume.isFinite ? Double(max(0, min(1, hit.volume))) : 0.5
        let original = max(0.2, min(2.2, 0.12 + max(0, pace * (0.7 + 0.6 * volume) - 0.12) * 1.6))
        return max(0.2, min(2.2, original * reaction.recoveryScale))
    }
}

func smoothRise(elapsed: Double, duration: Double) -> Float {
    let fraction = max(0, min(1, (elapsed - 0.12) / max(0.08, duration - 0.12)))
    return Float(fraction * fraction * (3 - 2 * fraction))
}

/// Unknown audio passes immediately; only recent, confident talking is blocked.
struct SpeechPolicy {
    private var speechAt = -Double.infinity
    private var blocked = false

    mutating func update(music: Double, speech: Double, singing: Double, at now: Double) {
        guard music.isFinite, speech.isFinite, singing.isFinite else { blocked = false; return }
        let musicalVoice = singing >= 0.45
        let musicWins = music >= 0.55 && music >= speech - 0.08
        if musicalVoice || musicWins { blocked = false }
        else if speech >= 0.65 && speech > music + 0.12 {
            speechAt = now; blocked = true
        } else if now - speechAt >= 0.6 { blocked = false }
    }

    func permits(at now: Double) -> Bool { !blocked || now - speechAt >= 0.85 }
    mutating func reset() { self = SpeechPolicy() }
}
