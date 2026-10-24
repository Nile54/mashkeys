import Foundation
import AVFoundation

guard CommandLine.arguments.count == 3 else { fatalError("Usage: audio-test speech-44100.wav music-44100.wav") }
var position: Int64 = 0
var events: [Double] = []
let processor = AudioPipeline(rate: 44100, guardSpeech: true,
                              onHit: { events.append($0.time) }, onSpeech: { _ in }, onWarning: { fatalError($0) })
func feed(_ path: String, seconds: Double) throws {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
    precondition(file.processingFormat.sampleRate == 44100)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 512)!
    var read = 0
    while read < Int(seconds * 44100) {
        try file.read(into: buffer, frameCount: AVAudioFrameCount(min(512, Int(seconds * 44100) - read)))
        let frames = Int(buffer.frameLength)
        if frames == 0 { break }
        position += Int64(frames); read += frames
        processor.feedMono(buffer.floatChannelData![0], frames: frames, time: Double(position) / 44100)
        processor.speech?.drainForTesting()
    }
}
try feed(CommandLine.arguments[1], seconds: 8)
precondition(events.filter { $0 > 1.25 }.isEmpty, "Confirmed speech must not continue driving lights")
let speechInitial = events.count
let musicStart = Double(position) / 44100
try feed(CommandLine.arguments[2], seconds: 12)
let music = events.filter { $0 >= musicStart }
precondition(music.count > 3 && music[0] - musicStart < 1.25, "Music after talking must recover without replay")
let speechStart = Double(position) / 44100
try feed(CommandLine.arguments[1], seconds: 8)
precondition(events.filter { $0 > speechStart + 1.25 }.isEmpty, "Music-to-speech transition should close")
processor.stop()
print("PASS: local speech classification, music recovery without replay, initial recognition window (\(speechInitial) early speech hits), \(music.count) music hits")
