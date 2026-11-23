import Foundation

/// The iPhone tools offered for one turn: their definitions (sorted by name, so the request bytes are stable) and
/// the implementations Claude's calls are dispatched to by name.
struct Toolbox: Sendable {
    let definitions: [ToolDefinition]
    let byName: [String: any AssistantTool]

    static let empty = Toolbox(definitions: [], byName: [:])

    /// The provider's current tools. A tool with a name the API would reject, or a repeat of a name, is left out
    /// (one bad definition would otherwise fail every request).
    static func load(from provider: (any ToolProvider)?) async -> Toolbox {
        guard let provider else { return .empty }
        var byName: [String: any AssistantTool] = [:]
        var skipped = 0
        for tool in await provider.currentTools() {
            let name = tool.definition.name
            guard isValidName(name), name != "web_search", name != "web_fetch", byName[name] == nil else {
                skipped += 1
                continue
            }
            byName[name] = tool
        }
        if skipped > 0 { AssistantLog.add("Tools: \(skipped) tool\(skipped == 1 ? "" : "s") left out (bad or repeated name)") }
        return Toolbox(definitions: byName.values.map(\.definition).sorted { $0.name < $1.name }, byName: byName)
    }

    /// `^[a-zA-Z0-9_-]{1,64}$`
    static func isValidName(_ name: String) -> Bool {
        (1...64).contains(name.utf8.count)
            && name.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0)
                || $0 == 0x5F || $0 == 0x2D }
    }
}

/// One tool call with a hard time limit. Tools never throw; this makes sure a slow or stuck one can't hold the turn
/// either: at the limit (or when the turn is cancelled) the call is answered with a failure and the tool's task is
/// cancelled, without waiting for it to notice.
enum ToolCall {
    static func run(_ call: ClaudeToolCall, tool: (any AssistantTool)?, context: ToolContext,
                    timeout: Duration) async -> ToolResult {
        guard let tool else {
            // A pinned tool whose connector was switched off since the conversation began.
            return .failure("That isn't available right now: it's switched off in ReGlass.")
        }
        if let raw = call.unreadableInput {
            let content = (try? JSONValue.object(["INVALID_JSON": .string(raw)]).encoded())
                .flatMap { String(data: $0, encoding: .utf8) } ?? "INVALID_JSON"
            return .failure(content)
        }
        let input = call.input
        let once = OnceResult()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                once.attach(continuation)
                let work = Task { once.finish(await tool.run(input, context: context)) }
                let timer = Task {
                    try? await Task.sleep(for: timeout)
                    once.finish(.failure("That took too long, so ReGlass stopped waiting for it."))
                }
                once.onFinish { work.cancel(); timer.cancel() }
            }
        } onCancel: {
            once.finish(.failure("Stopped."))
        }
    }
}

/// Resumes a continuation with the first result only, whichever of the tool, the timer or a cancellation gets there
/// first, then runs the clean-up. `@unchecked Sendable`: all state is behind `lock`.
private final class OnceResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ToolResult, Never>?
    private var result: ToolResult?
    private var cleanup: (@Sendable () -> Void)?

    func attach(_ continuation: CheckedContinuation<ToolResult, Never>) {
        let ready: ToolResult? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(returning: ready) }
    }

    func onFinish(_ body: @escaping @Sendable () -> Void) {
        let finished: Bool = lock.withLock {
            if result != nil { return true }
            cleanup = body
            return false
        }
        if finished { body() }
    }

    func finish(_ value: ToolResult) {
        let (waiting, clean): (CheckedContinuation<ToolResult, Never>?, (@Sendable () -> Void)?) = lock.withLock {
            guard result == nil else { return (nil, nil) }
            result = value
            defer {
                continuation = nil
                cleanup = nil
            }
            return (continuation, cleanup)
        }
        waiting?.resume(returning: value)
        clean?()
    }
}
