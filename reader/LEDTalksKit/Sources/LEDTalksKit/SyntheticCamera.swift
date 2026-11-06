import Foundation

/// A pretend camera filming a pretend LED, so the decoder can be tested without hardware.
///
/// It integrates the LED's drive over each frame's exposure, then applies what a real camera
/// and room do: colour crosstalk, white balance, ambient light with mains flicker, gain, a tone
/// curve, noise, timestamp jitter, and dropped frames. Each sample's time is the middle of its
/// exposure.
public struct SyntheticCamera: Sendable {
    public var fps = 240.0
    /// Exposure as a fraction of the frame interval.
    public var exposure = 0.5
    /// Linear gain before the tone curve.
    public var gain = 0.9
    /// The tone curve's gamma.
    public var gamma = 2.2
    public var whiteBalance = RGB(1, 1, 1)
    /// Rows: camera R, G, B; columns: how much of the LED's R, G, B each sees.
    public var crosstalk: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
    /// Ambient light in the region of interest, linear.
    public var ambient = RGB(0.02, 0.02, 0.02)
    public var flickerHz = 100.0
    /// The fraction of the ambient light that flickers.
    public var flickerDepth = 0.0
    /// Noise standard deviation, in output units (0...1).
    public var noise = 0.0
    /// Timestamp jitter standard deviation, in seconds.
    public var jitter = 0.0
    /// The chance of each frame being dropped.
    public var dropRate = 0.0
    public var seed: UInt64 = 1

    public init() {}

    /// Films `symbols` shown from `start` at `period` seconds each on the device's clock, which
    /// runs `skew` fast (0.02 = 2% slow periods). The LED is off before and after, and the film
    /// runs from 0 to `start` + the signal + `tail`.
    public func film(_ symbols: [UInt8], mode: LEDTalks.Mode, period: Double, skew: Double = 0,
                     start: Double = 0.3, tail: Double = 0.3, on: RGB = .white) -> [Sample] {
        let p = period * (1 + skew)
        let drives = symbols.map { LEDTalks.drive(mode, symbol: $0, on: on) }
        let end = start + Double(symbols.count) * p + tail
        let interval = 1 / fps, exp = exposure * interval
        var rng = SplitMix64(seed: seed)
        var samples: [Sample] = []
        var k = 0
        while Double(k) * interval < end {
            let t0 = Double(k) * interval
            k += 1
            if dropRate > 0, rng.uniform() < dropRate { continue }

            // Mean drive over [t0, t0 + exp].
            var sum = RGB.black
            let first = max(0, Int(((t0 - start) / p).rounded(.down)))
            var i = first
            while i < drives.count {
                let a = start + Double(i) * p, b = a + p
                if a >= t0 + exp { break }
                let overlap = min(b, t0 + exp) - max(a, t0)
                if overlap > 0 { sum = sum + drives[i] * overlap }
                i += 1
            }
            let led = sum * (1 / exp)

            let seen = RGB(row(0, led), row(1, led), row(2, led))
            let mid = t0 + exp / 2
            let flicker = 1 - flickerDepth + flickerDepth * (1 + cos(2 * .pi * flickerHz * mid)) / 2
            let linear = RGB(seen.r * whiteBalance.r, seen.g * whiteBalance.g, seen.b * whiteBalance.b)
                + ambient * flicker
            func out(_ x: Double) -> Double {
                let v = pow(min(max(gain * x, 0), 1), 1 / gamma) + noise * rng.gaussian()
                return min(max(v, 0), 1)
            }
            let time = mid + jitter * rng.gaussian()
            samples.append(Sample(time: time, colour: RGB(out(linear.r), out(linear.g), out(linear.b))))
        }
        // Jitter can reorder neighbours; a real camera's timestamps never go backwards.
        return samples.sorted { $0.time < $1.time }
    }

    private func row(_ r: Int, _ c: RGB) -> Double {
        crosstalk[r][0] * c.r + crosstalk[r][1] * c.g + crosstalk[r][2] * c.b
    }

    /// A frame shown `repeats` times with the protocol's gap between (§3.8).
    public static func repeated(_ frame: [UInt8], repeats: Int, gap: Int = 4) -> [UInt8] {
        var out: [UInt8] = []
        for r in 0..<repeats {
            if r > 0 { out += Array(repeating: 0, count: gap) }
            out += frame
        }
        return out
    }
}

/// A small, seedable random number generator, so tests are repeatable.
struct SplitMix64: Sendable {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func gaussian() -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
