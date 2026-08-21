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
        for message in older { byID[message.id] = message }
        return byID.values.sorted(by: LarkMessage.isChronologicallyBefore)
    }
}

public struct AuthStatus: Equatable, Sendable {
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
