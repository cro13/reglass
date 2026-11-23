import Foundation

/// How the iPhone tools' definitions go over the wire.
///
/// Sorted by name, so the same tools always render the same bytes (tools come first in the cached prefix). Each tool
/// whose schema fits strict mode is sent with `strict: true`, so Claude's arguments always match the schema (grammar-
/// constrained sampling). Strict mode has hard limits per request (20 strict tools, 24 optional parameters, 16
/// union-typed parameters) and turns down whole requests over a keyword it doesn't support, so a tool is strict only
/// when its schema uses the supported subset and still fits the limits; the rest go as plain tools.
///
/// If the API turns the definitions down anyway, strict mode (then the iPhone tools altogether, for a conversation that
/// hasn't used one yet) is switched off until the next launch rather than failing every request. The log says so.
final class ClientTools: @unchecked Sendable {
    private let lock = NSLock()
    /// Off: the first request after the tool set changes waited 22–32 s on the device while the API
    /// compiled the strict grammars (cached for a day), which comes back daily and after every connector switch.
    /// The tools validate their own input, so plain schemas are the better trade for a voice assistant.
    private var strictAllowed = false
    private var toolsAllowed = true

    static let maxStrictTools = 20
    static let maxOptionalParameters = 24
    static let maxUnionParameters = 16

    /// The definitions for a conversation's first request.
    func render(_ definitions: [ToolDefinition]) -> [JSONValue] {
        let (strict, allowed) = lock.withLock { (strictAllowed, toolsAllowed) }
        guard allowed else { return [] }
        var strictCount = 0
        var optional = 0
        var unions = 0
        return definitions.sorted { $0.name < $1.name }.map { definition in
            var tool: [String: JSONValue] = [
                "name": .string(definition.name),
                "description": .string(definition.description),
                "input_schema": definition.inputSchema,
            ]
            if strict, let prepared = StrictSchema.prepare(definition.inputSchema),
               strictCount < Self.maxStrictTools,
               optional + prepared.optional <= Self.maxOptionalParameters,
               unions + prepared.unions <= Self.maxUnionParameters {
                strictCount += 1
                optional += prepared.optional
                unions += prepared.unions
                tool["input_schema"] = prepared.schema
                tool["strict"] = true
            }
            return .object(tool)
        }
    }

    /// A 400 for a request carrying `rendered`. Returns the definitions to retry with, or nil when the tools aren't to
    /// blame (or nothing is left to drop).
    func reject(_ rendered: [JSONValue], message: String, conversationUsedTools: Bool) -> [JSONValue]? {
        guard !rendered.isEmpty else { return nil }
        let lowered = message.lowercased()
        let sentStrict = rendered.contains { $0["strict"]?.bool == true }
        let aboutSchema = ["strict", "schema", "grammar", "compil", "additionalproperties", "optional param",
                           "too complex"].contains { lowered.contains($0) }
        if sentStrict, aboutSchema {
            lock.withLock { strictAllowed = false }
            AssistantLog.add("Tools: the API turned down strict tool schemas; sending them without strict mode")
            return rendered.map { tool in
                guard var object = tool.object else { return tool }
                object["strict"] = nil
                return .object(object)
            }
        }
        // A broken definition: drop the iPhone tools rather than fail every request. Not once Claude has used one,
        // because the history's tool calls need their definitions.
        if !conversationUsedTools, lowered.contains("input_schema") || lowered.contains("custom") {
            lock.withLock { toolsAllowed = false }
            AssistantLog.add("Tools: the API turned down a tool definition; answering without the iPhone tools "
                             + "until ReGlass restarts")
            return []
        }
        return nil
    }
}

/// The subset of JSON Schema strict tool use accepts, and what a schema costs against the per-request limits.
enum StrictSchema {
    struct Prepared {
        /// The schema with `additionalProperties: false` on every object, as strict mode requires.
        let schema: JSONValue
        /// Properties not listed in `required`, over every object in the schema.
        let optional: Int
        /// Properties typed with `anyOf` or a type array.
        let unions: Int
    }

    private static let allowedKeys: Set<String> = [
        "type", "description", "title", "properties", "required", "enum", "const", "items", "anyOf", "format",
        "default", "additionalProperties", "minItems",
    ]
    private static let formats: Set<String> = [
        "date-time", "time", "date", "duration", "email", "hostname", "uri", "ipv4", "ipv6", "uuid",
    ]

    /// Nil when the schema uses anything strict mode would turn down (numeric or string limits, patterns, `$ref`,
    /// `allOf`, open objects, ...): the tool then goes without strict mode.
    static func prepare(_ schema: JSONValue) -> Prepared? {
        var optional = 0
        var unions = 0
        guard let prepared = node(schema, optional: &optional, unions: &unions), prepared["type"]?.string == "object" else {
            return nil
        }
        return Prepared(schema: prepared, optional: optional, unions: unions)
    }

    private static func node(_ value: JSONValue, optional: inout Int, unions: inout Int) -> JSONValue? {
        guard var object = value.object, Set(object.keys).isSubset(of: allowedKeys) else { return nil }
        if let format = object["format"] {
            guard let name = format.string, formats.contains(name) else { return nil }
        }
        if let minItems = object["minItems"] {
            guard let count = minItems.int, count == 0 || count == 1 else { return nil }
        }
        if let values = object["enum"] {
            guard let list = values.array, !list.isEmpty, list.allSatisfy(isScalar) else { return nil }
        }
        if let constant = object["const"], !isScalar(constant) { return nil }
        if let choices = object["anyOf"] {
            guard let list = choices.array, !list.isEmpty else { return nil }
            var prepared: [JSONValue] = []
            for choice in list {
                guard let next = node(choice, optional: &optional, unions: &unions) else { return nil }
                prepared.append(next)
            }
            object["anyOf"] = .array(prepared)
        }
        if let items = object["items"] {
            guard let next = node(items, optional: &optional, unions: &unions) else { return nil }
            object["items"] = next
        }

        let types: [String]
        switch object["type"] {
        case .string(let type)?: types = [type]
        case .array(let list)?:
            types = list.compactMap(\.string)
            guard types.count == list.count, !types.isEmpty else { return nil }
        case nil: types = []
        default: return nil
        }

        if types.contains("object") {
            if let extra = object["additionalProperties"], extra != .bool(false) { return nil }
            let properties = object["properties"]?.object ?? [:]
            if object["properties"] != nil, object["properties"]?.object == nil { return nil }
            let required = object["required"].map { $0.array?.compactMap(\.string) } ?? []
            guard let required, Set(required).isSubset(of: properties.keys) else { return nil }
            var prepared: [String: JSONValue] = [:]
            for (name, property) in properties {
                guard let next = node(property, optional: &optional, unions: &unions) else { return nil }
                if next["anyOf"] != nil || next["type"]?.array != nil { unions += 1 }
                prepared[name] = next
            }
            optional += properties.count - Set(required).count
            object["properties"] = .object(prepared)
            object["additionalProperties"] = false
        } else if object["properties"] != nil || object["required"] != nil || object["additionalProperties"] != nil {
            return nil
        }
        return .object(object)
    }

    private static func isScalar(_ value: JSONValue) -> Bool {
        switch value {
        case .string, .int, .double, .bool, .null: return true
        case .array, .object: return false
        }
    }
}
