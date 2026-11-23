import Foundation

/// Runs `operation`, or throws `ReGlassError.timedOut(what)` once `timeout` passes.
///
/// The operation must respond to cancellation (every wait in ReGlassKit does: queues and transports resume their
/// waiters when cancelled or closed). A task group waits for its children, so a wait that ignored cancellation
/// would hold the timeout up.
func withTimeout<T: Sendable>(
    _ timeout: Duration,
    _ what: String,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ReGlassError.timedOut(what)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}

/// A value guarded by a lock, for the few classes that must be `Sendable` without being actors
/// (CoreBluetooth delegates, transports). Keep the closures short and never await inside them.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    var current: Value { withLock { $0 } }
}

/// An unbounded first-in, first-out queue between producers and one awaiting consumer.
///
/// `next()` returns buffered elements first, then waits. `finish(throwing:)` ends the queue: the waiter and every
/// later `next()` get the error once the buffer is drained. Cancelling the waiting task resumes it with
/// `CancellationError`, so a `withTimeout` around `next()` works.
final class AsyncQueue<Element>: @unchecked Sendable {
    private struct State {
        var buffer: [Element] = []
        var head = 0
        var waiter: (id: UInt64, continuation: CheckedContinuation<Element, Error>)?
        var finished: Error?
        var nextWaiterID: UInt64 = 0

        var hasBuffered: Bool { head < buffer.count }

        mutating func popFirst() -> Element {
            let element = buffer[head]
            head += 1
            if head > 64 && head * 2 > buffer.count {
                buffer.removeFirst(head)
                head = 0
            }
            return element
        }
    }

    private enum WaitOutcome {
        case element(Element)
        case failure(Error)
        case waiting
    }

    private let state = Locked(State())

    /// Adds an element, handing it straight to a waiting consumer if there is one. Ignored after `finish`.
    func push(_ element: Element) {
        let waiter: CheckedContinuation<Element, Error>? = state.withLock { state in
            guard state.finished == nil else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter.continuation
            }
            state.buffer.append(element)
            return nil
        }
        waiter?.resume(returning: element)
    }

    /// Ends the queue. Buffered elements are still delivered; after them, `next()` throws `error`.
    func finish(throwing error: Error = ReGlassError.linkLost) {
        let waiter: CheckedContinuation<Element, Error>? = state.withLock { state in
            guard state.finished == nil else { return nil }
            state.finished = error
            defer { state.waiter = nil }
            return state.waiter?.continuation
        }
        waiter?.resume(throwing: error)
    }

    var isFinished: Bool { state.withLock { $0.finished != nil } }

    /// The next element without waiting, or nil.
    func poll() -> Element? {
        state.withLock { $0.hasBuffered ? $0.popFirst() : nil }
    }

    /// The next element, waiting for one if needed. One consumer at a time.
    func next() async throws -> Element {
        let id = state.withLock { state -> UInt64 in
            state.nextWaiterID &+= 1
            return state.nextWaiterID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Element, Error>) in
                let outcome: WaitOutcome = state.withLock { state in
                    if state.hasBuffered { return .element(state.popFirst()) }
                    if let finished = state.finished { return .failure(finished) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    precondition(state.waiter == nil, "AsyncQueue supports one waiting consumer")
                    state.waiter = (id, continuation)
                    return .waiting
                }
                switch outcome {
                case .element(let element): continuation.resume(returning: element)
                case .failure(let error): continuation.resume(throwing: error)
                case .waiting: break
                }
            }
        } onCancel: {
            let waiter: CheckedContinuation<Element, Error>? = state.withLock { state in
                guard let waiter = state.waiter, waiter.id == id else { return nil }
                state.waiter = nil
                return waiter.continuation
            }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

/// A value set once and awaited by any number of tasks (a one-shot promise). Cancellation-aware.
final class OneShot<Value>: @unchecked Sendable {
    private struct State {
        var result: Result<Value, Error>?
        var waiters: [UInt64: CheckedContinuation<Value, Error>] = [:]
        var nextID: UInt64 = 0
    }

    private let state = Locked(State())

    var isResolved: Bool { state.withLock { $0.result != nil } }

    /// Resolves the value. Only the first call counts; returns whether this call did.
    @discardableResult
    func resolve(_ result: Result<Value, Error>) -> Bool {
        let waiters: [CheckedContinuation<Value, Error>]? = state.withLock { state in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        guard let waiters else { return false }
        for waiter in waiters { waiter.resume(with: result) }
        return true
    }

    func value() async throws -> Value {
        let id = state.withLock { state -> UInt64 in
            state.nextID &+= 1
            return state.nextID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                let ready: Result<Value, Error>? = state.withLock { state in
                    if let result = state.result { return result }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    state.waiters[id] = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }
}
