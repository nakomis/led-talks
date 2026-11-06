import Foundation

/// A decoded payload (§4): a status report, raw bytes, or a content type this reader doesn't know.
public enum Content: Equatable, Sendable {
    case status(StatusReport)
    case raw([UInt8])
    case unknown(type: UInt8, [UInt8])

    public static func parse(_ payload: [UInt8]) -> Content {
        guard let type = payload.first else { return .raw([]) }
        let rest = Array(payload.dropFirst())
        switch type {
        case 0x00: return .raw(rest)
        case 0x01: return .status(StatusReport(fields: StatusReport.parseFields(rest)))
        default: return .unknown(type: type, rest)
        }
    }

    /// Label and value pairs, for display.
    public var lines: [(label: String, value: String)] {
        switch self {
        case .status(let report): report.fields.map { ($0.label, $0.value) }
        case .raw(let bytes): [("Bytes", Hex.string(bytes))]
        case .unknown(let type, let bytes):
            [("Content type", String(format: "0x%02X", type)), ("Bytes", Hex.string(bytes))]
        }
    }
}

/// §4: type-length-value fields.
public struct StatusReport: Equatable, Sendable {
    public var fields: [Field]

    public enum Field: Equatable, Sendable {
        case device(String)
        case firmware(String)
        case uptime(seconds: UInt32)
        case battery(millivolts: UInt16)
        case state(String)
        case error(UInt16)
        case id([UInt8])
        case keyValue(key: String, value: String)
        case temperature(centiCelsius: Int16)
        case deviceSpecific(tag: UInt8, [UInt8])

        public var label: String {
            switch self {
            case .device: "Device"
            case .firmware: "Firmware"
            case .uptime: "Uptime"
            case .battery: "Battery"
            case .state: "State"
            case .error: "Error"
            case .id: "ID"
            case .keyValue(let key, _): key
            case .temperature: "Temperature"
            case .deviceSpecific(let tag, _): String(format: "Tag 0x%02X", tag)
            }
        }

        public var value: String {
            switch self {
            case .device(let s), .firmware(let s), .state(let s): s
            case .uptime(let s): Duration.text(seconds: Int(s))
            case .battery(let mv): String(format: "%.2f V", Double(mv) / 1000)
            case .error(let code): "\(code) (0x\(String(format: "%04X", code)))"
            case .id(let bytes), .deviceSpecific(_, let bytes): Hex.string(bytes)
            case .keyValue(_, let value): value
            case .temperature(let c): String(format: "%.2f °C", Double(c) / 100)
            }
        }
    }

    public init(fields: [Field]) {
        self.fields = fields
    }

    static func parseFields(_ b: [UInt8]) -> [Field] {
        var fields: [Field] = []
        var i = 0
        while i + 2 <= b.count {
            let tag = b[i], len = Int(b[i + 1])
            i += 2
            guard i + len <= b.count else { break }  // runs past the end: the report ends
            let v = Array(b[i..<i + len])
            i += len
            if let field = field(tag: tag, v) { fields.append(field) }
        }
        return fields
    }

    private static func field(tag: UInt8, _ v: [UInt8]) -> Field? {
        func text() -> String? { String(bytes: v, encoding: .utf8) }
        func u16() -> UInt16? { v.count == 2 ? UInt16(v[0]) | UInt16(v[1]) << 8 : nil }
        switch tag {
        case 0x01: return text().map(Field.device)
        case 0x02: return text().map(Field.firmware)
        case 0x03:
            guard v.count == 4 else { return nil }
            return .uptime(seconds: v.reversed().reduce(0) { $0 << 8 | UInt32($1) })
        case 0x04: return u16().map { .battery(millivolts: $0) }
        case 0x05: return text().map(Field.state)
        case 0x06: return u16().map(Field.error)
        case 0x07: return .id(v)
        case 0x08:
            guard let s = text() else { return nil }
            let parts = s.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return .keyValue(key: String(parts[0]), value: parts.count > 1 ? String(parts[1]) : "")
        case 0x09: return u16().map { .temperature(centiCelsius: Int16(bitPattern: $0)) }
        case 0x80...0xFF: return .deviceSpecific(tag: tag, v)
        default: return nil  // reserved: skipped
        }
    }
}

enum Hex {
    static func string(_ bytes: [UInt8]) -> String {
        bytes.isEmpty ? "(none)" : bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

enum Duration {
    static func text(seconds s: Int) -> String {
        switch s {
        case ..<60: "\(s) s"
        case ..<3600: "\(s / 60) min \(s % 60) s"
        case ..<86400: "\(s / 3600) h \(s % 3600 / 60) min"
        default: "\(s / 86400) d \(s % 86400 / 3600) h"
        }
    }
}
