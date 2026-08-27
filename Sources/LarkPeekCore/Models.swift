import Foundation

public enum ChatKind: String, Codable, Sendable {
    case p2p
    case group
    case topic

    public init(chatMode: String?) {
        switch chatMode {
        case "p2p": self = .p2p
        case "topic": self = .topic
        default: self = .group
        }
    }

    public var label: String {
        switch self {
        case .p2p: "单聊"
        case .group: "群聊"
        case .topic: "话题群"
        }
    }
}

public struct LarkChat: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var description: String?
    public var kind: ChatKind
    public var external: Bool

    public init(
        id: String,
        name: String,
        description: String? = nil,
        kind: ChatKind,
        external: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.kind = kind
        self.external = external
    }
}

public struct MessageSender: Codable, Hashable, Sendable {
    public var id: String?
    public var name: String
    public var type: String?

    public init(id: String? = nil, name: String, type: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
    }
}

public struct MessageImage: Codable, Hashable, Sendable {
    public let key: String
    public var data: Data?
    public var attempted: Bool

    public init(key: String, data: Data? = nil, attempted: Bool = false) {
        self.key = key
        self.data = data
        self.attempted = attempted
    }
}

public struct ForwardedMessageItem: Codable, Hashable, Sendable {
    public var createTime: Date?
    public var senderName: String
    public var content: String

    public init(createTime: Date? = nil, senderName: String, content: String) {
        self.createTime = createTime
        self.senderName = senderName
        self.content = content
    }
}

public struct LarkMessage: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var chatID: String
    public var type: String
    public var createTime: Date
    public var position: Int64?
    public var sender: MessageSender
    public var content: String
    public var images: [MessageImage]
    public var sharedChatID: String?
    public var sharedChatName: String?
    public var forwardedMessages: [ForwardedMessageItem]
    public var threadID: String?
    public var threadReplies: [LarkMessage]
    public var threadRepliesLoaded: Bool
    public var threadHasMore: Bool
    public var deleted: Bool
    public var updated: Bool

    public init(
        id: String,
        chatID: String,
        type: String = "text",
        createTime: Date,
        position: Int64? = nil,
        sender: MessageSender,
        content: String,
        images: [MessageImage] = [],
        sharedChatID: String? = nil,
        sharedChatName: String? = nil,
        forwardedMessages: [ForwardedMessageItem] = [],
        threadID: String? = nil,
        threadReplies: [LarkMessage] = [],
        threadRepliesLoaded: Bool = false,
        threadHasMore: Bool = false,
        deleted: Bool = false,
        updated: Bool = false
    ) {
        self.id = id
        self.chatID = chatID
        self.type = type
        self.createTime = createTime
        self.position = position
        self.sender = sender
        self.content = content
        self.images = images
        self.sharedChatID = sharedChatID
        self.sharedChatName = sharedChatName
        self.forwardedMessages = forwardedMessages
        self.threadID = threadID
        self.threadReplies = threadReplies
        self.threadRepliesLoaded = threadRepliesLoaded
        self.threadHasMore = threadHasMore
        self.deleted = deleted
        self.updated = updated
    }

    public static func isChronologicallyBefore(_ lhs: LarkMessage, _ rhs: LarkMessage) -> Bool {
        if lhs.createTime != rhs.createTime { return lhs.createTime < rhs.createTime }
        if let left = lhs.position, let right = rhs.position, left != right { return left < right }
        return lhs.id < rhs.id
    }
}

public enum MessageTimeline {
    public static func merging(_ older: [LarkMessage], into current: [LarkMessage]) -> [LarkMessage] {
        var byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        for message in older {
            guard let existing = byID[message.id] else {
                byID[message.id] = message
                continue
            }

            var merged = message
            let existingImages = Dictionary(uniqueKeysWithValues: existing.images.map { ($0.key, $0) })
            merged.images = message.images.map { image in
                guard let hydrated = existingImages[image.key],
                      hydrated.data != nil || hydrated.attempted else { return image }
                return hydrated
            }
            if merged.sharedChatName == nil {
                merged.sharedChatName = existing.sharedChatName
            }
            if existing.threadRepliesLoaded {
                merged.threadReplies = existing.threadReplies
                merged.threadRepliesLoaded = true
                merged.threadHasMore = existing.threadHasMore
            }
            byID[message.id] = merged
        }
        return byID.values.sorted(by: LarkMessage.isChronologicallyBefore)
    }
}

public struct AuthStatus: Equatable, Sendable {
    public static let requiredScopes = [
        "im:chat:read",
        "im:message:readonly",
        "search:message"
    ]

    public enum State: Equatable, Sendable {
        case checking
        case ready
        case needsLogin
        case error(String)
    }

    public var state: State
    public var userName: String?
    public var openID: String?
    public var tokenStatus: String?
    public var scopes: Set<String>

    public var missingRequiredScopes: Set<String> {
        Set(Self.requiredScopes).subtracting(scopes)
    }

    public init(
        state: State = .checking,
        userName: String? = nil,
        openID: String? = nil,
        tokenStatus: String? = nil,
        scopes: Set<String> = []
    ) {
        self.state = state
        self.userName = userName
        self.openID = openID
        self.tokenStatus = tokenStatus
        self.scopes = scopes
    }
}

public struct HoveredConversation: Equatable, Sendable {
    public let name: String
    public let rowFrame: CGRect
    public let rowTexts: [String]

    public init(name: String, rowFrame: CGRect, rowTexts: [String]) {
        self.name = name
        self.rowFrame = rowFrame
        self.rowTexts = rowTexts
    }

    public var fingerprint: String {
        ConversationText.normalize([name] + rowTexts.prefix(5))
    }

    public var threadHint: ThreadRowHint? {
        ThreadRowHeuristics.hint(from: rowTexts.isEmpty ? [name] : rowTexts)
    }
}

public struct ThreadRowHint: Equatable, Sendable {
    public let rootSender: String
    public let rootExcerpt: String
    public let latestReplySender: String?
    public let latestReplyExcerpt: String
    public let searchQuery: String
    public let replySearchQuery: String?
    public let activityMarker: String

    public init(
        rootSender: String,
        rootExcerpt: String,
        latestReplySender: String?,
        latestReplyExcerpt: String,
        searchQuery: String,
        replySearchQuery: String?,
        activityMarker: String
    ) {
        self.rootSender = rootSender
        self.rootExcerpt = rootExcerpt
        self.latestReplySender = latestReplySender
        self.latestReplyExcerpt = latestReplyExcerpt
        self.searchQuery = searchQuery
        self.replySearchQuery = replySearchQuery
        self.activityMarker = activityMarker
    }

    public var stableFingerprint: String {
        ConversationText.normalize([rootSender, rootExcerpt])
    }
}

public enum ThreadRowHeuristics {
    // In Feishu's mixed "Messages" list, a standalone thread is exposed as one
    // flattened accessibility text node:
    //   root sender: root content 14:12 latest sender: latest reply
    // or, for compact rows:
    //   root sender: root content 11:49 latest reply
    // This is only a routing hint. A server result with a real thread_id is
    // still required before the row is treated as a thread.
    private static let rootSenderPattern = try! NSRegularExpression(
        pattern: #"^\s*([^:：\n]{1,40})\s*[:：]\s*"#
    )
    private static let replyTimePattern = try! NSRegularExpression(
        pattern: #"\s+(\d{1,2}:\d{2}|昨天|前天|\d{1,2}月\d{1,2}日)\s+"#
    )
    private static let replySenderPattern = try! NSRegularExpression(
        pattern: #"^\s*([^:：\n]{1,40}?)\s*[:：](?!\d)\s*"#
    )

    public static func hint(from texts: [String]) -> ThreadRowHint? {
        // Accessibility exposes the same Feishu row differently across builds:
        // sometimes as one flattened static text, sometimes as separate title,
        // time, sender and reply nodes. Try each node first, then suffix joins
        // so leading unread badges do not prevent the title node from becoming
        // the start of the candidate.
        let trimmedTexts = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var candidates: [String] = []
        if trimmedTexts.count > 1 {
            for start in trimmedTexts.indices
                where start < trimmedTexts.index(before: trimmedTexts.endIndex)
                    && (trimmedTexts[start].contains(":") || trimmedTexts[start].contains("：")) {
                candidates.append(trimmedTexts[start...].joined(separator: " "))
            }
        }
        candidates.append(contentsOf: trimmedTexts)

        for rawText in candidates {
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let senderMatch = rootSenderPattern.firstMatch(in: text, range: range),
                  let rootSender = capture(1, match: senderMatch, in: text),
                  let contentStart = Range(senderMatch.range, in: text)?.upperBound
            else { continue }

            let remainderRange = NSRange(contentStart..<text.endIndex, in: text)
            guard let timeMatch = replyTimePattern.matches(in: text, range: remainderRange).last,
                  let markerRange = Range(timeMatch.range, in: text),
                  let activityMarker = capture(1, match: timeMatch, in: text)
            else { continue }

            let rootExcerpt = String(text[contentStart..<markerRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let replyTail = String(text[markerRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let replyTailRange = NSRange(replyTail.startIndex..<replyTail.endIndex, in: replyTail)
            let replySenderMatch = replySenderPattern.firstMatch(in: replyTail, range: replyTailRange)
            let latestReplySender = replySenderMatch.flatMap { capture(1, match: $0, in: replyTail) }
            let latestReplyExcerpt: String
            if let replySenderMatch,
               let replyStart = Range(replySenderMatch.range, in: replyTail)?.upperBound {
                latestReplyExcerpt = String(replyTail[replyStart...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                latestReplyExcerpt = replyTail
            }
            guard !rootExcerpt.isEmpty, !latestReplyExcerpt.isEmpty,
                  let query = searchQuery(from: rootExcerpt)
            else { continue }

            return ThreadRowHint(
                rootSender: rootSender,
                rootExcerpt: rootExcerpt,
                latestReplySender: latestReplySender,
                latestReplyExcerpt: latestReplyExcerpt,
                searchQuery: query,
                replySearchQuery: searchQuery(from: latestReplyExcerpt),
                activityMarker: activityMarker
            )
        }
        return nil
    }

    private static func capture(_ index: Int, match: NSTextCheckingResult, in text: String) -> String? {
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func searchQuery(from excerpt: String) -> String? {
        var value = excerpt
        if value.trimmingCharacters(in: .whitespacesAndNewlines) == "[会话记录]" {
            return "[会话记录]"
        }
        // Link display titles can be longer than the actual topic sentence and
        // may not be present in message-search's normalized content. Prefer the
        // authored text before the first rich-link placeholder.
        if let linkRange = value.range(of: "[链接]") {
            value = String(value[..<linkRange.lowerBound])
        }
        value = value.replacingOccurrences(of: #"@[^ \t\r\n@]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\[[^\]]+\]"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let clauses = value.components(separatedBy: CharacterSet(charactersIn: "，。！？；;、&＆\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let withoutClock = clauses.filter {
            $0.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) == nil
        }
        let candidates = withoutClock.isEmpty ? clauses : withoutClock
        let candidate = candidates.max { lhs, rhs in lhs.count < rhs.count } ?? value
        guard !candidate.isEmpty else { return nil }
        return String(candidate.prefix(32))
    }
}

public struct ThreadSearchHit: Equatable, Sendable {
    public let rootMessage: LarkMessage
    public let chat: LarkChat

    public init(rootMessage: LarkMessage, chat: LarkChat) {
        self.rootMessage = rootMessage
        self.chat = chat
    }
}

public enum ThreadSearchMatcher {
    public static func bestHit(for hint: ThreadRowHint, in hits: [ThreadSearchHit]) -> ThreadSearchHit? {
        let scored = hits.compactMap { hit -> (ThreadSearchHit, Int)? in
            guard hit.rootMessage.threadID != nil else { return nil }
            let content = ConversationText.normalize(hit.rootMessage.content)
            let query = ConversationText.normalize(hint.searchQuery)
            let excerpt = ConversationText.normalize(hint.rootExcerpt)
            let senderMatches = ConversationText.normalize(hit.rootMessage.sender.name)
                == ConversationText.normalize(hint.rootSender)
            var score = 0
            if !query.isEmpty, content.contains(query) { score += 4 }
            if !excerpt.isEmpty, excerpt.contains(content) || content.contains(excerpt) { score += 2 }
            if senderMatches { score += 2 }
            guard score >= 6 else { return nil }
            return (hit, score)
        }
        guard let highest = scored.map(\.1).max() else { return nil }
        let winners = scored.filter { $0.1 == highest }
        return winners.count == 1 ? winners[0].0 : nil
    }
}

public enum ConversationText {
    public static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }

    public static func normalize<S: Sequence>(_ texts: S) -> String where S.Element == String {
        texts.map(normalize).joined(separator: "|")
    }
}

public enum ChatMatcher {
    public static func exactMatches(name: String, in chats: [LarkChat]) -> [LarkChat] {
        let target = ConversationText.normalize(name)
        guard !target.isEmpty else { return [] }
        return chats.filter { ConversationText.normalize($0.name) == target }
    }

    public static func fuzzyMatches(name: String, in chats: [LarkChat]) -> [LarkChat] {
        let target = ConversationText.normalize(name)
        guard !target.isEmpty else { return [] }
        return chats.filter {
            let candidate = ConversationText.normalize($0.name)
            return candidate != target
                && (candidate.hasPrefix(target) || target.hasPrefix(candidate))
        }
    }

    public static func matches(name: String, in chats: [LarkChat]) -> [LarkChat] {
        let exact = exactMatches(name: name, in: chats)
        return exact.isEmpty ? fuzzyMatches(name: name, in: chats) : exact
    }
}
