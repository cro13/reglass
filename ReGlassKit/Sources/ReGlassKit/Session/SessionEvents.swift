import Foundation

/// Where the link is, as the session reports it.
enum LinkState: Sendable, Equatable {
    case connecting
    case linkSetup
    case trust
    case ready
    case lost
    case disconnected
}

/// Everything the session tells the layer above it. One consumer; delivered on an `AsyncStream`.
enum LinkEvent: Sendable {
    /// The link moved. `reason` is a log-safe line on `.lost`, empty otherwise.
    case state(LinkState, reason: String)
    /// A connect attempt failed with something a person could act on.
    case connectFailure(ReGlassError)
    /// One message from a service, undecoded.
    case serviceMessage(service: Int, type: Int, payload: [UInt8])
    /// A protocol problem that did not necessarily end the link. Log-safe text only.
    case warning(String)
    /// A service answered with a non-success DataX status frame (always also logged as a `warning`). `channel` is
    /// the frame's channel as received, so a flow can tell a refusal of its own channel from another one.
    case serviceStatus(service: Int, channel: Int, status: Int)
}
