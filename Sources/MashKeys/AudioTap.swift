import Foundation
import CoreAudio

enum CaptureProblem: LocalizedError {
    case operation(String, OSStatus)
    case noOutput
    var errorDescription: String? {
        switch self {
        case .noOutput: return "No audio output device is available."
        case let .operation(name, status):
            return "\(name) failed (\(status)). If audio access was denied, allow MashKeys in System Settings → Privacy & Security → Screen & System Audio Recording, then retry."
        }
    }
}

final class AudioPipeline {
    let spectrum: AudioSpectrum
    private let reaction: ReactionControl
    private let songSync: SongSyncCoordinator?
    let speech: SpeechGuard?
    let onHit: (AudioHit) -> Void
    private var mono = [Float](repeating: 0, count: 16384)

    init(rate: Double, guardSpeech: Bool, reaction: ReactionControl = ReactionControl(), songSync: SongSyncCoordinator? = nil, onHit: @escaping (AudioHit) -> Void, onSpeech: @escaping (Bool) -> Void,
         onWarning: @escaping (String) -> Void) {
        self.reaction = reaction
        self.songSync = songSync
        spectrum = AudioSpectrum(sampleRate: rate, settings: reaction.snapshot(or: ReactionSettings()))
        self.onHit = onHit
        do { speech = try SpeechGuard(sampleRate: rate, enabled: guardSpeech) }
        catch { speech = nil; onWarning("Speech guard unavailable: \(error.localizedDescription)") }
        speech?.onSuppressionChanged = onSpeech
        speech?.onFailure = onWarning
    }

    func feedMono(_ pointer: UnsafePointer<Float>, frames: Int, time: Double) {
        spectrum.configure(reaction.snapshot(or: spectrum.settings))
        speech?.submit(pointer, count: frames)
        let allowed = speech?.allowsLights != false
        spectrum.consume(pointer, frames: frames, endingAt: time, onFrame: { [self] frame in
            songSync?.observe(frame, allowed: allowed)
        }) { [self] hit in
            if speech?.allowsLights != false { onHit(hit) }
        }
    }

    /// CoreAudio provides float PCM. Mix all channels and consume every frame.
    func feed(_ list: UnsafePointer<AudioBufferList>, at now: Double) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, first.mData != nil else { return }
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * max(1, Int(first.mNumberChannels)))
        let channelCount = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard frames > 0, channelCount > 0 else { return }
        var offset = 0
        while offset < frames {
            let count = min(frames - offset, mono.count)
            for i in 0..<count {
                var value: Float = 0
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    let channels = Int(buffer.mNumberChannels)
                    let available = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let position = (offset + i) * channels
                    if position + channels <= available {
                        let input = data.assumingMemoryBound(to: Float.self)
                        for channel in 0..<channels { value += input[position + channel] }
                    }
                }
                mono[i] = value / Float(channelCount)
            }
            mono.withUnsafeBufferPointer { pointer in
                feedMono(pointer.baseAddress!, frames: count,
                         time: now - Double(frames - offset - count) / spectrum.sampleRate)
            }
            offset += count
        }
    }

    func stop() { speech?.stop() }
}

/// An app-owned, unmuted process tap. Lifecycle changes are serialized off the UI thread.
final class AudioTap {
    let songSync = SongSyncCoordinator()
    var onHit: ((AudioHit) -> Void)?
    var onSpeech: ((Bool) -> Void)?
    var onStatus: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    private let work = DispatchQueue(label: "io.github.Nile54.MashKeys.capture", qos: .userInitiated)
    private let intent = NSLock()
    private var revision: UInt64 = 0
    private var wanted = false
    private var excluded: Set<String> = []
    private var protectSpeech = true
    private let reaction = ReactionControl()
    private var pipeline: AudioPipeline?
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var callback: AudioDeviceIOProcID?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var selectedObjects: Set<AudioObjectID> = []
    private let system = AudioObjectID(kAudioObjectSystemObject)

    private func ticket(active: Bool? = nil) -> UInt64 {
        intent.lock(); defer { intent.unlock() }
        if let active { wanted = active }
        revision &+= 1
        return revision
    }

    private func current(_ value: UInt64) -> Bool {
        intent.lock(); defer { intent.unlock() }
        return wanted && revision == value
    }

    func start(excluding: Set<String>, speech: Bool, reaction settings: ReactionSettings = ReactionSettings()) {
        reaction.replace(settings)
        let request = ticket(active: true)
        work.async { [self] in
            excluded = excluding; protectSpeech = speech
            close()
            guard current(request) else { return }
            do { try open(request) }
            catch { close(); publish(request) { $0.onFailure?(error.localizedDescription) } }
        }
    }

    func stop() {
        _ = ticket(active: false)
        work.async { [self] in close() }
    }

    func setReaction(_ settings: ReactionSettings) { reaction.replace(settings) }

    func setSpeechProtection(_ value: Bool) {
        work.async { [self] in protectSpeech = value; pipeline?.speech?.setEnabled(value) }
    }

    /// Used at application termination to finish teardown before the process exits.
    func finish() { _ = ticket(active: false); work.sync { close() } }

    private func publish(_ request: UInt64, _ body: @escaping (AudioTap) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.current(request) else { return }
            body(self)
        }
    }

    private func open(_ request: UInt64) throws {
        publish(request) { $0.onStatus?("Starting audio…") }
        var device: AudioObjectID = 0
        try read(system, selector: kAudioHardwarePropertyDefaultOutputDevice, into: &device)
        guard device != 0 else { throw CaptureProblem.noOutput }
        guard let uid = string(device, selector: kAudioDevicePropertyDeviceUID) else { throw CaptureProblem.noOutput }
        selectedObjects = allowedProcessIDs()
        // Filtered capture is an explicit allowed-process mix, including newly
        // allowed apps after the process list is reconciled.
        if !excluded.isEmpty && selectedObjects.isEmpty {
            addListeners()
            publish(request) { $0.onStatus?("Waiting for allowed apps") }
            return
        }
        let description = excluded.isEmpty
            ? CATapDescription(excludingProcesses: [], deviceUID: uid, stream: 0)
            : CATapDescription(processes: Array(selectedObjects), deviceUID: uid, stream: 0)
        description.isExclusive = excluded.isEmpty
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "MashKeys system audio"
        description.uuid = UUID()
        try check(AudioHardwareCreateProcessTap(description, &tap), "System audio capture")
        var format = AudioStreamBasicDescription()
        try read(tap, selector: kAudioTapPropertyFormat, into: &format)
        guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw CaptureProblem.operation("Audio format is not supported (32-bit float PCM required)", -50)
        }
        guard let tapUID = string(tap, selector: kAudioTapPropertyUID) else { throw CaptureProblem.noOutput }
        let definition: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "MashKeys",
            kAudioAggregateDeviceUIDKey as String: "io.github.Nile54.MashKeys.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [[kAudioSubTapUIDKey as String: tapUID,
                                                       kAudioSubTapDriftCompensationKey as String: true]]
        ]
        try check(AudioHardwareCreateAggregateDevice(definition as CFDictionary, &aggregate), "Audio device")
        // Tap aggregate initialization is asynchronous inside CoreAudio.
        Thread.sleep(forTimeInterval: 1)
        guard current(request) else { close(); return }
        var rate = 44100.0
        try read(aggregate, selector: kAudioDevicePropertyNominalSampleRate, into: &rate)
        let processor = AudioPipeline(rate: rate, guardSpeech: protectSpeech, reaction: reaction, songSync: songSync,
                                      onHit: { [weak self] hit in
                                          self?.publish(request) { tap in
                                              if tap.pipeline?.speech?.allowsLights != false { tap.onHit?(hit) }
                                          }
                                      }, onSpeech: { [weak self] blocked in
                                          self?.publish(request) { $0.onSpeech?(blocked) }
                                      }, onWarning: { [weak self] message in
                                          self?.publish(request) { $0.onStatus?(message) }
                                      })
        pipeline = processor
        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { _, input, _, _, _ in
            processor.feed(input, at: ProcessInfo.processInfo.systemUptime)
        }, "Audio callback")
        guard let proc else { throw CaptureProblem.operation("Audio callback", -1) }
        callback = proc
        try check(AudioDeviceStart(aggregate, proc), "Start audio")
        addListeners()
        publish(request) { $0.onStatus?("Listening for beats") }
    }

    private func close() {
        songSync.cancel("Audio capture changed. Click Sync to song again.")
        for (original, block) in listeners {
            var address = original
            AudioObjectRemovePropertyListenerBlock(system, &address, work, block)
        }
        listeners.removeAll()
        if let callback {
            AudioDeviceStop(aggregate, callback)
            AudioDeviceDestroyIOProcID(aggregate, callback)
            self.callback = nil
        }
        pipeline?.stop(); pipeline = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }

    private func addListeners() {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyProcessObjectList] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                if selector == kAudioHardwarePropertyProcessObjectList && (self.excluded.isEmpty || self.allowedProcessIDs() == self.selectedObjects) { return }
                let request = self.ticket()
                self.work.async { [self] in
                    guard self.current(request) else { return }
                    self.close()
                    do { try self.open(request) }
                    catch { self.close(); self.publish(request) { $0.onFailure?(error.localizedDescription) } }
                }
            }
            if AudioObjectAddPropertyListenerBlock(system, &address, work, block) == noErr { listeners.append((address, block)) }
        }
    }

    private func allowedProcessIDs() -> Set<AudioObjectID> {
        guard !excluded.isEmpty else { return [] }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &bytes) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &bytes, &objects) == noErr else { return [] }
        return Set(objects.filter { object in
            guard let bundle = string(object, selector: kAudioProcessPropertyBundleID) else { return false }
            guard bundle != Bundle.main.bundleIdentifier else { return false }
            return !excluded.contains { bundle == $0 || bundle.hasPrefix($0 + ".") }
        })
    }

    private func read<T>(_ object: AudioObjectID, selector: AudioObjectPropertySelector, into result: inout T) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, UnsafeMutableRawPointer($0))
        }
        try check(status, "Read audio property")
    }

    private func string(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        do { try read(object, selector: selector, into: &value) }
        catch { return nil }
        return value?.takeRetainedValue() as String?
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw CaptureProblem.operation(operation, status) }
    }
}
