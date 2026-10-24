import Foundation

let keyboard = try KeyboardBacklight()
let original = keyboard.brightness
let automatic = keyboard.automaticBrightness
let idle = keyboard.idleDimmingSuspended
let animation = LightAnimator(keyboard: keyboard)
var failures: [String] = []
func expect(_ level: Float, _ name: String) {
    let actual = keyboard.brightness
    print("\(name): \(actual)")
    if abs(actual - level) > 0.03 { failures.append(name) }
}
try animation.begin()
if keyboard.automaticBrightness != false || keyboard.idleDimmingSuspended != true { failures.append("Lighting takeover") }
animation.react(to: BassHit(time: 0, volume: 1, isDrop: false))
expect(0, "Immediate zero endpoint")
DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
    let value = keyboard.brightness
    if value <= 0.2 || value >= 0.8 { failures.append("Slow gradual recovery") }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { animation.react(to: BassHit(time: 0.9, volume: 1, isDrop: true)) }
DispatchQueue.main.asyncAfter(deadline: .now() + 0.96) { expect(0, "Drop interrupts an ordinary pulse") }
DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { animation.speechBegan() }
DispatchQueue.main.asyncAfter(deadline: .now() + 1.62) { expect(1, "Speech settles to steady light") }
DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { animation.react(to: BassHit(time: 1.9, volume: 0.4, isDrop: false)) }
DispatchQueue.main.asyncAfter(deadline: .now() + 1.96) { expect(0, "Music resumes full range") }
DispatchQueue.main.asyncAfter(deadline: .now() + 3.1) { expect(1, "Recovery reaches 100 percent") }
DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { animation.stop() }
DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) {
    expect(original, "Original brightness restored")
    if keyboard.automaticBrightness != automatic || keyboard.idleDimmingSuspended != idle { failures.append("Preference restoration") }
    print(failures.isEmpty ? "PASS: native driver writes, smooth recovery, drop interruption, speech cancellation and preference restore (not optical measurements)" : "FAIL: \(failures)")
    exit(failures.isEmpty ? 0 : 1)
}
dispatchMain()
