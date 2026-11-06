import XCTest
@testable import LEDTalksKit

/// End to end: encode, film with the synthetic camera, decode.
final class DecoderTests: XCTestCase {
    private let hi: [UInt8] = Array("Hi".utf8)

    private func run(_ samples: [Sample]) -> (decoded: [DecodedMessage], events: [DecoderEvent]) {
        var decoder = Decoder()
        var events: [DecoderEvent] = []
        for s in samples { events += decoder.add(s) }
        let decoded = events.compactMap { if case .decoded(let m) = $0 { m } else { nil } }
        return (decoded, events)
    }

    private func film(_ mode: LEDTalks.Mode, _ payload: [UInt8], camera: SyntheticCamera, period: Double,
                      skew: Double = 0, repeats: Int = 1) -> [Sample] {
        let frame = SyntheticCamera.repeated(LEDTalks.encode(mode, payload: payload)!, repeats: repeats)
        return camera.film(frame, mode: mode, period: period, skew: skew)
    }

    private func camera(fps: Double) -> SyntheticCamera {
        var c = SyntheticCamera()
        c.fps = fps
        return c
    }

    func testEveryModeAtTheRecommendedRates() {
        for mode in LEDTalks.Mode.allCases {
            for (fps, period) in [(30.0, 0.1), (120.0, 1 / 30.0), (240.0, 1 / 60.0)] {
                let (decoded, _) = run(film(mode, hi, camera: camera(fps: fps), period: period))
                XCTAssertEqual(decoded.map(\.payload), [hi], "\(mode.name) at \(fps) fps")
                XCTAssertEqual(decoded.first?.mode, mode)
                XCTAssertEqual(decoded.first?.period ?? 0, period, accuracy: period * 0.02)
            }
        }
    }

    func testThreeFramesPerSymbol() {
        // The protocol's floor (§5): 240 fps at 12.5 ms.
        for mode in LEDTalks.Mode.allCases {
            let (decoded, _) = run(film(mode, hi, camera: camera(fps: 240), period: 0.0125))
            XCTAssertEqual(decoded.map(\.payload), [hi], mode.name)
        }
    }

    func testLongPayloadsWithClockSkew() {
        // 255 bytes of OOK is about 2,000 symbols: skew must be tracked, not just estimated.
        let payload = (0..<255).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
        for mode in LEDTalks.Mode.allCases {
            for skew in [-0.02, 0.02] {
                let (decoded, _) = run(film(mode, payload, camera: camera(fps: 240), period: 1 / 60.0,
                                            skew: skew))
                XCTAssertEqual(decoded.map(\.payload), [payload], "\(mode.name), skew \(skew)")
            }
        }
    }

    func testARealisticCameraAndRoom() {
        var c = SyntheticCamera()
        c.fps = 240
        c.gain = 0.8
        c.whiteBalance = RGB(1.25, 1, 0.8)
        c.crosstalk = [[0.85, 0.12, 0.03], [0.10, 0.80, 0.10], [0.03, 0.15, 0.82]]
        c.ambient = RGB(0.06, 0.05, 0.04)
        c.flickerDepth = 0.6
        c.noise = 0.012
        c.jitter = 0.0004
        c.dropRate = 0.02
        let report = StatusTests.vector
        for mode in LEDTalks.Mode.allCases {
            for seed in 1...3 {
                c.seed = UInt64(seed)
                let (decoded, _) = run(film(mode, report, camera: c, period: 1 / 30.0, skew: 0.01))
                XCTAssertEqual(decoded.map(\.payload), [report], "\(mode.name), seed \(seed)")
                if case .status(let s)? = decoded.first?.content {
                    XCTAssertEqual(s.fields.first, .device("fob"))
                }
            }
        }
    }

    func testAColouredOOKLED() {
        let frame = LEDTalks.encode(.ook, payload: hi)!
        let samples = camera(fps: 60).film(frame, mode: .ook, period: 0.05, on: RGB(0.9, 0.35, 0))  // amber
        XCTAssertEqual(run(samples).decoded.map(\.payload), [hi])
    }

    func testJoiningPartWayThroughRepeats() {
        let samples = film(.rgb8, hi, camera: camera(fps: 120), period: 1 / 30.0, repeats: 3)
        let frameTime = Double(LEDTalks.frameSymbols(.rgb8, length: 2)) / 30
        let late = samples.filter { $0.time > 0.3 + frameTime * 0.4 }  // misses the first preamble
        XCTAssertEqual(run(late).decoded.map(\.payload), [hi, hi])
        XCTAssertEqual(run(samples).decoded.map(\.payload), [hi, hi, hi])
    }

    func testEventsAndProgress() {
        let (_, events) = run(film(.pam4, hi, camera: camera(fps: 240), period: 1 / 60.0))
        XCTAssertEqual(events.first, .locked(mode: .pam4, period: events.first.flatMap {
            if case .locked(_, let p) = $0 { p } else { nil }
        } ?? 0))
        let progress = events.compactMap { if case .progress(let r, let t) = $0 { (r, t) } else { nil } }
        XCTAssertEqual(progress.last?.0, 20)
        XCTAssertEqual(progress.last?.1, 20)
        XCTAssertNil(progress.first?.1)  // the length isn't known after the first symbol
    }

    func testACorruptedFrameFailsItsCRC() {
        var frame = LEDTalks.encode(.rgb8, payload: hi)!
        frame[frame.count - 3] ^= 0x5  // a body symbol, not the length
        let samples = camera(fps: 240).film(frame, mode: .rgb8, period: 1 / 60.0)
        let (decoded, events) = run(samples)
        XCTAssertTrue(decoded.isEmpty)
        XCTAssertTrue(events.contains(.failed(.crc)))
    }

    func testAnUnknownHeaderIsRejected() {
        var frame = LEDTalks.encode(.ook, payload: hi)!
        frame[27] = 0  // header 0x11 becomes 0x10: mode 0
        let (decoded, events) = run(camera(fps: 240).film(frame, mode: .ook, period: 1 / 60.0))
        XCTAssertTrue(decoded.isEmpty)
        XCTAssertTrue(events.contains(.failed(.unknownHeader(0x10))))
    }

    func testIndistinctTrainingIsRejected() {
        var frame = LEDTalks.encode(.pam4, payload: hi)!
        frame[29] = 0  // training "0123" becomes "0023"
        let (decoded, events) = run(camera(fps: 240).film(frame, mode: .pam4, period: 1 / 60.0))
        XCTAssertTrue(decoded.isEmpty)
        XCTAssertTrue(events.contains(.failed(.indistinctSymbols)))
    }

    func testNoSignalNoEvents() {
        var c = camera(fps: 240)
        c.noise = 0.005
        let dark = c.film(Array(repeating: 0, count: 200), mode: .ook, period: 1 / 60.0)
        let steady = c.film(Array(repeating: 1, count: 200), mode: .ook, period: 1 / 60.0)
        XCTAssertTrue(run(dark).events.isEmpty)
        XCTAssertTrue(run(steady).events.isEmpty)
    }

    func testIgnoresOutOfOrderSamplesAndResets() {
        var decoder = Decoder()
        XCTAssertTrue(decoder.add(Sample(time: 1, colour: .white)).isEmpty)
        XCTAssertTrue(decoder.add(Sample(time: 0.5, colour: .black)).isEmpty)
        decoder.reset()
        XCTAssertFalse(decoder.isReading)
        XCTAssertEqual(decoder.contrast, 0)
    }

    func testAnHourOfIdleSamplesStaysSmall() {
        // Trimming: the decoder mustn't keep every sample it's ever seen.
        var decoder = Decoder()
        for i in 0..<20_000 { _ = decoder.add(Sample(time: Double(i) / 240, colour: .black)) }
        let samples = film(.ook, hi, camera: camera(fps: 240), period: 1 / 60.0)
        var decoded = 0
        for s in samples {
            for e in decoder.add(Sample(time: s.time + 100, colour: s.colour)) {
                if case .decoded = e { decoded += 1 }
            }
        }
        XCTAssertEqual(decoded, 1)
    }
}
