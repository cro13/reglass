import CoreFoundation
import Foundation

/// The evaluation context a script runs in: how to resolve a named local script, and how to reach the session's
/// action table for anything the interpreter itself doesn't implement.
@MainActor
protocol BloksContext: AnyObject {
    func script(_ id: String) throws -> BloksLambda
    func extensionCall(_ interpreter: Interpreter, _ name: String, _ args: [Any?]) throws -> Any?
}

final class BloksLambda {
    let body: Expr
    let bound: [Any?]
    let ctx: BloksContext
    init(_ body: Expr, _ bound: [Any?] = [], _ ctx: BloksContext) { self.body = body; self.bound = bound; self.ctx = ctx }
}

final class BloksRef {
    var value: Any?
    init(_ value: Any?) { self.value = value }
}

private struct PatternMark { let value: Any?; let body: Expr }
private struct DefaultMark { let body: Expr }

/// The bounded evaluator for Meta's `bk.action.*` opcodes. Resource and instruction limits keep a hostile script
/// from running away; password encryption and other unsupported auth opcodes fail closed in `BloksActions`.
///
/// The evaluator runs on the main actor (it drives the session's action table). The pure value helpers at the
/// bottom are `nonisolated`, since the value model and the off-actor HTTP client use them too.
@MainActor
final class Interpreter {
    private var frames: [BloksArray] = []
    private var remaining = 0
    private var missingEntryNotes = 0

    /// Logs a read of a missing list item or map key: the container's shape and the key's, never values.
    /// A field-style key (lower-case letters, digits, underscores) is named; any other key is only measured.
    private func noteMissingEntry(_ container: Any?, _ key: Any?) {
        guard missingEntryNotes < 12 else { return }
        missingEntryNotes += 1
        let shape: String
        if let map = container as? BloksMap { shape = "a map of \(map.pairs.count)" }
        else if let array = container as? BloksArray { shape = "a list of \(array.items.count)" }
        else if container is String { shape = "text" }
        else if container == nil { shape = "nothing" }
        else { shape = "a \(type(of: container!))" }
        let what: String
        if let text = key as? String {
            let fieldLike = text.count <= 48 && text.first?.isLowercase == true
                && text.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") }
            what = fieldLike ? "key '\(text)'" : "a \(text.count)-character key"
        } else if key is NSNumber {
            what = "index \(bint(key))"
        } else {
            what = key == nil ? "no key" : "a \(type(of: key!)) key"
        }
        kitLog("account", "sign-in script read a missing entry (\(what) in \(shape)); treated as empty")
    }

    private func framed(_ args: [Any?], _ block: () throws -> Any?) throws -> Any? {
        guard frames.count < 128 else { throw BloksError("Script recursion limit") }
        if frames.isEmpty { remaining = 100_000 }
        frames.append(BloksArray(args))
        defer { frames.removeLast() }
        return try block()
    }

    func run(_ expr: Expr, _ ctx: BloksContext, _ args: [Any?] = []) throws -> Any? { try framed(args) { try eval(expr, ctx) } }

    func call(_ fn: Any?, _ args: [Any?] = []) throws -> Any? {
        guard let lambda = fn as? BloksLambda else { throw BloksError("Expected function") }
        return try framed(lambda.bound + args) { try eval(lambda.body, lambda.ctx) }
    }

    func eval(_ expr: Expr, _ ctx: BloksContext) throws -> Any? {
        remaining -= 1
        guard remaining > 0 else { throw BloksError("Script instruction limit") }
        switch expr {
        case .lit(let value):
            return value
        case .call(let fn, let a, let local):
            if let local { return try call(ctx.script(local), a.map { try eval($0, ctx) }) }
            let name = Functions.name(fn)
            func arg(_ i: Int) throws -> Any? { i < a.count ? try eval(a[i], ctx) : nil }
            func body(_ i: Int) throws -> Expr {
                guard i < a.count else { throw BloksError("Missing script body") }
                if case .call(let f, let args, nil) = a[i], Functions.name(f) == "bk.action.core.FuncConst", let first = args.first { return first }
                return a[i]
            }
            switch name {
            case "bk.action.core.FuncConst": guard let first = a.first else { throw BloksError("Missing function body") }; return BloksLambda(first, [], ctx)
            case "bk.action.core.Apply": return try call(arg(0), a.dropFirst().map { try eval($0, ctx) })
            case "bk.action.core.GetArg": let i = bint(try arg(0)); return frames.last?.items.at(i)
            case "bk.action.core.SetArg":
                let i = bint(try arg(0)); guard i >= 0, i < 10_000, let frame = frames.last else { throw BloksError("Frame index limit") }
                let value = try arg(1); while frame.items.count <= i { frame.items.append(nil) }; frame.items[i] = value; return nil
            case "bk.action.core.TakeLast": var value: Any?; for e in a { value = try eval(e, ctx) }; return value
            case "bk.action.core.If": return try arg(Self.truthy(arg(0)) ? 1 : 2)
            case "bk.action.core.Coalesce": for e in a { if let value = try eval(e, ctx) { return value } }; return nil
            case "bk.action.core.Pattern": return PatternMark(value: try arg(0), body: try body(1))
            case "bk.action.core.Default": return DefaultMark(body: try body(0))
            case "bk.action.core.Match":
                let value = try arg(0), patterns = blist(try arg(1))
                if let hit = patterns.compactMap({ $0 as? PatternMark }).first(where: { Self.equal($0.value, value) }) { return try eval(hit.body, ctx) }
                guard let other = try arg(2) as? DefaultMark else { throw BloksError("Missing match default") }; return try eval(other.body, ctx)
            case "bk.action.core.While": let cond = try body(0), loop = try body(1); while Self.truthy(try eval(cond, ctx)) { _ = try eval(loop, ctx) }; return nil
            case "bk.action.mins.ArgCount": return Int32(frames.last?.items.count ?? 0)
            case "bk.action.bloks.debug.Breakpoint": return nil
            case "bk.action.i64.Const": return Self.i64(try arg(0))
            case "bk.action.i32.Const": return Self.i32(try arg(0))
            case "bk.action.f32.Const", "bk.action.f64.Const": return Self.norm(bnum(try arg(0)))
            case "bk.action.bool.Const": return Self.truthy(try arg(0))
            default: return try builtin(name, a.map { try eval($0, ctx) }, ctx)
            }
        }
    }

    private func builtin(_ name: String, _ v: [Any?], _ ctx: BloksContext) throws -> Any? {
        func x(_ i: Int) -> Any? { v.at(i) }
        func s(_ i: Int) -> String { x(i) as? String ?? "" }
        func n(_ i: Int) -> Double { bnum(x(i)) }
        func i(_ at: Int) -> Int { bint(x(at)) }
        func l(_ at: Int) -> [Any?] { blist(x(at)) }
        func m(_ at: Int) -> BloksMap? { x(at) as? BloksMap }
        func pred(_ f: Any?, _ a: [Any?]) throws -> Bool { Self.truthy(try call(f, a)) }
        switch name {
        case "null": return x(0) == nil
        case "bk.action.array.Make": return BloksArray(v)
        case "bk.action.array.Get", "bk.action.map.Get", "bk.action.mins.GetByValOr":
            if let map = m(0) { if map.has(x(1)) { return map.get(x(1)) } }
            else if let array = x(0) as? BloksArray, array.items.indices.contains(i(1)) { return array.items[i(1)] }
            else if let string = x(0) as? String, Array(string.utf16).indices.contains(i(1)) { return Int32(Array(string.utf16)[i(1)]) }
            // Sign-in scripts check optional fields against null. Log a missing entry and return nil so those
            // checks can run.
            if name == "bk.action.array.Get" { noteMissingEntry(x(0), x(1)); return nil }
            return x(2)
        case "bk.action.array.Length", "bk.action.string.Length": return Int32((x(0) as? BloksArray)?.items.count ?? m(0)?.pairs.count ?? s(0).utf16.count)
        case "bk.action.array.Map": return BloksArray(try l(0).enumerated().map { try call(x(1), [Int32($0.offset), $0.element]) })
        case "bk.action.array.Filter": return BloksArray(try l(0).filter { try pred(x(1), [$0]) })
        case "bk.action.array.FindIndex": return Int32(try l(0).firstIndex { try pred(x(1), [$0]) } ?? -1)
        case "bk.action.array.Reduce": var acc = x(2); for (idx, value) in l(0).enumerated() { acc = try call(x(1), [acc, value, Int32(idx)]) }; return acc
        case "bk.action.array.Concat": return BloksArray(v.flatMap(blist))
        case "bk.action.array.Append": return BloksArray(l(0) + [x(1)])
        case "bk.action.array.Slice", "bk.action.js.array.Slice":
            let a = l(0), count = a.count
            func clamp(_ p: Int) -> Int { min(count, max(0, p < 0 && name.contains("js.") ? count + p : p)) }
            let start = clamp(i(1)), end = clamp(x(2) == nil ? count : i(2)); return BloksArray(start < end ? Array(a[start..<end]) : [])
        case "bk.action.array.Contains": return x(0) is String ? s(0).contains(bstr(x(1))) : (m(0)?.pairs.map { $0.1 } ?? l(0)).contains { Self.equal($0, x(1)) }
        case "bk.action.array.Put", "bk.action.mins.PutByVal": try put(x(0), x(1), x(2)); return nil
        case "bk.action.array.Remove": if let array = x(0) as? BloksArray, array.items.indices.contains(i(1)) { array.items.remove(at: i(1)) }; return nil
        case "bk.action.array.Update": guard l(1).count == l(2).count else { throw BloksError("Mismatched array update") }; for (key, value) in zip(l(1), l(2)) { try put(x(0), key, value) }; return nil
        case "bk.action.array.SortedArray": return BloksArray(try l(0).sorted { bint(try call(x(1), [$0, $1])) < 0 })
        case "bk.action.array.Max": return l(0).map(bnum).max()
        case "bk.action.array.Min": return l(0).map(bnum).min()
        case "bk.action.map.Make": guard l(0).count == l(1).count else { throw BloksError("Mismatched map") }; return BloksMap(Array(zip(l(0), l(1))))
        case "bk.action.map.Merge": let map = BloksMap(); for a in v { for (key, value) in (a as? BloksMap)?.pairs ?? [] { map.set(key, value) } }; return map
        case "bk.action.map.Keys": return BloksArray(m(0)?.pairs.map { $0.0 } ?? [])
        case "bk.action.map.Values": return BloksArray(m(0)?.pairs.map { $0.1 } ?? [])
        case "bk.action.map.Remove", "bk.action.mins.DelByVal": m(0)?.remove(x(1)); return nil
        case "bk.action.map.Update": for (key, value) in m(1)?.pairs ?? [] { m(0)?.set(key, value) }; return nil
        case "bk.action.map.Filter": let map = BloksMap(); for (key, value) in m(0)?.pairs ?? [] { if try pred(x(1), [key, value]) { map.set(key, value) } }; return map
        case "bk.action.mins.InByVal": return m(1)?.has(x(0)) ?? l(1).indices.contains(i(0))
        case "bk.action.mins.TypeOf": return Self.typeOf(x(0))
        case "bk.action.mins.AssertType": let type = Self.typeOf(x(0)); guard type == i(1) || i(1) == 100 && [3, 4].contains(type) else { throw BloksError("Type assertion failed") }; return x(0)
        case "bk.action.mins.ToBool": return Self.truthy(x(0))
        case "bk.action.mins.ToInt32", "bk.action.mins.Trunc", "bk.action.i32.Convert": return Self.i32(x(0))
        case "bk.action.i64.Convert": return Self.i64(x(0))
        case "bk.action.f32.Convert": return Self.norm(n(0))
        case "bk.action.mins.Raise": throw BloksError("Server script raised an error (details withheld)")
        case "bk.action.mins.BinAsr": return Self.i32(x(0)) >> (Self.i32(x(1)) & 31)
        case "bk.action.mins.BinNot": return ~Self.i32(x(0))
        case "bk.action.mins.BinShl": return Self.i32(x(0)) &<< (Self.i32(x(1)) & 31)
        case "bk.action.mins.BinShr": return Self.norm(Double(UInt32(bitPattern: Self.i32(x(0))) >> UInt32(Self.i32(x(1)) & 31)))
        case "bk.action.mins.BinXor": return Self.i32(x(0)) ^ Self.i32(x(1))
        case "bk.action.mins.IMul": return Self.i32(x(0)) &* Self.i32(x(1))
        case "bk.action.mins.Int64And": return Self.i64(x(0)) & Self.i64(x(1))
        case "bk.action.mins.Int64Or": return Self.i64(x(0)) | Self.i64(x(1))
        case "bk.action.mins.Int64Xor": return Self.i64(x(0)) ^ Self.i64(x(1))
        case "bk.action.mins.Int64Not": return ~Self.i64(x(0))
        case "bk.action.mins.Int64Shl": return Self.i64(x(0)) &<< (Self.i64(x(1)) & 63)
        case "bk.action.mins.Int64Asr": return Self.i64(x(0)) >> (Self.i64(x(1)) & 63)
        case "bk.action.mins.Int64Shr": return Int64(bitPattern: UInt64(bitPattern: Self.i64(x(0))) >> UInt64(Self.i64(x(1)) & 63))
        case "bk.action.mins.Int64Mod": let d = Self.i64(x(1)), a = Self.i64(x(0)); guard d != 0 else { throw BloksError("Division by zero") }; return a == .min && d == -1 ? 0 : a % d
        case "bk.action.mins.ContainerClone", "bk.action.mins.ImmutableClone": if let array = x(0) as? BloksArray { return BloksArray(array.items) }; if let map = m(0) { return BloksMap(map.pairs) }; return x(0)
        case "bk.action.mins.VectorAppend": guard let array = x(0) as? BloksArray, array.items.count < 10_000 else { throw BloksError("Array size limit") }; array.items.append(x(1)); return nil
        case "bk.action.mins.CallRuntime": return try runtime(i(0), Array(v.dropFirst()))
        case "bk.action.core.AsNonnull": guard let value = x(0) else { throw BloksError("Unexpected null") }; return value
        case "bk.action.core.Let": return x(0) == nil ? nil : try call(x(1), [x(0)])
        case "bk.action.function.BindWithArrayV2": guard let f = x(0) as? BloksLambda else { throw BloksError("Bind expected function") }; return l(1).isEmpty ? f : BloksLambda(f.body, l(1), f.ctx)
        case "data.Get": return (x(0) as? BloksNode)?[i(1)]
        case "pando.As": return m(0)?.get(x(1)) == nil ? nil : m(0)
        case "pando.Read", "pando.Require": var cur = x(0); for key in v.dropFirst() { cur = (cur as? BloksMap)?.get(key); if cur == nil && name == "pando.Require" { throw BloksError("Missing Pando field") } }; return cur
        case "bk.action.react.NormalizeChildren": let a = x(0) is BloksArray ? l(0) : [x(0)]; return BloksArray(a.filter { $0 is BloksNode || $0 is BloksSession.Instance })
        case "bk.action.string.Concat": if x(0) is String && x(1) is String { return s(0) + s(1) }; return Self.arith(x(0), x(1), "+")
        case "bk.action.string.ValueOfNumber": return bstr(x(0))
        case "bk.action.string.ValueOfNumberInBase": guard (2...36).contains(i(1)) else { throw BloksError("Invalid number base") }; return String(Self.i64(x(0)), radix: i(1))
        case "bk.action.string.JsonEncode", "bk.action.string.JsonEncodeV2", "bk.action.string.JsonEncodeV3": if x(0) == nil { return "" }; if x(0) is BloksArray || x(0) is BloksMap { return try BloksJson.encode(x(0), boolsAsInts: !name.hasSuffix("V3")) }; return bstr(x(0))
        case "bk.action.string.JsonDecode", "bk.action.string.JsonDecodeArray": return try BloksJson.decode(s(0))
        case "bk.action.string.Join": return l(1).map(bstr).joined(separator: s(0))
        case "bk.action.string.Contains": return s(0).contains(s(1))
        case "bk.action.string.StartsWith": return s(0).hasPrefix(s(1))
        case "bk.action.string.ToLowerCase": return s(0).lowercased()
        case "bk.action.string.ToUpperCase": return s(0).uppercased()
        case "bk.action.string.Trim", "bk.action.js.string.Trim": return s(0).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}\u{a0}")))
        case "bk.action.string.SplitWithString": return BloksArray(s(0).components(separatedBy: s(1)))
        case "bk.action.string.MatchesRegex": let re = try NSRegularExpression(pattern: s(1)); return re.firstMatch(in: s(0), range: NSRange(location: 0, length: s(0).utf16.count))?.range == NSRange(location: 0, length: s(0).utf16.count)
        case "bk.action.string.Replace": let re = try NSRegularExpression(pattern: s(1)), range = NSRange(location: 0, length: s(0).utf16.count); if Self.truthy(x(3)), let hit = re.firstMatch(in: s(0), range: range) { return re.stringByReplacingMatches(in: s(0), range: hit.range, withTemplate: s(2)) }; return re.stringByReplacingMatches(in: s(0), range: range, withTemplate: s(2))
        case "bk.action.string.ReplaceAll", "bk.action.js.string.ReplaceAll": return s(0).replacingOccurrences(of: s(1), with: s(2))
        case "bk.action.js.string.Replace": if let range = s(0).range(of: s(1)) { return s(0).replacingCharacters(in: range, with: s(2)) }; return s(0)
        case "bk.action.string.AsInteger": return Int32(s(0).trimmingCharacters(in: .whitespacesAndNewlines))
        case "bk.action.string.AsLong": return Int64(s(0).trimmingCharacters(in: .whitespacesAndNewlines))
        case "bk.action.string.Base64Encode": return Data(s(0).utf8).base64EncodedString()
        case "bk.action.string.ParseUrl":
            let url = URLComponents(string: s(0)), params = BloksMap(); for item in url?.queryItems ?? [] { if !params.has(item.name) { params.set(item.name, item.value ?? "") } }
            return BloksMap([("scheme", url?.scheme), ("host", url?.host), ("port", url?.port), ("path", url?.path), ("url_params", params), ("fragment", url?.fragment)])
        case "bk.action.string.EncryptPassword": throw BloksError("Password login is outside this email-code implementation. Cancel and use Meta AI if required.")
        case "bk.action.js.string.CharAt", "bk.action.js.string.CharCodeAt": let a = Array(s(0).utf16); guard a.indices.contains(i(1)) else { return name.hasSuffix("CharAt") ? "" as Any : Double.nan }; return name.hasSuffix("CharAt") ? String(decoding: [a[i(1)]], as: UTF16.self) as Any : Int32(a[i(1)])
        case "bk.action.js.string.Slice", "bk.action.js.string.Substring":
            let a = Array(s(0).utf16), count = a.count
            func clamp(_ p: Int) -> Int { min(count, max(0, p < 0 && name.hasSuffix("Slice") ? count + p : p)) }
            let start = clamp(i(1)), end = clamp(x(2) == nil ? count : i(2)), lo = name.hasSuffix("Substring") ? min(start, end) : start, hi = name.hasSuffix("Substring") ? max(start, end) : max(start, end)
            return String(decoding: a[lo..<hi], as: UTF16.self)
        case "bk.action.js.string.IndexOf", "bk.action.js.string.LastIndexOf": let string = s(0) as NSString, range = NSRange(location: 0, length: string.length); let r = string.range(of: s(1), options: name.contains("Last") ? .backwards : [], range: range); return Int32(r.location == NSNotFound ? -1 : r.location)
        case "bk.action.js.string.Repeat": guard (0...1000).contains(i(1)), s(0).utf8.count * i(1) < 1_000_000 else { throw BloksError("String size limit") }; return String(repeating: s(0), count: i(1))
        case "bk.action.js.number.IsInteger": return n(0).isFinite && n(0).rounded(.towardZero) == n(0)
        case "bk.action.js.array.IndexOf", "bk.action.js.array.LastIndexOf": let a = l(0), start = x(2) == nil ? (name.contains("Last") ? a.count - 1 : 0) : (i(2) < 0 ? max(0, a.count + i(2)) : i(2)); let ids = name.contains("Last") ? Array(a.indices.reversed()).filter { $0 <= start } : Array(a.indices).filter { $0 >= start }; return Int32(ids.first { Self.equal(a[$0], x(1), strict: true) } ?? -1)
        case "bk.action.js.array.Find", "bk.action.js.array.FindIndex": for (idx, value) in l(0).enumerated() { if try pred(x(1), [value, Int64(idx), x(0)]) { return name.hasSuffix("Find") ? value : Int64(idx) } }; return name.hasSuffix("Find") ? nil : Int64(-1)
        case "bk.action.js.array.At": let a = l(0); return a.at(i(1) < 0 ? a.count + i(1) : i(1))
        case "bk.action.js.array.Join": return l(0).map { $0 == nil ? "" : bstr($0) }.joined(separator: x(1) == nil ? "," : bstr(x(1)))
        case "bk.action.js.syntax.StrictEqual": return Self.equal(x(0), x(1), strict: true)
        case "bk.action.bool.Not": return !Self.truthy(x(0))
        case "bk.action.bool.Or": return (Self.i32(x(0)) | Self.i32(x(1))) != 0
        case "bk.action.bool.And": return (Self.i32(x(0)) & Self.i32(x(1))) != 0
        case "bk.action.mins.Ge", "bk.action.mins.Le": return name.hasSuffix("Ge") ? Self.compare(x(0), x(1)) >= 0 : Self.compare(x(0), x(1)) <= 0
        case "bk.action.i32.And": return Self.i32(x(0)) & Self.i32(x(1))
        case "bk.action.i32.Or": return Self.i32(x(0)) | Self.i32(x(1))
        case "bk.action.i64.Div": let a = Self.i64(x(0)), d = Self.i64(x(1)); guard d != 0 else { throw BloksError("Division by zero") }; return a == .min && d == -1 ? Int64.min : a / d
        case "bk.action.i32.Rand": return Self.norm((n(0) + (n(1) - n(0)) * Double.random(in: 0..<1)).rounded(.towardZero))
        case "bk.action.f32.Log": return Self.norm(log(n(0)))
        case "bk.action.f32.Sqrt": return Self.norm(sqrt(n(0)))
        case "bk.action.f32.Pow", "bk.action.num.Pow": return Self.norm(pow(n(0), n(1)))
        case "bk.action.f32.Cos": return Self.norm(cos(n(0) * .pi / 180))
        case "bk.action.f32.Sin": return Self.norm(sin(n(0) * .pi / 180))
        case "bk.action.math.Max": return v.map(bnum).max().map(Self.norm)
        case "bk.action.math.Min": return v.map(bnum).min().map(Self.norm)
        case "bk.action.math.Abs": return Self.norm(abs(n(0)))
        case "bk.action.math.Floor": return Self.norm(floor(n(0)))
        case "bk.action.math.Ceil": return Self.norm(ceil(n(0)))
        case "bk.action.io.CurrentTimeMillis", "bk.action.io.CurrentTimeMillisV2": return Int64(Date().timeIntervalSince1970 * 1000)
        case "bk.action.bloks.TimestampOfLastTouchUpV2": return Int64(-1)
        case "bk.action.GetClientTimezone": return TimeZone.current.identifier
        case "bk.action.i18n.LanguagePackResolveFbt", "bk.action.i18n.LanguagePackResolveFbtV2", "bk.action.mins.Chr16", "bk.action.mins.EqArgCount", "bk.action.mins.GetArguments", "bk.action.mins.ToUint32", "bk.action.mins.VectorResize", "bk.action.splice.Apply", "bk.action.splice.Get", "bk.action.bloks.Timestamp", "bk.action.bloks.TimestampOfLastTouchUp": return nil
        default:
            if ["bk.action.f32.", "bk.action.i32.", "bk.action.i64.", "bk.action.num."].contains(where: name.hasPrefix) {
                switch name.components(separatedBy: ".").last {
                case "Eq": return Self.equal(x(0), x(1))
                case "Gt": return Self.compare(x(0), x(1)) > 0
                case "Lt": return Self.compare(x(0), x(1)) < 0
                case "Add": return Self.arith(x(0), x(1), "+")
                case "Sub": return Self.arith(x(0), x(1), "-")
                case "Mul": return Self.arith(x(0), x(1), "*")
                case "Div": return Self.norm(name.contains("i32") ? (n(0) / n(1)).rounded(.towardZero) : n(0) / n(1))
                case "Mod": return Self.norm(n(0).truncatingRemainder(dividingBy: n(1)).rounded(.towardZero))
                default: break
                }
            }
            return try ctx.extensionCall(self, name, v)
        }
    }

    private func put(_ target: Any?, _ key: Any?, _ value: Any?) throws {
        if let map = target as? BloksMap { guard map.pairs.count < 10_000 else { throw BloksError("Map size limit") }; map.set(key, value); return }
        if let array = target as? BloksArray { let i = bint(key); guard i >= 0, i <= array.items.count, i < 10_000 else { throw BloksError("Array index limit") }; if i == array.items.count { array.items.append(value) } else { array.items[i] = value }; return }
        throw BloksError("Expected mutable container")
    }

    private func runtime(_ op: Int, _ a: [Any?]) throws -> Any? {
        switch op {
        case 2: if let string = a.at(0) as? String { return Double(string.trimmingCharacters(in: .whitespacesAndNewlines)).map(Self.norm) }; return a.at(0).map { Self.norm(bnum($0)) }
        case 6: guard a.count % 2 == 0 else { throw BloksError("Odd map literal") }; let n = a.count / 2; return BloksMap((0..<n).map { (a[$0], a[n + $0]) })
        case 8: if let string = a.at(0) as? String { return Int64(string.trimmingCharacters(in: .whitespacesAndNewlines)) }; return a.at(0).map(Self.i64)
        case 10: let string = Array((a.at(0) as? String ?? "").utf16), offset = bint(a.at(1)), start = offset < 0 ? string.count + offset : offset, length = a.at(2) == nil ? string.count - start : bint(a.at(2)); guard start >= 0, length >= 0, start <= string.count, length <= string.count - start else { throw BloksError("Substring range") }; return String(decoding: string[start..<start + length], as: UTF16.self)
        case 17: return BloksMap(stride(from: 0, to: a.count, by: 2).map { (a[$0], a.at($0 + 1)) })
        default: throw BloksError("Unsupported runtime operation \(op)")
        }
    }

    nonisolated static func isBool(_ x: Any?) -> Bool { guard let number = x as? NSNumber else { return false }; return CFGetTypeID(number) == CFBooleanGetTypeID() }
    nonisolated static func truthy(_ x: Any?) -> Bool { guard let x, !(x is NSNull) else { return false }; if let string = x as? String { return !string.isEmpty }; if let number = x as? NSNumber { return number.doubleValue != 0 && !number.doubleValue.isNaN }; return true }
    nonisolated static func equal(_ a: Any?, _ b: Any?, strict: Bool = false) -> Bool {
        if a == nil || b == nil { return a == nil && b == nil }
        if strict && isBool(a) != isBool(b) { return false }
        if let a = a as? NSNumber, let b = b as? NSNumber { return a.compare(b) == .orderedSame && !a.doubleValue.isNaN && !b.doubleValue.isNaN }
        if let a = a as? String, let b = b as? String { return a == b }
        if let a = a as? BloksMap, let b = b as? BloksMap { return a === b }; if let a = a as? BloksArray, let b = b as? BloksArray { return a === b }
        if let a = a as? BloksNode, let b = b as? BloksNode { return a === b }; if let a = a as? BloksLambda, let b = b as? BloksLambda { return a === b }; return false
    }
    nonisolated static func compare(_ a: Any?, _ b: Any?) -> Int { if let a = a as? String, let b = b as? String { return a == b ? 0 : a < b ? -1 : 1 }; if let a = a as? NSNumber, let b = b as? NSNumber { return a.compare(b).rawValue }; return 0 }
    nonisolated static func typeOf(_ x: Any?) -> Int { if x == nil { return 0 }; if isBool(x) { return 1 }; if x is String { return 2 }; if x is Int64 { return 3 }; if x is NSNumber { return 4 }; if x is BloksArray { return 6 }; if x is BloksMap { return 7 }; if x is BloksLambda { return 8 }; return 5 }
    nonisolated static func i32(_ x: Any?) -> Int32 { let d = bnum(x); if d.isNaN { return 0 }; if d >= Double(Int32.max) { return .max }; if d <= Double(Int32.min) { return .min }; return Int32(d) }
    nonisolated static func i64(_ x: Any?) -> Int64 { if let integer = x as? Int64 { return integer }; let d = bnum(x); if d.isNaN { return 0 }; if d >= Double(Int64.max) { return .max }; if d <= Double(Int64.min) { return .min }; return Int64(d) }
    nonisolated static func norm(_ d: Double) -> Any { if d.isFinite, d.rounded(.towardZero) == d, d >= Double(Int32.min), d <= Double(Int32.max), !(d == 0 && d.sign == .minus) { return Int32(d) }; return d }
    nonisolated private static func arith(_ a: Any?, _ b: Any?, _ op: String) -> Any {
        if (a is Int64 || b is Int64) && (a is Int32 || a is Int64) && (b is Int32 || b is Int64) { let l = i64(a), r = i64(b), v = op == "+" ? l &+ r : op == "-" ? l &- r : l &* r; return (Int64(Int32.min)...Int64(Int32.max)).contains(v) ? Int32(v) as Any : v }
        let l = bnum(a), r = bnum(b); return norm(op == "+" ? l + r : op == "-" ? l - r : l * r)
    }
}
