import XCTest
@testable import LEDTalksKit

/// docs/protocol.md §7. The same vectors as encoder/core/tests.
final class ProtocolTests: XCTestCase {
    private let hi: [UInt8] = Array("Hi".utf8)

    private func symbols(_ spec: String) -> [UInt8] {
        spec.compactMap { $0.wholeNumberValue }.map(UInt8.init)
    }

    func testCRCAndWhitening() {
        XCTAssertEqual(LEDTalks.crc16(Array("123456789".utf8)), 0x29B1)
        XCTAssertEqual(LEDTalks.whitening(8), [0xFF, 0x83, 0xDF, 0x17, 0x32, 0x09, 0x4E, 0xD1])
        let data = (0..<300).map { UInt8(truncatingIfNeeded: $0 * 7) }
        XCTAssertEqual(LEDTalks.whiten(LEDTalks.whiten(data)), data)
    }

    func testVectors() {
        XCTAssertEqual(LEDTalks.encode(.ook, payload: hi), symbols(
            "101010101010 | 11100100 | 00010001 | 01 | 1111110111001011101101101110100101101011"))
        XCTAssertEqual(LEDTalks.encode(.pam4, payload: hi), symbols(
            "303030303030 | 33300300 | 00030030 | 0123 | 33313023231213022313"))
        XCTAssertEqual(LEDTalks.encode(.rgb8, payload: hi), symbols(
            "707070707070 | 77700700 | 00070077 | 01234567 | 77345666010014"))
        XCTAssertEqual(LEDTalks.encode(.ook, payload: []), symbols(
            "101010101010 | 11100100 | 00010001 | 01 | 111111111010111010010010"))
        XCTAssertEqual(LEDTalks.encode(.rgb8, payload: StatusTests.vector), symbols(
            "707070707070 | 77700700 | 00070077 | 01234567 | "
                + "7210133605052146131517427712224172162707600500570604712141071327330124"))
    }

    func testSizes() {
        XCTAssertEqual(LEDTalks.frameSymbols(.ook, length: 2), 70)
        XCTAssertEqual(LEDTalks.frameSymbols(.pam4, length: 2), 52)
        XCTAssertEqual(LEDTalks.frameSymbols(.rgb8, length: 2), 50)
        XCTAssertNil(LEDTalks.encode(.ook, payload: Array(repeating: 0, count: 256)))
        for mode in LEDTalks.Mode.allCases {
            let frame = LEDTalks.encode(mode, payload: Array(repeating: 0xA5, count: 255))!
            XCTAssertEqual(frame.count, LEDTalks.frameSymbols(mode, length: 255))
            XCTAssertTrue(frame.allSatisfy { Int($0) < mode.symbols })
        }
    }

    func testBitPackerRoundTrips() {
        let bytes: [UInt8] = [0x00, 0xFF, 0x12, 0x34, 0xAB]
        for k in 1...3 {
            XCTAssertEqual(BitPacker.bytes(from: BitPacker.symbols(from: bytes, bits: k), bits: k,
                                           count: bytes.count), bytes)
        }
    }

    func testDrive() {
        XCTAssertEqual(LEDTalks.drive(.rgb8, symbol: 4), RGB(1, 0, 0))
        XCTAssertEqual(LEDTalks.drive(.rgb8, symbol: 3), RGB(0, 1, 1))
        XCTAssertEqual(LEDTalks.drive(.ook, symbol: 1, on: RGB(1, 0.5, 0)), RGB(1, 0.5, 0))
        XCTAssertEqual(LEDTalks.drive(.pam4, symbol: 2).r, 102.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(LEDTalks.drive(.pam4, symbol: 0), .black)
    }
}

final class StatusTests: XCTestCase {
    /// §7: device "fob", firmware "1.0.0", uptime 3600 s, battery 2950 mV.
    static let vector: [UInt8] = [0x01, 0x01, 0x03, 0x66, 0x6F, 0x62, 0x02, 0x05, 0x31, 0x2E, 0x30,
                                  0x2E, 0x30, 0x03, 0x04, 0x10, 0x0E, 0x00, 0x00, 0x04, 0x02, 0x86, 0x0B]

    func testParsesTheVector() {
        guard case .status(let report) = Content.parse(Self.vector) else { return XCTFail() }
        XCTAssertEqual(report.fields, [.device("fob"), .firmware("1.0.0"), .uptime(seconds: 3600),
                                       .battery(millivolts: 2950)])
        XCTAssertEqual(Content.parse(Self.vector).lines.map(\.value), ["fob", "1.0.0", "1 h 0 min", "2.95 V"])
    }

    func testSkipsWhatItCannotRead() {
        let payload: [UInt8] = [0x01,
                                0x03, 0x02, 0x01, 0x02,          // uptime of the wrong size
                                0x0A, 0x01, 0xEE,                // reserved tag
                                0x09, 0x02, 0x6A, 0xFF,          // -1.50 °C
                                0x08, 0x07] + Array("heap=42".utf8)
            + [0x08, 0x02] + Array("ok".utf8)                    // no "=": an empty value
            + [0x81, 0x02, 0xBE, 0xEF,
               0x06, 0x02, 0x34, 0x12,
               0x07, 0x00,
               0x05, 0x09, 0x41]                                 // runs past the end
        guard case .status(let report) = Content.parse(payload) else { return XCTFail() }
        XCTAssertEqual(report.fields, [.temperature(centiCelsius: -150), .keyValue(key: "heap", value: "42"),
                                       .keyValue(key: "ok", value: ""), .deviceSpecific(tag: 0x81, [0xBE, 0xEF]),
                                       .error(0x1234), .id([])])
        XCTAssertEqual(report.fields.map(\.value),
                       ["-1.50 °C", "42", "", "BE EF", "4660 (0x1234)", "(none)"])
        XCTAssertEqual(report.fields.map(\.label), ["Temperature", "heap", "ok", "Tag 0x81", "Error", "ID"])
    }

    func testOtherContent() {
        XCTAssertEqual(Content.parse([]), .raw([]))
        XCTAssertEqual(Content.parse([0x00, 0xAB]).lines.first?.value, "AB")
        XCTAssertEqual(Content.parse([0x07, 0x01]), .unknown(type: 7, [0x01]))
        XCTAssertEqual(Content.parse([0x07, 0x01]).lines.map(\.value), ["0x07", "01"])
        XCTAssertEqual(Content.parse([0x01, 0x01, 0x02, 0xC3, 0x28]), .status(StatusReport(fields: [])))  // bad UTF-8
    }

    func testDurations() {
        XCTAssertEqual(Duration.text(seconds: 59), "59 s")
        XCTAssertEqual(Duration.text(seconds: 125), "2 min 5 s")
        XCTAssertEqual(Duration.text(seconds: 90_061), "1 d 1 h")
    }
}
