import Foundation

/// The LED Talks protocol, version 1 (`docs/protocol.md`). Section numbers refer to it.
public enum LEDTalks {
    public static let version: UInt8 = 1
    public static let maxPayload = 255
    static let preambleSymbols = 12
    static let syncByte: UInt8 = 0xE4
    /// Preamble, sync and header.
    static let fixedSymbols = preambleSymbols + 8 + 8
    /// §2: PAM-4 drive levels, out of 255.
    public static let pam4Levels: [UInt8] = [0, 31, 102, 255]

    /// §2.
    public enum Mode: UInt8, CaseIterable, Sendable {
        case ook = 1, pam4 = 2, rgb8 = 3

        public var symbols: Int { 1 << bits }
        public var bits: Int {
            switch self {
            case .ook: 1
            case .pam4: 2
            case .rgb8: 3
            }
        }
        public var header: UInt8 { LEDTalks.version << 4 | rawValue }
        public var name: String {
            switch self {
            case .ook: "OOK"
            case .pam4: "PAM-4"
            case .rgb8: "RGB-8"
            }
        }
    }

    /// §3.5: CRC-16/CCITT-FALSE.
    public static func crc16<C: Collection>(_ data: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    /// §3.6: the whitening sequence, PRBS9 from 0x1FF.
    public static func whitening(_ count: Int) -> [UInt8] {
        var state: UInt16 = 0x1FF
        return (0..<count).map { _ in
            var w: UInt8 = 0
            for _ in 0..<8 {
                let out = (state >> 8) & 1
                let fb = ((state >> 8) ^ (state >> 4)) & 1
                state = ((state << 1) | fb) & 0x1FF
                w = w << 1 | UInt8(out)
            }
            return w
        }
    }

    public static func whiten(_ bytes: [UInt8]) -> [UInt8] {
        zip(bytes, whitening(bytes.count)).map { $0 ^ $1 }
    }

    /// Symbols in a frame carrying `length` payload bytes.
    public static func frameSymbols(_ mode: Mode, length: Int) -> Int {
        fixedSymbols + mode.symbols + bodySymbols(mode, length: length)
    }

    static func bodySymbols(_ mode: Mode, length: Int) -> Int {
        (8 * (length + 3) + mode.bits - 1) / mode.bits
    }

    /// §3: a frame, one symbol (0..N-1) per element. The Swift twin of the C encoder, used by
    /// the synthetic camera and checked against the same test vectors.
    public static func encode(_ mode: Mode, payload: [UInt8]) -> [UInt8]? {
        guard payload.count <= maxPayload else { return nil }
        let hi = UInt8(mode.symbols - 1)
        var out: [UInt8] = (0..<preambleSymbols).map { $0 % 2 == 0 ? hi : 0 }
        func binary(_ byte: UInt8) { for b in (0..<8).reversed() { out.append(byte >> b & 1 == 1 ? hi : 0) } }
        binary(syncByte)
        binary(mode.header)
        out += (0..<mode.symbols).map { UInt8($0) }

        let crc = crc16([mode.header, UInt8(payload.count)] + payload)
        let body = whiten([UInt8(payload.count)] + payload + [UInt8(crc >> 8), UInt8(crc & 0xFF)])
        out += BitPacker.symbols(from: body, bits: mode.bits)
        return out
    }

    /// §2: a symbol's drive for an RGB LED, 0...1 per channel. OOK and PAM-4 scale `on`.
    public static func drive(_ mode: Mode, symbol: UInt8, on: RGB = .white) -> RGB {
        switch mode {
        case .rgb8:
            return RGB(symbol & 4 != 0 ? 1 : 0, symbol & 2 != 0 ? 1 : 0, symbol & 1 != 0 ? 1 : 0)
        case .ook:
            return symbol == 0 ? .black : on
        case .pam4:
            return on * (Double(pam4Levels[Int(symbol & 3)]) / 255)
        }
    }
}

/// Bytes to and from k-bit symbols, most significant bit first (§3.7).
enum BitPacker {
    static func symbols(from bytes: [UInt8], bits k: Int) -> [UInt8] {
        var out: [UInt8] = []
        var acc: UInt32 = 0, have = 0
        for byte in bytes {
            acc = acc << 8 | UInt32(byte)
            have += 8
            while have >= k {
                have -= k
                out.append(UInt8(acc >> UInt32(have) & ((1 << UInt32(k)) - 1)))
            }
            acc &= (1 << UInt32(have)) - 1
        }
        if have > 0 { out.append(UInt8(acc << UInt32(k - have) & ((1 << UInt32(k)) - 1))) }
        return out
    }

    /// The first `count` whole bytes in a symbol stream.
    static func bytes(from symbols: [UInt8], bits k: Int, count: Int) -> [UInt8] {
        var out: [UInt8] = []
        var acc: UInt32 = 0, have = 0
        for s in symbols where out.count < count {
            acc = acc << UInt32(k) | UInt32(s)
            have += k
            if have >= 8 {
                have -= 8
                out.append(UInt8(acc >> UInt32(have) & 0xFF))
                acc &= (1 << UInt32(have)) - 1
            }
        }
        return out
    }
}

/// A colour, linear or as the camera saw it, 0...1 per channel.
public struct RGB: Equatable, Sendable {
    public var r: Double, g: Double, b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    public static let black = RGB(0, 0, 0)
    public static let white = RGB(1, 1, 1)

    /// Rec. 709 luma.
    public var luma: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    public static func + (a: RGB, b: RGB) -> RGB { RGB(a.r + b.r, a.g + b.g, a.b + b.b) }
    public static func - (a: RGB, b: RGB) -> RGB { RGB(a.r - b.r, a.g - b.g, a.b - b.b) }
    public static func * (a: RGB, k: Double) -> RGB { RGB(a.r * k, a.g * k, a.b * k) }
    public func dot(_ o: RGB) -> Double { r * o.r + g * o.g + b * o.b }
    public func distance(to o: RGB) -> Double { (self - o).dot(self - o).squareRoot() }
}
