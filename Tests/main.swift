import Foundation

func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

var speech = SpeechPolicy()
require(speech.permits(at: 0), "Unknown first-play audio must pass without a music label")
speech.update(music: 0.3, speech: 0.95, singing: 0.1, at: 0)
require(!speech.permits(at: 0.1), "Confirmed talking should suppress lights")
speech.update(music: 0.3, speech: 0.3, singing: 0.1, at: 0.3)
require(!speech.permits(at: 0.3), "A short uncertain speech window should not cause flicker")
speech.update(music: 0.3, speech: 0.3, singing: 0.1, at: 0.7)
require(speech.permits(at: 0.7), "Unrecognized music after speech must not remain locked out")
speech.update(music: 0.2, speech: 0.98, singing: 0, at: 1)
speech.update(music: 0.4, speech: 0.9, singing: 0.8, at: 1.1)
require(speech.permits(at: 1.1), "Singing/rap must override speech-like confidence")
speech.update(music: 0.2, speech: 0.95, singing: 0, at: 2)
require(speech.permits(at: 3), "A stale classifier must not force a replay")

func settled(_ spacing: Double, _ volume: Float) -> Double {
    var timing = RiseTiming()
    var duration = 0.0
    for i in 0..<12 { duration = timing.duration(for: AudioHit(time: Double(i) * spacing, volume: volume, isDrop: false)) }
    return duration
}
require(settled(0.3, 0.5) < settled(1, 0.5) / 2, "Tempo must change recovery speed")
require(settled(0.6, 0.95) > settled(0.6, 0.15) * 1.5, "Volume must change recovery speed")
require(abs(settled(2, 1) - 2.2) < 0.001, "Long recovery range must be preserved")
for duration in [0.2, 0.4, 1.128, 2.2] {
    var previous: Float = 0
    for i in 0...1000 {
        let value = smoothRise(elapsed: duration * Double(i) / 1000, duration: duration)
        require(value >= previous && value <= 1, "Recovery must be smooth and bounded")
        previous = value
    }
    require(smoothRise(elapsed: 0, duration: duration) == 0 && previous == 1, "Every pulse must span 0–100")
}

var contrast = ContrastTracker()
for i in 0..<10 { require(!contrast.accent(level: 0.1, position: 0.8, prominence: 2, at: Double(i) * 0.6), "Regular beat is not a drop") }
require(contrast.accent(level: 0.4, position: 1, prominence: 3, at: 6), "Loud lift should accent")
for i in 1..<10 { require(!contrast.accent(level: 0.4, position: 1, prominence: 2, at: 6 + Double(i) * 0.6), "Loud section should establish a new baseline") }
var sparse = ContrastTracker()
for i in 0..<12 { require(!sparse.accent(level: 0.1, position: 0.9, prominence: 2, at: Double(i) * 1.1), "Sparse steady kicks are not repeated drops") }

func synthesize(frequency: Double, length: Double = 1, sections: Bool = false) -> [Float] {
    let rate = 44100.0
    return (0..<Int(rate * length)).map { index in
        let t = Double(index) / rate
        var amplitude = sections ? 0.004 : (t < 0.18 ? 0.4 * (1 - exp(-t / 0.002)) * exp(-t / 0.045) : 0)
        if sections {
            for kick in 0..<18 {
                let dt = t - (1 + Double(kick) * 0.6)
                if dt >= 0 && dt < 0.4 { amplitude += (kick < 8 ? 0.08 : 0.32) * (1 - exp(-dt / 0.002)) * exp(-dt / 0.07) }
            }
        }
        return Float(amplitude * sin(2 * .pi * frequency * t))
    }
}

func detect(_ samples: [Float], frames: Int = 512, gain: Float = 1, settings: ReactionSettings = ReactionSettings()) -> [AudioHit] {
    let analyzer = AudioSpectrum(sampleRate: 44100, settings: settings)
    var hits: [AudioHit] = []
    var scaled = samples.map { $0 * gain }
    scaled.withUnsafeMutableBufferPointer { pointer in
        var offset = 0
        while offset < pointer.count {
            let count = min(frames, pointer.count - offset)
            analyzer.consume(pointer.baseAddress!.advanced(by: offset), frames: count,
                             endingAt: Double(offset + count) / 44100) { hits.append($0) }
            offset += count
        }
    }
    return hits
}

let first = detect(synthesize(frequency: 80))
require(first.count == 1 && first[0].time < 0.2, "An isolated first kick must work without history")
require(detect(synthesize(frequency: 1000)).isEmpty, "Midrange must not trigger Bass mode")
require(detect(synthesize(frequency: 5000)).isEmpty, "Treble must not trigger Bass mode")
require(detect([Float](repeating: 0, count: 44100)).isEmpty, "Silence must not trigger")
let song = synthesize(frequency: 80, length: 12.5, sections: true)
let reference = detect(song)
for frames in [256, 1000, 4096] { require(detect(song, frames: frames).count == 18, "All input samples must be consumed") }
let quiet = detect(song, gain: 0.05)
require(reference.count == 18 && quiet.count == 18, "Normal and low volume should detect the same kicks")
require(reference.filter(\.isDrop).count == 1 && quiet.filter(\.isDrop).count == 1, "Accent the step once")
for (a, b) in zip(reference, quiet) {
    require(abs(a.time - b.time) < 0.0001 && abs(a.volume - b.volume) < 0.01 && a.isDrop == b.isDrop, "Relative response must be gain independent")
}

// Isolated carriers select the intended band; full mix accepts all three.
for (source, carrier) in [(BeatSource.bass, 80.0), (.mids, 1000.0), (.treble, 5000.0)] {
    let settings = ReactionSettings(source: source)
    require(!detect(synthesize(frequency: carrier), settings: settings).isEmpty, "Selected band must react on first play: \(source)")
    for other in [80.0, 1000.0, 5000.0] where other != carrier {
        require(detect(synthesize(frequency: other), settings: settings).isEmpty, "Selected band must reject other carriers: \(source), \(other)")
    }
    require(!detect(synthesize(frequency: carrier), settings: ReactionSettings(source: .fullMix)).isEmpty, "Full mix must include each carrier")
}
for source in BeatSource.allCases {
    for sensitivity in [0.0, 0.5, 1.0] {
        require(detect([Float](repeating: 0, count: 44100), settings: ReactionSettings(source: source, sensitivity: sensitivity)).isEmpty, "Sensitivity must never turn silence into beats")
    }
}

// A steady background plus modest and strong crests exposes the sensitivity range.
let textured: [Float] = (0..<Int(44100 * 9)).map { i in
    let t = Double(i) / 44100
    var amplitude = 0.10
    for beat in 0..<20 {
        let dt = t - (0.5 + Double(beat) * 0.4)
        if dt >= 0 && dt < 0.25 { amplitude += (beat % 4 == 0 ? 0.28 : 0.045) * exp(-dt / 0.06) }
    }
    return Float(amplitude * sin(2 * .pi * 80 * t))
}
let sparseHits = detect(textured, settings: ReactionSettings(sensitivity: 0))
let normalHits = detect(textured)
let frequentHits = detect(textured, settings: ReactionSettings(sensitivity: 1))
require(sparseHits.count < frequentHits.count, "Higher sensitivity must detect more modest hits (\(sparseHits.count) vs \(frequentHits.count))")
require(sparseHits.count <= normalHits.count && normalHits.count <= frequentHits.count, "Sensitivity should increase hit counts across the slider")
var lowTiming = RiseTiming(), highTiming = RiseTiming()
let testHit = AudioHit(time: 0, volume: 0.5, isDrop: false)
require(highTiming.duration(for: testHit, reaction: ReactionSettings(sensitivity: 1)) < lowTiming.duration(for: testHit, reaction: ReactionSettings(sensitivity: 0)), "Higher sensitivity should also permit more visible pulses through a shorter smooth recovery")

// Changing source on the running analyzer must take effect without rebuilding capture.
let liveSpectrum = AudioSpectrum(sampleRate: 44100)
var liveHits = 0
let midKick = synthesize(frequency: 1000)
midKick.withUnsafeBufferPointer { liveSpectrum.consume($0.baseAddress!, frames: $0.count, endingAt: 1) { _ in liveHits += 1 } }
require(liveHits == 0, "Bass should reject the midrange test before switching")
liveSpectrum.configure(ReactionSettings(source: .mids))
midKick.withUnsafeBufferPointer { liveSpectrum.consume($0.baseAddress!, frames: $0.count, endingAt: 2) { _ in liveHits += 1 } }
require(liveHits > 0, "Live source changes should start detecting the new band immediately")

// Song sync uses measured band envelopes rather than requiring a song file/name.
func syncSamples(_ pcm: [Float], source: BeatSource = .bass) -> [SongSyncSample] {
    let spectrum = AudioSpectrum(sampleRate: 44100, settings: ReactionSettings(source: source))
    var samples: [SongSyncSample] = []
    pcm.withUnsafeBufferPointer { pointer in
        var offset = 0
        while offset < pointer.count {
            let count = min(512, pointer.count - offset)
            spectrum.consume(pointer.baseAddress!.advanced(by: offset), frames: count, endingAt: Double(offset + count) / 44100,
                             onFrame: { samples.append(SongSyncSample(frame: $0, allowed: true)) }) { _ in }
            offset += count
        }
    }
    return samples
}
let clearSyncFrames = syncSamples(Array(song.prefix(44100 * 9)))
let softSyncFrames = syncSamples(textured)
let clearSync = try SongSensitivityTuner.recommend(clearSyncFrames, source: .bass)
let softSync = try SongSensitivityTuner.recommend(softSyncFrames, source: .bass)
let quietSyncFrames = softSyncFrames.map { sample in
    let f = sample.frame
    return SongSyncSample(frame: SpectrumFrame(energy: f.energy * 0.02, share: f.share, seconds: f.seconds, time: f.time), allowed: true)
}
let quietSync = try SongSensitivityTuner.recommend(quietSyncFrames, source: .bass)
require(quietSync.sensitivity == softSync.sensitivity, "Sync should follow relative rhythm, not playback gain")
require(clearSync.sensitivity >= 0 && clearSync.sensitivity <= 1 && softSync.visiblePulses >= 3, "Sync must suggest a usable bounded setting")
require(clearSync.sensitivity != softSync.sensitivity, "Different accent structure should not always return a fixed percentage")
for (source, frequency) in [(BeatSource.mids, 1000.0), (.treble, 5000.0), (.fullMix, 1000.0)] {
    let result = try SongSensitivityTuner.recommend(syncSamples(synthesize(frequency: frequency, length: 9, sections: true), source: source), source: source)
    require(result.visiblePulses >= 3, "Sync must honor every available beat source")
}
func cannotSync(_ frames: [SongSyncSample], _ message: String) {
    do { _ = try SongSensitivityTuner.recommend(frames, source: .bass); fatalError(message) }
    catch is SongSyncError { }
    catch { fatalError("Unexpected sync failure: \(error)") }
}
cannotSync(syncSamples([Float](repeating: 0, count: 44100 * 9)), "Silence must not change sensitivity")
cannotSync(softSyncFrames.map { SongSyncSample(frame: $0.frame, allowed: false) }, "Filtered speech must not calibrate lights")
cannotSync(Array(softSyncFrames.prefix(100)), "Insufficient music must not produce a pretend sync")
let constantTone = (0..<44100 * 9).map { Float(0.1 * sin(2 * .pi * 80 * Double($0) / 44100)) }
cannotSync(syncSamples(constantTone), "A steady tone without rhythmic changes must not produce a pretend sync")

let coordinator = SongSyncCoordinator()
var synced: SongSyncRecommendation?
coordinator.begin(source: .bass) { result in
    require(Thread.isMainThread, "Saved sensitivity must be delivered on the UI thread")
    synced = result
}
for sample in softSyncFrames { coordinator.observe(sample.frame, allowed: sample.allowed) }
let syncDeadline = Date().addingTimeInterval(3)
while synced == nil && Date() < syncDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
require(synced?.sensitivity == softSync.sensitivity, "Coordinator must apply the measured recommendation")
require(!coordinator.status.isBusy, "Successful sync must finish its progress state")

// Cancelled/obsolete analysis must never overwrite the manual slider or a new sync.
let heldWorker = DispatchQueue(label: "MashKeys.tests.sync-cancel")
heldWorker.suspend()
let cancelledSync = SongSyncCoordinator(worker: heldWorker)
var staleApplications = 0
cancelledSync.begin(source: .bass) { _ in staleApplications += 1 }
for sample in softSyncFrames { cancelledSync.observe(sample.frame, allowed: true) }
require(cancelledSync.status == .analysing, "Full sample should enter background analysis")
cancelledSync.cancel()
heldWorker.resume(); heldWorker.sync { }
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
require(staleApplications == 0 && !cancelledSync.status.isBusy, "Cancelling analysis must discard its queued result")
cancelledSync.begin(source: .bass, at: 100) { _ in staleApplications += 1 }
_ = cancelledSync.poll(at: 115)
require(!cancelledSync.status.isBusy && staleApplications == 0, "Missing audio callbacks must time out without applying a setting")
print("PASS: song sync for clear/soft tracks (\(Int(clearSync.sensitivity * 100))%/\(Int(softSync.sensitivity * 100))%), gain invariance, sources, silence/speech/tone rejection, completion, cancellation and timeout")

// Auto-sync watches the live envelope without browser metadata or a timer that
// blindly recalibrates silence. A quiet boundary re-arms it; gapless audio gets
// bounded periodic refreshes instead of pretending every track is identifiable.
func feedAutomatic(_ policy: inout AutomaticSyncPolicy, loops: Int = 1, from start: Double = 0, allowed: Bool = true) -> [Double] {
    var requests: [Double] = []
    for loop in 0..<loops {
        for sample in softSyncFrames {
            let f = sample.frame
            let shifted = SpectrumFrame(energy: f.energy, share: f.share, seconds: f.seconds, time: f.time + start + Double(loop) * 9)
            if policy.observe(shifted, allowed: allowed, busy: false) { requests.append(shifted.time) }
        }
    }
    return requests
}
func quietAutomatic(_ policy: inout AutomaticSyncPolicy, at time: Double) {
    for i in 0..<500 {
        _ = policy.observe(SpectrumFrame(energy: 0, share: 0, seconds: 0.005, time: time + Double(i) * 0.005), allowed: true, busy: false)
    }
}
var automatic = AutomaticSyncPolicy()
automatic.reset(enabled: true)
let automaticTimes = feedAutomatic(&automatic, loops: 9)
require(automaticTimes.count == 2 && automaticTimes[1] - automaticTimes[0] >= 60, "Music starts should sync once, with bounded gapless refresh")
quietAutomatic(&automatic, at: 81)
require(feedAutomatic(&automatic, from: 84).count == 1, "Music after a quiet gap must automatically sync again")
automatic.holdForCurrentMusic()
require(feedAutomatic(&automatic, loops: 9, from: 93).isEmpty, "Manual tuning should hold against periodic auto-sync for this playback")
quietAutomatic(&automatic, at: 174)
require(feedAutomatic(&automatic, from: 177).count == 1, "Auto-sync should resume after the next quiet playback boundary")
var disabledAuto = AutomaticSyncPolicy()
require(feedAutomatic(&disabledAuto).isEmpty, "Auto-sync off must leave manual tuning alone")
disabledAuto.reset(enabled: true)
require(feedAutomatic(&disabledAuto, allowed: false).isEmpty, "Filtered speech must not trigger auto-sync")
quietAutomatic(&disabledAuto, at: 9)
require(feedAutomatic(&disabledAuto, from: 12).count == 1, "Music must still trigger after filtered speech or silence")

let autoCoordinator = SongSyncCoordinator()
var automaticRequests = 0
var automaticResult: SongSyncRecommendation?
autoCoordinator.configureAutomatic(true) { [weak autoCoordinator] in
    automaticRequests += 1
    autoCoordinator?.begin(source: .bass, automatic: true) { automaticResult = $0 }
}
for sample in softSyncFrames.prefix(600) { autoCoordinator.observe(sample.frame, allowed: true) }
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
require(automaticRequests == 1 && autoCoordinator.status.isBusy, "Automatic request must start the same sync on the main queue")
for sample in softSyncFrames {
    let f = sample.frame
    autoCoordinator.observe(SpectrumFrame(energy: f.energy, share: f.share, seconds: f.seconds, time: f.time + 4), allowed: true)
}
let automaticDeadline = Date().addingTimeInterval(3)
while automaticResult == nil && Date() < automaticDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
require(automaticResult != nil && automaticRequests == 1, "Automatic sync should complete without a button click or duplicate request")
let offBeforeDelivery = SongSyncCoordinator()
var disabledRequests = 0
offBeforeDelivery.configureAutomatic(true) { disabledRequests += 1 }
for sample in softSyncFrames { offBeforeDelivery.observe(sample.frame, allowed: true) }
offBeforeDelivery.configureAutomatic(false) { disabledRequests += 1 }
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
require(disabledRequests == 0, "Turning auto-sync off must invalidate a queued automatic request")
let manualWorker = DispatchQueue(label: "MashKeys.tests.manual-before-auto")
manualWorker.suspend()
let manualBeforeAuto = SongSyncCoordinator(worker: manualWorker)
var manualDone = false, duplicateAutomaticRequests = 0
manualBeforeAuto.begin(source: .bass) { _ in manualDone = true }
manualBeforeAuto.configureAutomatic(true) { duplicateAutomaticRequests += 1 }
for sample in softSyncFrames { manualBeforeAuto.observe(sample.frame, allowed: true) }
manualWorker.resume(); manualWorker.sync { }
let manualDeadline = Date().addingTimeInterval(3)
while !manualDone && Date() < manualDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
require(manualDone, "Manual sync must finish even if auto-sync was enabled during sampling")
for sample in softSyncFrames {
    let f = sample.frame
    manualBeforeAuto.observe(SpectrumFrame(energy: f.energy, share: f.share, seconds: f.seconds, time: f.time + 9), allowed: true)
}
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
require(duplicateAutomaticRequests == 0, "Enabling auto during manual sync must not immediately override its result")
var idleManualHold = AutomaticSyncPolicy(); idleManualHold.reset(enabled: true)
idleManualHold.holdForCurrentMusic(); quietAutomatic(&idleManualHold, at: 0)
require(feedAutomatic(&idleManualHold, from: 3).count == 1, "Quiet must release a manual hold even if no previous session was observed")
print("PASS: automatic music starts, quiet-gap rearming, gapless refresh, manual hold, speech exclusion, automatic completion and disable race")

// Regression: even a persisted connected-tabs setting from older releases must
// leave Chrome in the normal system mix, without any browser helper.
let suite = "io.github.Nile54.MashKeys.tests." + UUID().uuidString
let preferences = UserDefaults(suiteName: suite)!
preferences.set(true, forKey: "websiteFilteringEnabled")
preferences.set(["instagram.com", "x.com"], forKey: "blockedWebsites")
preferences.set(["com.apple.Music"], forKey: "blockedApplications")
var rules = RuleSnapshot.load(from: preferences)
require(rules.speech, "Speech protection defaults on")
require(rules.captureExclusions == ["com.apple.Music"], "Old website mode must not exclude Chrome or any other browser")
require(rules.blocks(application: "com.apple.Music.helper"), "App helper processes must be excluded too")
preferences.set(["com.google.Chrome"], forKey: "blockedApplications")
preferences.set(false, forKey: "speechProtection")
rules = RuleSnapshot.load(from: preferences)
require(rules.captureExclusions == ["com.google.Chrome"] && !rules.speech, "Explicit whole-app exclusions and speech setting must remain effective")
preferences.set(true, forKey: "autoSyncMusic")
require(RuleSnapshot.load(from: preferences).autoSync, "Auto-sync preference must survive loading")
preferences.set("treble", forKey: "beatSource")
preferences.set(0.8, forKey: "sensitivity")
require(RuleSnapshot.load(from: preferences).reaction == ReactionSettings(source: .treble, sensitivity: 0.8), "Source and sensitivity must survive preference loading")
preferences.set("invalid", forKey: "beatSource")
preferences.set(900, forKey: "sensitivity")
require(ReactionSettings.load(from: preferences) == ReactionSettings(sensitivity: 1), "Invalid preferences must use a valid source and bounded sensitivity")
preferences.removePersistentDomain(forName: suite)
print("PASS: speech guard, vocals/rap, stale recovery, full-range adaptive rise, first-play bass, live drops, gains, frame sizes, extension-free capture rules, frequency sources and sensitivity (\(sparseHits.count)/\(normalHits.count)/\(frequentHits.count) hits)")
