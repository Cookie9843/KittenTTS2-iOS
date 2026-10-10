import Foundation

public struct StatusMessage: Equatable, Sendable {
    public var text: String
    public var isError: Bool
    public init(_ text: String, isError: Bool = false) { self.text = text; self.isError = isError }
}

/// The user-visible result of one kind of operation. Each operation owns its own slot, so a new message (or clearing one)
/// for a different operation can never replace or hide this one.
public struct OperationStatus<Operation: Hashable & Sendable>: Equatable, Sendable {
    private var slots: [Operation: StatusMessage] = [:]
    public init() {}

    public subscript(operation: Operation) -> StatusMessage? { slots[operation] }

    public mutating func info(_ text: String, for operation: Operation) { slots[operation] = StatusMessage(text) }
    public mutating func error(_ text: String, for operation: Operation) { slots[operation] = StatusMessage(text, isError: true) }
    /// Call when the user starts a new action of this kind: drops only this operation's stale message.
    public mutating func clear(_ operation: Operation) { slots[operation] = nil }
}

/// Independent KittenTTS 2 operations.
public enum Kitten2Operation: Hashable, Sendable, CaseIterable {
    case modelDownload, modelImport, synthesis, referenceAudio, playback
}

/// Independent KittenTTS 0.8 / shared-history operations.
public enum LegacyOperation: Hashable, Sendable, CaseIterable {
    case modelSetup, synthesis, playback, history
}
