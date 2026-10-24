import Foundation
import Accelerate

/// A causal overlapping FFT: 2048 samples of frequency resolution, 256-sample hops.
final class BassSpectrum {
    let sampleRate: Double
    private let count = 2048
    private let hop = 256
    private let fft: FFTSetup
    private var samples = [Float](repeating: 0, count: 2048)
    private var window = [Float](repeating: 0, count: 2048)
    private var tapered = [Float](repeating: 0, count: 2048)
    private var real = [Float](repeating: 0, count: 1024)
    private var imaginary = [Float](repeating: 0, count: 1024)
    private var powers = [Float](repeating: 0, count: 1024)
    private var filled = 0
    private var detector = BassDetector()

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        fft = vDSP_create_fftsetup(11, FFTRadix(FFT_RADIX2))!
        vDSP_hann_window(&window, 2048, Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    func consume(_ input: UnsafePointer<Float>, frames: Int, endingAt time: Double, onHit: (BassHit) -> Void) {
        var consumed = 0
        while consumed < frames {
            let n = min(frames - consumed, count - filled)
            samples.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress!.advanced(by: filled).update(from: input.advanced(by: consumed), count: n)
            }
            filled += n; consumed += n
            if filled == count {
                let (energy, share) = spectrum()
                let end = time - Double(frames - consumed) / sampleRate
                if let hit = detector.observe(energy: energy, bassShare: share,
                                               seconds: Double(hop) / sampleRate, time: end) { onHit(hit) }
                samples.withUnsafeMutableBufferPointer { pointer in
                    _ = memmove(pointer.baseAddress!, pointer.baseAddress!.advanced(by: hop), (count - hop) * MemoryLayout<Float>.size)
                }
                filled = count - hop
            }
        }
    }

    private func spectrum() -> (Float, Float) {
        vDSP_vmul(samples, 1, window, 1, &tapered, 1, vDSP_Length(count))
        real.withUnsafeMutableBufferPointer { r in
            imaginary.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                tapered.withUnsafeBytes { bytes in
                    vDSP_ctoz(bytes.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, 1024)
                }
                vDSP_fft_zrip(fft, &split, 1, 11, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &powers, 1, 1024)
            }
        }
        let binWidth = sampleRate / Double(count)
        let low = max(1, Int(ceil(20 / binWidth)))
        let high = min(1023, Int(floor(150 / binWidth)))
        let top = min(1023, Int(floor(20000 / binWidth)))
        var bass: Float = 0, total: Float = 0
        if low <= top {
            for bin in low...top {
                total += powers[bin]
                if bin <= high { bass += powers[bin] }
            }
        }
        return (sqrt(max(0, bass)) / Float(count), bass / max(total, 1e-20))
    }
}
