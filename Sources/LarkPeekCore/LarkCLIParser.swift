import Foundation

public enum LarkCLIParser {
    public struct ChatPage: Sendable {
        public let chats: [LarkChat]
        public let nextPageToken: String?

        public init(chats: [LarkChat], nextPageToken: String?) {
            self.chats = chats
            self.nextPageToken = nextPageToken
        }
    }

    public struct MessagePage: Sendable {
        public let messages: [LarkMessage]
        public let nextPageToken: String?

        public init(messages: [LarkMessage], nextPageToken: String?) {
            self.messages = messages
            self.nextPageToken = nextPageToken
        }
    }

    public static func authStatus(from data: Data) throws -> AuthStatus {
        let root = try dictionary(from: data)
        let identities = root["identities"] as? [String: Any]
        let user = identities?["user"] as? [String: Any]
        let available = user?["available"] as? Bool ?? false
        let verified = root["verified"] as? Bool ?? user?["verified"] as? Bool ?? false
        let state: AuthStatus.State = available && verified ? .ready : .needsLogin
        let scopeString = user?["scope"] as? String ?? ""
        return AuthStatus(
            state: state,
            userName: user?["userName"] as? String,
            openID: user?["openId"] as? String,
            tokenStatus: user?["tokenStatus"] as? String,
            scopes: Set(scopeString.split(separator: " ").map(String.init))
        )
    }

    public static func chatPage(from data: Data) throws -> ChatPage {
        let root = try payload(from: data)
        let rows = root["chats"] as? [[String: Any]] ?? []
        let chats = rows.compactMap(parseChat)
        let hasMore = root["has_more"] as? Bool ?? root["hasMore"] as? Bool
        let token = (root["page_token"] as? String)
            ?? (root["next_page_token"] as? String)
            ?? (root["nextPageToken"] as? String)
        return ChatPage(
            chats: chats,
            nextPageToken: hasMore == false ? nil : token.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    public static func chats(from data: Data) throws -> [LarkChat] {
        try chatPage(from: data).chats
    }

    public static func messages(from data: Data, fallbackChatID: String) throws -> [LarkMessage] {
        try messagePage(from: data, fallbackChatID: fallbackChatID).messages
    }

    public static func messagePage(from data: Data, fallbackChatID: String) throws -> MessagePage {
        let root = try payload(from: data)
        let rows = root["messages"] as? [[String: Any]] ?? []
        let hasMore = root["has_more"] as? Bool ?? root["hasMore"] as? Bool
        let token = (root["page_token"] as? String)
            ?? (root["next_page_token"] as? String)
            ?? (root["nextPageToken"] as? String)
        return MessagePage(
            messages: rows.compactMap { parseMessage($0, fallbackChatID: fallbackChatID) },
            nextPageToken: hasMore == false ? nil : token.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private static func parseChat(_ row: [String: Any]) -> LarkChat? {
        guard let id = row["chat_id"] as? String, id.hasPrefix("oc_") else { return nil }
        let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LarkChat(
            id: id,
            name: name?.isEmpty == false ? name! : "未命名会话",
            description: row["description"] as? String,
            kind: ChatKind(chatMode: row["chat_mode"] as? String),
            external: row["external"] as? Bool ?? false
        )
    }

    private static func parseMessage(_ row: [String: Any], fallbackChatID: String) -> LarkMessage? {
        guard let id = row["message_id"] as? String, id.hasPrefix("om_") else { return nil }
        let senderRow = row["sender"] as? [String: Any] ?? [:]
        let sender = MessageSender(
            id: senderRow["id"] as? String ?? senderRow["sender_id"] as? String,
            name: senderRow["name"] as? String ?? senderRow["id"] as? String ?? "未知发送者",
            type: senderRow["type"] as? String ?? senderRow["sender_type"] as? String
        )
        let type = row["msg_type"] as? String ?? "text"
        let rawContent = stringify(row["content"])
        let deleted = row["deleted"] as? Bool ?? false
        return LarkMessage(
            id: id,
            chatID: row["chat_id"] as? String ?? fallbackChatID,
            type: type,
            createTime: parseDate(row["create_time"]),
            position: parseInt64(row["message_position"]),
            sender: sender,
            content: deleted ? "这条消息已撤回" : readableContent(rawContent, type: type),
            deleted: deleted,
            updated: row["updated"] as? Bool ?? false
        )
    }

    private static func dictionary(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LarkCLIError.malformedResponse
        }
        return object
    }

    private static func payload(from data: Data) throws -> [String: Any] {
        let root = try dictionary(from: data)
        if let ok = root["ok"] as? Bool, !ok { throw LarkCLIError.malformedResponse }
        return root["data"] as? [String: Any] ?? root
    }

    private static func stringify(_ value: Any?) -> String {
        if let string = value as? String { return string }
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }

    private static func parseDate(_ value: Any?) -> Date {
        if let number = value as? NSNumber { return epochDate(number.doubleValue) }
        if let string = value as? String {
            if let number = Double(string) { return epochDate(number) }
            if let date = ISO8601DateFormatter().date(from: string) { return date }
            for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
                let formatter = DateFormatter()
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = .current
                formatter.dateFormat = format
                if let date = formatter.date(from: string) { return date }
            }
        }
        return .distantPast
    }

    private static func parseInt64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    private static func epochDate(_ value: Double) -> Date {
        Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
    }

    private static func readableContent(_ raw: String, type: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return raw.isEmpty ? placeholder(for: type) : normalizeMarkers(raw) }
        if let text = object["text"] as? String { return normalizeMarkers(text) }
        if let title = object["file_name"] as? String { return "附件：\(title)" }
        if let title = object["title"] as? String, !title.isEmpty { return title }
        return placeholder(for: type)
    }

    private static func normalizeMarkers(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"!\[Image\]\(img_[A-Za-z0-9_-]+\)"#, with: "[图片]", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func placeholder(for type: String) -> String {
        switch type {
        case "image": "[图片]"
        case "file": "[文件]"
        case "audio": "[语音]"
        case "video", "media": "[视频]"
        case "interactive": "[互动卡片]"
        case "sticker": "[表情包]"
        case "system": "[系统消息]"
        default: "[暂不支持的消息类型]"
        }
    }
}
