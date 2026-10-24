import Foundation
import ObjectiveC.runtime

enum KeyboardError: LocalizedError {
    case unsupported
    case writeFailed
    var errorDescription: String? {
        switch self {
        case .unsupported: return "This Mac does not expose a supported built-in keyboard backlight."
        case .writeFailed: return "macOS did not accept the keyboard brightness change."
        }
    }
}

/// Small native adapter. The hardware exposes one brightness channel for the entire keyboard.
final class KeyboardBacklight {
    private let client: NSObject
    private let identifier: UInt64
    private var saved: [String: Any]?
    private let recoveryKey = "backlightRecovery"
    private typealias ReadLevel = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias WriteLevel = @convention(c) (AnyObject, Selector, Float, Int32, Bool, UInt64) -> Bool
    private typealias ReadFlag = @convention(c) (AnyObject, Selector, UInt64) -> Bool
    private typealias WriteFlag = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool

    init() throws {
        guard let framework = Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework"), framework.load(),
              let kind = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { throw KeyboardError.unsupported }
        let instance = kind.init()
        guard let object = instance.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue(),
              let devices = object as? [NSNumber], let first = devices.first else { throw KeyboardError.unsupported }
        client = instance; identifier = first.uint64Value
        guard implementation("setBrightness:fadeSpeed:commit:forKeyboard:", as: WriteLevel.self) != nil else { throw KeyboardError.unsupported }
    }

    private func implementation<T>(_ name: String, as signature: T.Type) -> T? {
        guard let method = class_getInstanceMethod(type(of: client), NSSelectorFromString(name)) else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: signature)
    }

    var brightness: Float {
        let selector = NSSelectorFromString("brightnessForKeyboard:")
        return implementation("brightnessForKeyboard:", as: ReadLevel.self)?(client, selector, identifier) ?? 1
    }

    var automaticBrightness: Bool? { readFlag("isAutoBrightnessEnabledForKeyboard:") }
    var idleDimmingSuspended: Bool? { readFlag("isIdleDimmingSuspendedOnKeyboard:") }

    @discardableResult func set(_ value: Float) -> Bool {
        let name = "setBrightness:fadeSpeed:commit:forKeyboard:"
        guard let write = implementation(name, as: WriteLevel.self) else { return false }
        // The animation owns the fade: do not restart the OS manual fade on every frame.
        return write(client, NSSelectorFromString(name), max(0, min(1, value)), 0, true, identifier)
    }

    private func readFlag(_ name: String) -> Bool? {
        implementation(name, as: ReadFlag.self)?(client, NSSelectorFromString(name), identifier)
    }

    private func writeFlag(_ name: String, _ value: Bool) {
        _ = implementation(name, as: WriteFlag.self)?(client, NSSelectorFromString(name), value, identifier)
    }

    func takeControl() throws {
        if saved == nil {
            let recovery = UserDefaults.standard.dictionary(forKey: recoveryKey)
            if (recovery?["device"] as? NSNumber)?.uint64Value == identifier { saved = recovery }
            if saved == nil {
                var snapshot: [String: Any] = ["device": NSNumber(value: identifier), "brightness": brightness]
                snapshot["automatic"] = readFlag("isAutoBrightnessEnabledForKeyboard:")
                snapshot["idleSuspended"] = readFlag("isIdleDimmingSuspendedOnKeyboard:")
                saved = snapshot
            }
            UserDefaults.standard.set(saved, forKey: recoveryKey)
        }
        writeFlag("enableAutoBrightness:forKeyboard:", false)
        writeFlag("suspendIdleDimming:forKeyboard:", true)
        guard set(1) else { restore(); throw KeyboardError.writeFailed }
    }

    func restore() {
        guard let snapshot = saved else { return }
        if let value = snapshot["brightness"] as? NSNumber { _ = set(value.floatValue) }
        if let value = snapshot["idleSuspended"] as? Bool { writeFlag("suspendIdleDimming:forKeyboard:", value) }
        if let value = snapshot["automatic"] as? Bool { writeFlag("enableAutoBrightness:forKeyboard:", value) }
        saved = nil
        UserDefaults.standard.removeObject(forKey: recoveryKey)
    }
}
