import CoreFoundation
import Foundation

// The dynamic value model Meta's Bloks scripts run on. `BloksArray`/`BloksMap`/`BloksNode` are reference types on
// purpose: scripts mutate shared containers and compare them by identity, and `BloksMap` keeps insertion order.
// `BloksJson` controls exact bytes (scripts hash and compare them), so its formatter is reproduced precisely.

struct BloksError: Error { let message: String; init(_ message: String) { self.message = message } }

final class BloksArray {
    var items: [Any?]
    init(_ items: [Any?] = []) { self.items = items }
}

final class BloksMap {
    var pairs: [(Any?, Any?)] = []
    init(_ pairs: [(Any?, Any?)] = []) { for (key, value) in pairs { set(key, value) } }
    func get(_ key: Any?) -> Any? { pairs.first { Interpreter.equal($0.0, key) }?.1 }
    func has(_ key: Any?) -> Bool { pairs.contains { Interpreter.equal($0.0, key) } }
    func set(_ key: Any?, _ value: Any?) {
        if let i = pairs.firstIndex(where: { Interpreter.equal($0.0, key) }) { pairs[i].1 = value }
        else { pairs.append((key, value)) }
    }
    func remove(_ key: Any?) { pairs.removeAll { Interpreter.equal($0.0, key) } }
}

func blist(_ value: Any?) -> [Any?] { (value as? BloksArray)?.items ?? [] }

func bstr(_ value: Any?) -> String {
    guard let value else { return "null" }
    if let string = value as? String { return string }
    if let bool = value as? Bool { return bool ? "true" : "false" }
    if let array = value as? BloksArray { return "[" + array.items.map(bstr).joined(separator: ", ") + "]" }
    if let map = value as? BloksMap { return "{" + map.pairs.map { bstr($0.0) + "=" + bstr($0.1) }.joined(separator: ", ") + "}" }
    return String(describing: value)
}

func bint(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
func bnum(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }

func bflat(_ value: Any?) throws -> String {
    let map = BloksMap((value as? BloksMap)?.pairs.map { (bstr($0.0), bstr($0.1)) } ?? [])
    return try BloksJson.encode(map)
}

enum BloksJson {
    static func quote(_ string: String) -> String {
        // JSONSerialization is used only at this Apple boundary; never log the resulting bytes.
        let bytes = try? JSONSerialization.data(withJSONObject: [string], options: [.fragmentsAllowed, .withoutEscapingSlashes])
        let text = bytes.map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        return String(text.dropFirst().dropLast())
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static func encode(_ value: Any?, boolsAsInts: Bool = false, depth: Int = 0) throws -> String {
        guard depth < 128 else { throw BloksError("JSON nesting limit") }
        guard let value else { return "null" }
        if let string = value as? String { return quote(string) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return boolsAsInts ? (number.boolValue ? "1" : "0") : (number.boolValue ? "true" : "false")
            }
            return number.doubleValue.isFinite ? number.stringValue : "null"
        }
        if let array = value as? BloksArray {
            return "[" + (try array.items.map { try encode($0, boolsAsInts: boolsAsInts, depth: depth + 1) }).joined(separator: ",") + "]"
        }
        if let map = value as? BloksMap {
            return "{" + (try map.pairs.map { quote(bstr($0.0)) + ":" + (try encode($0.1, boolsAsInts: boolsAsInts, depth: depth + 1)) }).joined(separator: ",") + "}"
        }
        return quote(bstr(value))
    }

    static func decode(_ text: String) throws -> Any? {
        guard text.utf8.count <= 4_000_000 else { throw BloksError("Response size limit") }
        return try convert(JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed))
    }

    static func convert(_ value: Any, depth: Int = 0) throws -> Any? {
        guard depth < 128 else { throw BloksError("Payload nesting limit") }
        if value is NSNull { return nil }
        if let array = value as? [Any] { return BloksArray(try array.map { try convert($0, depth: depth + 1) }) }
        if let map = value as? [String: Any] { return BloksMap(try map.map { ($0.key, try convert($0.value, depth: depth + 1)) }) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            if !String(cString: number.objCType).contains("f") && !String(cString: number.objCType).contains("d") {
                let integer = number.int64Value
                return (Int64(Int32.min)...Int64(Int32.max)).contains(integer) ? Int32(integer) as Any : integer
            }
        }
        return value
    }
}

final class BloksNode {
    let type: Int
    let attrs: [Int: Any]
    init(_ type: Int, _ attrs: [Int: Any]) { self.type = type; self.attrs = attrs }
    subscript(_ key: Int) -> Any? { let value = attrs[key]; return value is NSNull ? nil : value }
}

final class BloksScript {
    let source: String
    private var parsed: Expr?
    init(_ source: String) { self.source = source }
    func expr() throws -> Expr {
        if let parsed { return parsed }
        let expr = try Lispy.parse(source)
        parsed = expr
        return expr
    }
}

struct ComponentQuery {
    let target: String?
    let appId: BloksScript?
    let params: BloksScript?
    let clientParams: BloksScript?
}

struct Variable {
    let id: String
    let type: String
    let initial: Any?
    let initialScript: BloksScript?
    let key: String?
    let mode: String?
}

final class BloksPayload {
    var tree: BloksNode?
    var action: BloksScript?
    var variables: [Variable] = []
    var scripts: [String: BloksScript] = [:]
    var embedded: [String: BloksPayload] = [:]
    var props: [String: String] = [:]
    var values: [String: BloksScript] = [:]
    var constants: [String: Any] = [:]
    var templates: [String: BloksNode] = [:]
    var componentQueries: [ComponentQuery] = []

    func withTree(_ root: BloksNode?) -> BloksPayload {
        let copy = BloksPayload()
        copy.tree = root
        copy.variables = variables
        copy.scripts = scripts
        copy.embedded = embedded
        copy.props = props
        copy.values = values
        copy.constants = constants
        copy.templates = templates
        copy.componentQueries = componentQueries
        return copy
    }

    static func parse(_ text: String) throws -> BloksPayload {
        guard text.utf8.count <= 4_000_000,
              let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { throw BloksError("Invalid payload") }
        return try of(object)
    }

    static func of(_ holder: [String: Any], depth: Int = 0) throws -> BloksPayload {
        guard depth < 32, let layout = holder["layout"] as? [String: Any], let p = layout["bloks_payload"] as? [String: Any]
        else { throw BloksError("Missing Bloks payload") }
        let out = BloksPayload()
        out.tree = try p["tree"].flatMap { try convert($0) as? BloksNode }
        out.action = (p["action"] as? String).map(BloksScript.init)
        for variable in p["data"] as? [[String: Any]] ?? [] {
            guard let id = variable["id"] else { continue }
            let data = variable["data"] as? [String: Any] ?? [:]
            out.variables.append(Variable(
                id: bstr(id),
                type: variable["type"] as? String ?? "",
                initial: try data["initial"].flatMap { try convert($0) },
                initialScript: (data["initial_lispy"] as? String).map(BloksScript.init),
                key: data["key"] as? String,
                mode: data["mode"] as? String
            ))
        }
        for (key, script) in p["ft"] as? [String: String] ?? [:] { out.scripts[key] = BloksScript(script) }
        for embedded in p["embedded_payloads"] as? [[String: Any]] ?? [] {
            if let id = embedded["id"], let holder = embedded["payload"] as? [String: Any] {
                out.embedded[bstr(id)] = try of(holder, depth: depth + 1)
            }
        }
        for prop in p["props"] as? [[String: Any]] ?? [] {
            if let name = prop["name"], let id = prop["id"] { out.props[bstr(name)] = bstr(id) }
        }
        for value in p["values"] as? [[String: Any]] ?? [] {
            if let id = value["id"], let expression = value["expression"] as? String { out.values[bstr(id)] = BloksScript(expression) }
        }
        if let constants = p["ct"] as? [String: Any] {
            for (key, value) in constants { out.constants[key] = try convert(value) ?? NSNull() }
        } else {
            for constant in p["ct"] as? [[String: Any]] ?? [] {
                if let name = constant["name"] ?? constant["id"] {
                    out.constants[bstr(name)] = try constant["value"].flatMap { try convert($0) } ?? NSNull()
                }
            }
        }
        for (id, tree) in p["templates"] as? [String: Any] ?? [:] { out.templates[id] = try convert(tree) as? BloksNode }
        for query in p["component_queries"] as? [[String: Any]] ?? [] {
            out.componentQueries.append(ComponentQuery(
                target: (query["targets"] as? [String: Any])?["component"].map(bstr),
                appId: (query["app_id_expr"] as? String).map(BloksScript.init),
                params: (query["params"] as? String).map(BloksScript.init),
                clientParams: (query["client_params"] as? String).map(BloksScript.init)
            ))
        }
        return out
    }

    static func convert(_ value: Any, depth: Int = 0) throws -> Any? {
        guard depth < 128 else { throw BloksError("Tree nesting limit") }
        if let string = value as? String { return Lispy.isScript(string) ? BloksScript(string) : string as Any }
        if let map = value as? [String: Any] {
            if map.count == 1, let key = map.keys.first, key.utf16.count == 1, let code = key.utf16.first, code >= 0x3000,
               let attrs = map[key] as? [String: Any] {
                var out: [Int: Any] = [:]
                for (attrKey, attrValue) in attrs {
                    let id = attrKey.utf16.count == 1 ? Int(attrKey.utf16.first!) : Int(attrKey) ?? -1
                    out[id] = try convert(attrValue, depth: depth + 1) ?? NSNull()
                }
                return BloksNode(Int(code), out)
            }
            return BloksMap(try map.map { ($0.key, try convert($0.value, depth: depth + 1)) })
        }
        if let array = value as? [Any] { return BloksArray(try array.map { try convert($0, depth: depth + 1) }) }
        return try BloksJson.convert(value)
    }
}

extension Array where Element == Any? {
    func at(_ index: Int) -> Any? { indices.contains(index) ? self[index] : nil }
}
