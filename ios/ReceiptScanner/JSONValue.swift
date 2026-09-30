import Foundation

/// Order-preserving JSON value. `data/expenses.json` is written by the web app with
/// `JSON.stringify(x, null, 2)`; parsing into this type and serializing with `pretty()`
/// reproduces that byte-for-byte so saves from the phone don't churn the whole file.
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    /// Keeps the original literal so existing numbers are re-emitted unchanged.
    case number(Double, literal: String)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.number(x, _), .number(y, _)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    static func num(_ d: Double) -> JSONValue {
        let lit: String
        if d == d.rounded(), abs(d) < 1e15 { lit = String(Int64(d)) } else { lit = "\(d)" }
        return .number(d, literal: lit)
    }

    subscript(key: String) -> JSONValue? {
        if case let .object(pairs) = self { return pairs.first { $0.0 == key }?.1 }
        return nil
    }

    /// Copy of an object with `key` set (replaced in place, or appended at the end).
    func setting(_ key: String, _ value: JSONValue) -> JSONValue {
        guard case var .object(pairs) = self else { return self }
        if let i = pairs.firstIndex(where: { $0.0 == key }) { pairs[i].1 = value } else { pairs.append((key, value)) }
        return .object(pairs)
    }

    /// Copy of an object without `key`.
    func removing(_ key: String) -> JSONValue {
        guard case let .object(pairs) = self else { return self }
        return .object(pairs.filter { $0.0 != key })
    }

    var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    var doubleValue: Double? { if case let .number(d, _) = self { return d }; return nil }
    var boolValue: Bool? { if case let .bool(b) = self { return b }; return nil }

    // MARK: Serialize (matches JSON.stringify(v, null, 2))

    func pretty() -> String {
        var out = ""
        write(&out, indent: 0)
        return out
    }

    private func write(_ out: inout String, indent: Int) {
        switch self {
        case .null: out += "null"
        case let .bool(b): out += b ? "true" : "false"
        case let .number(_, lit): out += lit
        case let .string(s): JSONValue.writeString(s, &out)
        case let .array(items):
            if items.isEmpty { out += "[]"; return }
            let pad = String(repeating: " ", count: indent + 2)
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += pad
                item.write(&out, indent: indent + 2)
                out += i < items.count - 1 ? ",\n" : "\n"
            }
            out += String(repeating: " ", count: indent) + "]"
        case let .object(pairs):
            if pairs.isEmpty { out += "{}"; return }
            let pad = String(repeating: " ", count: indent + 2)
            out += "{\n"
            for (i, (k, v)) in pairs.enumerated() {
                out += pad
                JSONValue.writeString(k, &out)
                out += ": "
                v.write(&out, indent: indent + 2)
                out += i < pairs.count - 1 ? ",\n" : "\n"
            }
            out += String(repeating: " ", count: indent) + "}"
        }
    }

    private static func writeString(_ s: String, _ out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }

    // MARK: Parse

    struct ParseError: LocalizedError {
        let message: String
        var errorDescription: String? { "JSON parse error: \(message)" }
    }

    static func parse(_ data: Data) throws -> JSONValue {
        var p = Parser(bytes: [UInt8](data))
        p.skipWS()
        let v = try p.value()
        p.skipWS()
        guard p.i == p.bytes.count else { throw ParseError(message: "trailing data at \(p.i)") }
        return v
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        mutating func skipWS() {
            while i < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) { i += 1 }
        }

        mutating func expect(_ lit: String) throws {
            for b in lit.utf8 {
                guard i < bytes.count, bytes[i] == b else { throw ParseError(message: "expected \(lit) at \(i)") }
                i += 1
            }
        }

        mutating func value() throws -> JSONValue {
            guard i < bytes.count else { throw ParseError(message: "unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return try number()
            }
        }

        mutating func object() throws -> JSONValue {
            i += 1
            var pairs: [(String, JSONValue)] = []
            skipWS()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
            while true {
                skipWS()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw ParseError(message: "expected key at \(i)") }
                let k = try string()
                skipWS()
                try expect(":")
                skipWS()
                pairs.append((k, try value()))
                skipWS()
                guard i < bytes.count else { throw ParseError(message: "unexpected end in object") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
                throw ParseError(message: "expected , or } at \(i)")
            }
        }

        mutating func array() throws -> JSONValue {
            i += 1
            var items: [JSONValue] = []
            skipWS()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                skipWS()
                items.append(try value())
                skipWS()
                guard i < bytes.count else { throw ParseError(message: "unexpected end in array") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw ParseError(message: "expected , or ] at \(i)")
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16)
            else { throw ParseError(message: "bad \\u escape at \(i)") }
            i += 4
            return v
        }

        mutating func string() throws -> String {
            i += 1
            var buf: [UInt8] = []
            while true {
                guard i < bytes.count else { throw ParseError(message: "unterminated string") }
                let b = bytes[i]
                i += 1
                if b == UInt8(ascii: "\"") { break }
                if b != UInt8(ascii: "\\") { buf.append(b); continue }
                guard i < bytes.count else { throw ParseError(message: "bad escape") }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): buf.append(0x22)
                case UInt8(ascii: "\\"): buf.append(0x5C)
                case UInt8(ascii: "/"): buf.append(0x2F)
                case UInt8(ascii: "b"): buf.append(0x08)
                case UInt8(ascii: "f"): buf.append(0x0C)
                case UInt8(ascii: "n"): buf.append(0x0A)
                case UInt8(ascii: "r"): buf.append(0x0D)
                case UInt8(ascii: "t"): buf.append(0x09)
                case UInt8(ascii: "u"):
                    var cp = try hex4()
                    if (0xD800...0xDBFF).contains(cp), i + 6 <= bytes.count,
                       bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let lo = try hex4()
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                    }
                    buf.append(contentsOf: Array(String(Unicode.Scalar(cp) ?? "\u{FFFD}").utf8))
                default: throw ParseError(message: "bad escape at \(i)")
                }
            }
            return String(decoding: buf, as: UTF8.self)
        }

        mutating func number() throws -> JSONValue {
            let start = i
            while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
            let lit = String(decoding: bytes[start..<i], as: UTF8.self)
            guard let d = Double(lit) else { throw ParseError(message: "bad number at \(start)") }
            return .number(d, literal: lit)
        }
    }
}
