import Foundation

/// A parsed Bloks script: either a call (function id, arguments, and an optional local-script name) or a literal.
indirect enum Expr {
    case call(Int, [Expr], String?)
    case lit(Any?)
}

/// The function-id ↔ name table generated from the user's Meta AI APK.
enum Functions {
    private static let table: (byID: [Int: String], byName: [String: Int])? = {
        guard let url = AccountResources.bloksFunctionMap,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var byID: [Int: String] = [:]
        var byName: [String: Int] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let id = Int(parts[0]), id > 0,
                  !parts[1].contains(where: \.isWhitespace) else { return nil }
            let name = String(parts[1])
            guard byID.updateValue(name, forKey: id) == nil,
                  byName.updateValue(id, forKey: name) == nil else { return nil }
        }
        return byID.isEmpty ? nil : (byID, byName)
    }()
    static var isAvailable: Bool { table != nil }
    static func id(_ name: String) -> Int? { table?.byName[name] }
    static func name(_ id: Int) -> String { table?.byID[id] ?? "unknown_function_\(id)" }
}

/// The bounded reader for Meta's Lisp-like script syntax. Malformed or unknown scripts throw rather than run.
enum Lispy {
    static func isScript(_ text: String) -> Bool { text.hasPrefix("\t(") }

    static func parse(_ source: String) throws -> Expr {
        let reader = Reader(source)
        let expr = try reader.read(0)
        reader.skipSpace()
        guard reader.at == reader.text.count else { throw BloksError("Trailing script data") }
        return expr
    }

    private final class Reader {
        let text: [UInt16]
        var at = 0
        var count = 0
        init(_ text: String) { self.text = Array(text.utf16) }

        func isWhite(_ c: UInt16) -> Bool { [32, 9, 10, 13, 44, 0xfeff].contains(c) }
        func skipSpace() { while at < text.count && isWhite(text[at]) { at += 1 } }

        func atom() throws -> String {
            let start = at
            while at < text.count && !isWhite(text[at]) && ![40, 41, 12].contains(text[at]) { at += 1 }
            guard at > start else { throw BloksError("Empty script atom") }
            return String(decoding: text[start..<at], as: UTF16.self)
        }

        func read(_ depth: Int) throws -> Expr {
            count += 1
            skipSpace()
            guard depth < 128, count < 100_000, at < text.count, text.count < 2_000_000 else { throw BloksError("Script parse limit") }
            let c = text[at]
            if c == 40 { // (
                at += 1
                skipSpace()
                let head = try atom()
                var args: [Expr] = []
                while true {
                    skipSpace()
                    guard at < text.count else { throw BloksError("Unclosed script") }
                    if text[at] == 41 { at += 1; break } // )
                    args.append(try read(depth + 1))
                }
                if head.hasPrefix("#") { return .call(-1, args, String(head.dropFirst())) }
                guard let id = (head.contains(".") || head == "null") ? Functions.id(head) : Int(head, radix: 36) else {
                    throw BloksError("Unknown script head")
                }
                return .call(id, args, nil)
            }
            if c == 34 || c == 39 { // " or '
                at += 1
                var out: [UInt16] = []
                while at < text.count {
                    let ch = text[at]; at += 1
                    if ch == c { return .lit(String(decoding: out, as: UTF16.self)) }
                    if ch != 92 { out.append(ch); continue } // \
                    guard at < text.count else { throw BloksError("Unclosed escape") }
                    let escape = text[at]; at += 1
                    if escape == 117 { // u
                        guard at + 4 <= text.count, let hex = UInt16(String(decoding: text[at..<at + 4], as: UTF16.self), radix: 16) else {
                            throw BloksError("Invalid Unicode escape")
                        }
                        out.append(hex); at += 4
                    } else {
                        out.append([110: 10, 116: 9, 114: 13, 98: 8, 102: 12][escape] ?? escape)
                    }
                }
                throw BloksError("Unclosed string")
            }
            let word = try atom()
            if word == "null" { return .lit(nil) }
            if word == "true" { return .lit(true) }
            if word == "false" { return .lit(false) }
            if let integer = Int64(word) {
                return .lit((Int64(Int32.min)...Int64(Int32.max)).contains(integer) ? Int32(integer) as Any : integer)
            }
            if let double = Double(word) { return .lit(double) }
            return .lit(word)
        }
    }
}
