import Foundation

/// Identifies the preview attempt across all async helpers, including reopening the same chat.
enum TimelineRequestContext {
    @TaskLocal static var sessionID: UUID?
}

@MainActor
public final class TimelineSession {
    public private(set) var id = UUID()
    public private(set) var revision: UInt64 = 0
    public private(set) var messages: [LarkMessage] = []
    public private(set) var pagination: TimelinePagination = .exhausted
    public private(set) var conversation: HoveredConversation?
    public private(set) var chat: LarkChat?
    public private(set) var replyErrors: [String: String] = [:]
    private(set) var consumedPageTokens: Set<String> = []
    private var acceptsResults = true
    var onChange: (() -> Void)?
    private var tasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]

    public init() {}

    public func isCurrent(_ sessionID: UUID) -> Bool { id == sessionID && acceptsResults }

    func checkCurrentRequest() throws {
        try Task.checkCancellation()
        guard let requestSession = TimelineRequestContext.sessionID, isCurrent(requestSession) else { throw CancellationError() }
    }

    func reset() {
        cancelTasks()
        id = UUID()
        acceptsResults = true
        revision = 0
        messages = []
        pagination = .exhausted
        conversation = nil
        chat = nil
        replyErrors = [:]
        consumedPageTokens = []
    }

    func cancelTasks() {
        let current = tasks.values.map(\.task)
        tasks.removeAll()
        current.forEach { $0.cancel() }
    }

    func invalidateRequests() {
        acceptsResults = false
        cancelTasks()
    }

    @discardableResult
    func schedule(key: String, operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        guard acceptsResults else { return Task {} }
        if let existing = tasks[key] { return existing.task }
        let requestID = UUID()
        let sessionID = id
        let task = Task { @MainActor [weak self] in
            await TimelineRequestContext.$sessionID.withValue(sessionID) {
                guard let self, self.isCurrent(sessionID), !Task.isCancelled else { return }
                await operation()
                if self.isCurrent(sessionID), self.tasks[key]?.id == requestID {
                    self.tasks[key] = nil
                }
            }
        }
        tasks[key] = (requestID, task)
        return task
    }

    func install(conversation: HoveredConversation, chat: LarkChat, messages: [LarkMessage], cursor: String?, sessionID: UUID) {
        guard isCurrent(sessionID) else { return }
        self.conversation = conversation
        self.chat = chat
        self.messages = MessageTimeline.merging(messages, into: [])
        pagination = cursor.map(TimelinePagination.ready) ?? .exhausted
        changed()
    }

    func beginPage(sessionID: UUID, automatic: Bool) -> (id: UUID, cursor: String)? {
        guard isCurrent(sessionID), !pagination.isLoading,
              !automatic || pagination.allowsAutomaticLoading,
              let cursor = pagination.cursor else { return nil }
        let requestID = UUID()
        pagination = .loading(requestID, cursor)
        changed()
        return (requestID, cursor)
    }

    @discardableResult
    func receivePage(_ page: LarkCLIParser.MessagePage, requestID: UUID, sessionID: UUID, nextState: TimelinePagination) -> Int {
        guard ownsPage(requestID, sessionID: sessionID) else { return 0 }
        if let cursor = pagination.cursor { consumedPageTokens.insert(cursor) }
        let previousCount = messages.count
        messages = MessageTimeline.merging(page.messages, into: messages)
        pagination = nextState
        changed()
        return messages.count - previousCount
    }

    func finishPage(_ state: TimelinePagination, requestID: UUID, sessionID: UUID) {
        guard ownsPage(requestID, sessionID: sessionID) else { return }
        pagination = state
        changed()
    }

    private func ownsPage(_ requestID: UUID, sessionID: UUID) -> Bool {
        guard isCurrent(sessionID), case let .loading(activeID, _) = pagination else { return false }
        return activeID == requestID
    }

    func applyNames(_ names: [String: String], sessionID: UUID) {
        patchMessages(sessionID: sessionID) { message in
            if let id = message.sharedChatID, let name = names[id] { message.sharedChatName = name }
        }
    }

    func applyImage(messageID: String, key: String, data: Data?, sessionID: UUID) {
        patchMessages(sessionID: sessionID) { message in
            guard message.id == messageID else { return }
            message.images = message.images.map { image in
                guard image.key == key, image.data == nil else { return image }
                return MessageImage(key: key, data: data, attempted: true)
            }
        }
    }

    func applyReplies(_ replies: [LarkMessage], threadID: String, hasMore: Bool, sessionID: UUID) {
        guard isCurrent(sessionID) else { return }
        replyErrors[threadID] = nil
        patchMessages(sessionID: sessionID) { message in
            guard message.isThreadRoot, message.threadID == threadID else { return }
            message.threadReplies = MessageTimeline.merging(replies, into: message.threadReplies)
            message.threadRepliesLoaded = true
            message.threadHasMore = hasMore
        }
    }

    func failReplies(threadID: String, error: String, sessionID: UUID) {
        guard isCurrent(sessionID) else { return }
        replyErrors[threadID] = error
        changed()
    }

    func beginReplies(threadID: String, sessionID: UUID) {
        guard isCurrent(sessionID), replyErrors.removeValue(forKey: threadID) != nil else { return }
        changed()
    }

    private func patchMessages(sessionID: UUID, patch: (inout LarkMessage) -> Void) {
        guard isCurrent(sessionID) else { return }
        var updated = messages
        for index in updated.indices {
            patch(&updated[index])
            for replyIndex in updated[index].threadReplies.indices {
                patch(&updated[index].threadReplies[replyIndex])
            }
        }
        guard updated != messages else { return }
        messages = updated
        changed()
    }

    private func changed() {
        revision &+= 1
        onChange?()
    }
}
