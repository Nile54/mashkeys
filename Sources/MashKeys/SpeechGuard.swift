import Foundation
import AVFoundation
import SoundAnalysis
import CoreMedia

/// Classification never runs on the audio callback and never waits for a music label.
final class SpeechGuard: NSObject, SNResultsObserving {
    var onSuppressionChanged: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    private let worker = DispatchQueue(label: "io.github.Nile54.MashKeys.speech", qos: .userInitiated)
    private let stateMutex = NSLock()
    private let buffersMutex = NSLock()
    private let analyzer: SNAudioStreamAnalyzer
    private var unused: [AVAudioPCMBuffer] = []
    private var current: AVAudioPCMBuffer?
    private var used = 0
    private var samplePosition: Int64 = 0
    private var packetStart: Int64 = 0
    private var policy = SpeechPolicy()
    private var enabled = true
    private var alive = true
    private let packetSize = 2048

    init(sampleRate: Double, enabled: Bool) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        analyzer = SNAudioStreamAnalyzer(format: format)
        self.enabled = enabled
        super.init()
        for _ in 0..<8 { unused.append(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!) }
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 0.5, preferredTimescale: 16000)
        request.overlapFactor = 0.5
        try analyzer.add(request, withObserver: self)
    }

    var allowsLights: Bool {
        guard stateMutex.try() else { return false }
        defer { stateMutex.unlock() }
        return !enabled || !alive || policy.permits(at: ProcessInfo.processInfo.systemUptime)
    }

    func setEnabled(_ value: Bool) {
        stateMutex.lock()
        guard enabled != value else { stateMutex.unlock(); return }
        enabled = value; policy.reset()
        stateMutex.unlock()
        onSuppressionChanged?(false)
    }

    func setEnabledIfNeeded(_ value: Bool) { setEnabled(value) }

    /// The caller owns the audio thread. Only bounded, preallocated packets are queued.
    func submit(_ source: UnsafePointer<Float>, count: Int) {
        var offset = 0
        while offset < count {
            if current == nil {
                guard buffersMutex.try() else { samplePosition += Int64(count - offset); return }
                current = unused.popLast()
                buffersMutex.unlock()
                guard current != nil else { samplePosition += Int64(count - offset); return }
                used = 0; packetStart = samplePosition
            }
            let packet = current!
            let n = min(count - offset, packetSize - used)
            packet.floatChannelData![0].advanced(by: used).update(from: source.advanced(by: offset), count: n)
            samplePosition += Int64(n); offset += n; used += n
            if used == packetSize {
                packet.frameLength = AVAudioFrameCount(packetSize)
                let start = packetStart
                current = nil
                worker.async { [self] in
                    stateMutex.lock(); let shouldAnalyze = enabled && alive; stateMutex.unlock()
                    if shouldAnalyze { analyzer.analyze(packet, atAudioFramePosition: start) }
                    buffersMutex.lock(); unused.append(packet); buffersMutex.unlock()
                }
            }
        }
    }

    func stop() {
        stateMutex.lock(); alive = false; policy.reset(); stateMutex.unlock()
        worker.async { [self] in analyzer.removeAllRequests() }
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        func confidence(_ name: String) -> Double { result.classification(forIdentifier: name)?.confidence ?? 0 }
        let now = ProcessInfo.processInfo.systemUptime
        stateMutex.lock()
        guard alive && enabled else { stateMutex.unlock(); return }
        let before = policy.permits(at: now)
        policy.update(music: confidence("music"),
                      speech: max(confidence("speech"), confidence("chatter"), confidence("whispering"), confidence("babble")),
                      singing: max(confidence("singing"), confidence("rapping"), confidence("choir_singing")), at: now)
        let after = policy.permits(at: now)
        stateMutex.unlock()
        if before != after { onSuppressionChanged?(!after) }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        stateMutex.lock(); policy.reset(); stateMutex.unlock()
        onSuppressionChanged?(false)
        onFailure?(error.localizedDescription)
    }

    #if TESTING
    func drainForTesting() { worker.sync {} }
    #endif
}
