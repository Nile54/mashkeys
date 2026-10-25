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
    for i in 0..<12 { duration = timing.duration(for: BassHit(time: Double(i) * spacing, volume: volume, isDrop: false)) }
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

func detect(_ samples: [Float], frames: Int = 512, gain: Float = 1) -> [BassHit] {
    let analyzer = BassSpectrum(sampleRate: 44100)
    var hits: [BassHit] = []
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
preferences.removePersistentDomain(forName: suite)
print("PASS: speech guard, vocals/rap, stale recovery, full-range adaptive rise, first-play bass, live drops, gains, frame sizes and extension-free capture rules")
