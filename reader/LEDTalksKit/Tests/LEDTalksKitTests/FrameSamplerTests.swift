import XCTest
@testable import LEDTalksKit

final class FrameSamplerTests: XCTestCase {
    /// A 64 × 36 BGRA frame, padded rows, with `fill` deciding each pixel.
    private func withFrame(_ fill: (Int, Int) -> (UInt8, UInt8, UInt8), _ body: (BGRAFrame) -> Void) {
        let w = 64, h = 36, bpr = w * 4 + 16
        var bytes = [UInt8](repeating: 0, count: bpr * h)
        for y in 0..<h {
            for x in 0..<w {
                let (r, g, b) = fill(x, y)
                bytes[y * bpr + x * 4] = b
                bytes[y * bpr + x * 4 + 1] = g
                bytes[y * bpr + x * 4 + 2] = r
                bytes[y * bpr + x * 4 + 3] = 255
            }
        }
        bytes.withUnsafeBytes { body(BGRAFrame(base: $0.baseAddress!, width: w, height: h, bytesPerRow: bpr)) }
    }

    func testMeanOfARegion() {
        // Red on the left half, blue on the right.
        withFrame({ x, _ in x < 32 ? (255, 0, 0) : (0, 0, 255) }) { frame in
            XCTAssertEqual(frame.mean(around: (0.25, 0.5), size: 0.2).distance(to: RGB(1, 0, 0)), 0, accuracy: 1e-9)
            XCTAssertEqual(frame.mean(around: (0.75, 0.5), size: 0.2).distance(to: RGB(0, 0, 1)), 0, accuracy: 1e-9)
            let edge = frame.mean(around: (0.5, 0.5), size: 0.5)
            XCTAssertEqual(edge.r, 0.5, accuracy: 0.1)
            XCTAssertEqual(edge.b, 0.5, accuracy: 0.1)
            // At a corner the square is clipped, not out of bounds.
            XCTAssertEqual(frame.mean(around: (0, 0), size: 0.3).distance(to: RGB(1, 0, 0)), 0, accuracy: 1e-9)
            XCTAssertEqual(frame.mean(around: (1, 1), size: 0.3).distance(to: RGB(0, 0, 1)), 0, accuracy: 1e-9)
        }
    }

    func testFinderPicksTheBlinkingCellNotTheBrightOne() {
        var finder = LEDFinder(columns: 8, rows: 6)
        XCTAssertNil(finder.best)
        for k in 0..<20 {
            let on = k % 2 == 0
            withFrame({ x, y in
                if x >= 48, y < 6 { return (255, 255, 255) }                        // a steady lamp
                if (24..<32).contains(x), (18..<24).contains(y) { return on ? (255, 120, 0) : (10, 5, 0) }
                return (20, 20, 20)
            }) { finder.add($0) }
        }
        let best = finder.best!
        XCTAssertEqual(best.x, 3.5 / 8, accuracy: 1e-9)  // column 3: x 24..<32
        XCTAssertEqual(best.y, 3.5 / 6, accuracy: 1e-9)  // row 3: y 18..<24
        XCTAssertGreaterThan(best.deviation, 0.2)
        XCTAssertEqual(finder.frames, 20)
    }
}
