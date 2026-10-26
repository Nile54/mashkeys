import Foundation

/// Main-thread animation: full-depth dips, smooth adaptive recovery, drop interruption.
final class LightAnimator {
    private let keyboard: KeyboardBacklight
    private var cadence = RiseTiming()
    private var reaction = ReactionSettings()
    private var frameTimer: DispatchSourceTimer?
    private var generation: UInt64 = 0
    private var owner: String?

    init(keyboard: KeyboardBacklight) { self.keyboard = keyboard }

    func begin() throws { cadence = RiseTiming(); try keyboard.takeControl() }

    func configure(_ settings: ReactionSettings) {
        if settings.source != reaction.source { cadence = RiseTiming() }
        reaction = settings
    }

    func react(to hit: AudioHit, source: String = "system") {
        let duration = cadence.duration(for: hit, reaction: reaction)
        guard frameTimer == nil || hit.isDrop else { return }
        cancelFrames()
        owner = source
        _ = keyboard.set(0)
        animate(seconds: duration) { elapsed in smoothRise(elapsed: elapsed, duration: duration) }
    }

    func speechBegan(source: String = "system") {
        guard owner == source else { return }
        cancelFrames()
        cadence = RiseTiming()
        let start = keyboard.brightness
        animate(seconds: 0.25) { elapsed in
            let t = Float(min(1, max(0, elapsed / 0.25)))
            return start + (1 - start) * t * t * (3 - 2 * t)
        }
    }

    func stop() { cancelFrames(); owner = nil; keyboard.restore() }

    private func cancelFrames() { generation &+= 1; frameTimer?.cancel(); frameTimer = nil }

    private func animate(seconds: Double, value: @escaping (Double) -> Float) {
        let ticket = generation
        let start = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: .main)
        frameTimer = timer
        timer.schedule(deadline: .now(), repeating: 1.0 / 60, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, ticket == self.generation else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            _ = self.keyboard.set(value(elapsed))
            if elapsed >= seconds { self.frameTimer?.cancel(); self.frameTimer = nil }
        }
        timer.resume()
    }
}
