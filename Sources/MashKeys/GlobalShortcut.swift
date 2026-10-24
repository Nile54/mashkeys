import Carbon
import Foundation

final class GlobalShortcut {
    var onToggle: (() -> Void)?
    private var key: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let signature: OSType = 0x4D53484B // MSHK

    init() throws {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let target = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == target.signature, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            target.onToggle?()
            return noErr
        }
        let installed = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &event,
                                            Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { throw CaptureProblem.operation("Install global shortcut", installed) }
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(cmdKey | optionKey), EventHotKeyID(signature: signature, id: 1),
                                         GetApplicationEventTarget(), 0, &key)
        guard result == noErr else {
            if let handler { RemoveEventHandler(handler); self.handler = nil }
            throw CaptureProblem.operation("Register ⌘⌥K (another app may already use it)", result)
        }
    }

    deinit {
        if let key { UnregisterEventHotKey(key) }
        if let handler { RemoveEventHandler(handler) }
    }
}
