import Foundation

/// Debounces a new row without repeatedly reopening the row already being read.
public struct HoverPreviewTracker {
    private var active: HoveredConversation?
    private var candidate: HoveredConversation?
    private var candidateSince: TimeInterval = 0
    public var hasPendingCandidate: Bool { candidate != nil }
    public let dwell: TimeInterval

    public init(dwell: TimeInterval = 0.2) { self.dwell = dwell }

    public mutating func activate(_ conversation: HoveredConversation) {
        active = conversation
        candidate = nil
    }

    public mutating func observe(_ conversation: HoveredConversation?, at time: TimeInterval) -> HoveredConversation? {
        guard let conversation else {
            candidate = nil
            return nil
        }
        if sameRow(conversation, active) {
            candidate = nil
            return nil
        }
        guard sameRow(conversation, candidate) else {
            candidate = conversation
            candidateSince = time
            return nil
        }
        guard time - candidateSince >= dwell else { return nil }
        activate(conversation)
        return conversation
    }

    private func sameRow(_ lhs: HoveredConversation, _ rhs: HoveredConversation?) -> Bool {
        guard let rhs else { return false }
        return lhs.fingerprint == rhs.fingerprint && lhs.rowFrame == rhs.rowFrame
    }
}
