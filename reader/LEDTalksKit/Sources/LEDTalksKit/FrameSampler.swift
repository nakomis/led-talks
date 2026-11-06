import Foundation

/// A camera frame's pixels: 8-bit BGRA (what AVFoundation's `kCVPixelFormatType_32BGRA` gives),
/// rows `bytesPerRow` apart. Coordinates are normalised, 0...1, in the buffer's own orientation,
/// which is also what `AVCaptureVideoPreviewLayer`'s capture-device points use.
public struct BGRAFrame {
    public let base: UnsafeRawPointer
    public let width: Int, height: Int, bytesPerRow: Int

    public init(base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) {
        self.base = base
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
    }

    @inline(__always) func pixel(_ x: Int, _ y: Int) -> RGB {
        let p = base.advanced(by: y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
        return RGB(Double(p[2]) / 255, Double(p[1]) / 255, Double(p[0]) / 255)
    }

    /// The mean colour of a square of side `size` (a fraction of the frame's height) centred on
    /// `centre`, sampling at most about 32 × 32 pixels.
    public func mean(around centre: (x: Double, y: Double), size: Double) -> RGB {
        let half = max(1, Int(size * Double(height) / 2))
        let cx = Int(centre.x * Double(width)), cy = Int(centre.y * Double(height))
        let x0 = max(0, cx - half), x1 = min(width - 1, cx + half)
        let y0 = max(0, cy - half), y1 = min(height - 1, cy + half)
        guard x1 >= x0, y1 >= y0 else { return .black }
        let step = max(1, (2 * half) / 32)
        var sum = RGB.black, n = 0.0
        for y in stride(from: y0, through: y1, by: step) {
            for x in stride(from: x0, through: x1, by: step) {
                sum = sum + pixel(x, y)
                n += 1
            }
        }
        return sum * (1 / n)
    }
}

/// Finds a blinking LED: the cell of a coarse grid whose brightness varies most over the frames
/// it has seen. A steady lamp, however bright, varies little; an LED talking varies a lot.
public struct LEDFinder: Sendable {
    public let columns: Int, rows: Int
    private var sum: [Double]
    private var sumSquares: [Double]
    public private(set) var frames = 0

    public init(columns: Int = 32, rows: Int = 18) {
        self.columns = columns
        self.rows = rows
        sum = Array(repeating: 0, count: columns * rows)
        sumSquares = sum
    }

    public mutating func add(_ frame: BGRAFrame) {
        for r in 0..<rows {
            for c in 0..<columns {
                let x = (2 * c + 1) * frame.width / (2 * columns)
                let y = (2 * r + 1) * frame.height / (2 * rows)
                // A few pixels per cell: the cell's centre and its four neighbours.
                var l = 0.0
                for (dx, dy) in [(0, 0), (-2, 0), (2, 0), (0, -2), (0, 2)] {
                    l += frame.pixel(min(max(x + dx, 0), frame.width - 1),
                                     min(max(y + dy, 0), frame.height - 1)).luma
                }
                l /= 5
                sum[r * columns + c] += l
                sumSquares[r * columns + c] += l * l
            }
        }
        frames += 1
    }

    /// The centre of the cell that varied most, normalised, and its standard deviation; nil
    /// until a few frames have been seen.
    public var best: (x: Double, y: Double, deviation: Double)? {
        guard frames >= 8 else { return nil }
        var bestIndex = 0, bestVariance = -1.0
        let n = Double(frames)
        for i in sum.indices {
            let mean = sum[i] / n
            let variance = sumSquares[i] / n - mean * mean
            if variance > bestVariance { bestVariance = variance; bestIndex = i }
        }
        let c = bestIndex % columns, r = bestIndex / columns
        return ((Double(c) + 0.5) / Double(columns), (Double(r) + 0.5) / Double(rows),
                max(bestVariance, 0).squareRoot())
    }
}
