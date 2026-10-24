import Foundation

struct BassHit {
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

/// Measures only the 20–150 Hz envelope supplied by the spectrum analyzer.
struct BassDetector {
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

    mutating func observe(energy: Float, bassShare: Float, seconds: Double, time: Double) -> BassHit? {
        guard energy.isFinite, bassShare.isFinite, seconds > 0, time.isFinite else { return nil }
        if energy < 1e-7 {
            silence += seconds
            background = 0; trough = 0; crest = 0; rising = false
            if silence >= 2 { historyCount = 0; historyIndex = 0 }
            return nil
        }
        silence = 0
        historyElapsed += seconds
        if bassShare >= 0.08 && (historyCount == 0 || historyElapsed >= 2048.0 / 44100.0) {
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
            if bassShare >= 0.10 { rising = true; crest = energy; crestShare = bassShare }
        }
        background += Float(1 - exp(-seconds / 0.7)) * (energy - background)
        if rising {
            if energy > crest { crest = energy; crestShare = bassShare }
        } else {
            trough = trough == 0 ? energy : min(trough, energy)
            if energy >= trough * 1.03 { rising = true; crest = energy; crestShare = bassShare }
        }
        guard rising, energy < crest * 0.985 else { return nil }
        rising = false; trough = energy
        let prominence = crest / max(background, 1e-8)
        guard historyCount > 0, crestShare >= 0.10, prominence > 1.42, time - firedAt >= 0.14 else { return nil }
        firedAt = time
        let db = 20 * log10(max(crest, 1e-8))
        let volume: Float = historyCount < 16 ? 0.5 : max(0, min(1, (db - floorDB) / max(8, ceilingDB - floorDB)))
        return BassHit(time: time, volume: volume,
                       isDrop: contrast.accent(level: crest, position: volume, prominence: prominence, at: time))
    }
}

struct RiseTiming {
    private var last: Double?
    private var gaps: [Double] = []
    private var pace = 0.75

    mutating func duration(for hit: BassHit) -> Double {
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
        return max(0.2, min(2.2, 0.12 + max(0, pace * (0.7 + 0.6 * volume) - 0.12) * 1.6))
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
