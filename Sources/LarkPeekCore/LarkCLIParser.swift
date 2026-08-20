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

    public static func chatDetails(from data: Data, chatID: String) throws -> LarkChat {
        guard validChatID(chatID) != nil else { throw LarkCLIError.malformedResponse }
        let root = try payload(from: data)
        let name = (root["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LarkChat(
            id: chatID,
            name: name?.isEmpty == false ? name! : "未命名群聊",
            description: root["description"] as? String,
            kind: ChatKind(chatMode: root["chat_mode"] as? String),
            external: root["external"] as? Bool ?? false
        )
    }

    public static func messages(from data: Data, fallbackChatID: String) throws -> [LarkMessage] {
        try messagePage(from: data, fallbackChatID: fallbackChatID).messages
    }

    public static func downloadedResourcePath(from data: Data) throws -> String {
        let root = try payload(from: data)
        guard let path = root["saved_path"] as? String, !path.isEmpty else {
            throw LarkCLIError.malformedResponse
        }
        return path
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
        let parsedContent = readableContent(rawContent, type: type)
        return LarkMessage(
            id: id,
            chatID: row["chat_id"] as? String ?? fallbackChatID,
            type: type,
            createTime: parseDate(row["create_time"]),
            position: parseInt64(row["message_position"]),
            sender: sender,
            content: deleted ? "这条消息已撤回" : parsedContent.text,
            images: deleted ? [] : parsedContent.imageKeys.map { MessageImage(key: $0) },
            sharedChatID: deleted ? nil : parsedContent.sharedChatID,
            sharedChatName: deleted ? nil : parsedContent.sharedChatName,
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

    private struct ReadableContent {
        let text: String
        let imageKeys: [String]
        let sharedChatID: String?
        let sharedChatName: String?
    }

    private static func readableContent(_ raw: String, type: String) -> ReadableContent {
        if type == "interactive", let markup = cardMarkup(in: raw) {
            return ReadableContent(
                text: markup,
                imageKeys: imageKeys(in: raw),
                sharedChatID: sharedChatID(in: raw),
                sharedChatName: nil
            )
        }
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ReadableContent(
                text: raw.isEmpty ? placeholder(for: type) : normalizeMarkers(raw),
                imageKeys: imageKeys(in: raw),
                sharedChatID: sharedChatID(in: raw),
                sharedChatName: nil
            )
        }

        let images = imageKeys(in: object)
        let sharedChatID = (object["chat_id"] as? String).flatMap(validChatID)
            ?? sharedChatID(in: raw)
        let text: String
        if type == "interactive", let cardText = cardText(in: object) {
            text = cardText
        } else if let value = object["text"] as? String {
            text = normalizeMarkers(value)
        } else if let title = object["file_name"] as? String {
            text = "附件：\(title)"
        } else if let title = object["title"] as? String, !title.isEmpty {
            text = title
        } else if sharedChatID != nil || type == "share_chat" {
            text = "分享了一个群聊"
        } else {
            text = placeholder(for: type)
        }
        let sharedChatName = (object["chat_name"] as? String) ?? (object["name"] as? String)
        return ReadableContent(
            text: text,
            imageKeys: images,
            sharedChatID: sharedChatID,
            sharedChatName: sharedChatName
        )
    }

    private static func normalizeMarkers(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: #"!\[Image\]\(img_[A-Za-z0-9_-]+\)"#, with: "[图片]", options: .regularExpression)
            .replacingOccurrences(of: #"\[Image:\s*img_[A-Za-z0-9_-]+\]"#, with: "[图片]", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\[Image\]\(img_[A-Za-z0-9_-]+\)"#, with: "[图片]", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "[图片]" : normalized
    }

    private static func cardMarkup(in text: String) -> String? {
        guard text.range(of: #"<\s*card\b"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        let title = matches(
            in: text,
            pattern: #"<\s*card\b[^>]*\btitle\s*=\s*[\"']([^\"']*)[\"'][^>]*>"#,
            captureGroup: 1
        ).first
        var body = text
            .replacingOccurrences(of: #"<\s*card\b[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<\s*/\s*card\s*>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<\s*br\s*/?\s*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\(ou_[A-Za-z0-9_-]+\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        body = decodeBasicEntities(in: body)
        let titleText = title.map { decodeBasicEntities(in: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [titleText.map { "**\($0)**" }, body.isEmpty ? nil : body]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    private static func decodeBasicEntities(in text: String) -> String {
        text
            .replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
            .replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
            .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&#39;", with: "'", options: .caseInsensitive)
            .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
    }

    private static func imageKeys(in value: Any) -> [String] {
        var keys: [String] = []
        func collect(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                if let key = dictionary["image_key"] as? String, validImageKey(key) != nil {
                    keys.append(key)
                }
                for nested in dictionary.values { collect(nested) }
            } else if let array = value as? [Any] {
                for nested in array { collect(nested) }
            } else if let string = value as? String {
                keys.append(contentsOf: imageKeys(in: string))
            }
        }
        collect(value)
        return keys.reduce(into: []) { result, key in
            if !result.contains(key) { result.append(key) }
        }
    }

    private static func imageKeys(in text: String) -> [String] {
        matches(in: text, pattern: #"img_[A-Za-z0-9_-]+"#)
            .compactMap(validImageKey)
    }

    private static func sharedChatID(in text: String) -> String? {
        matches(in: text, pattern: #"\[Chat card:\s*(oc_[A-Za-z0-9_-]+)\]"#, captureGroup: 1)
            .compactMap(validChatID)
            .first
    }

    private static func validImageKey(_ value: String) -> String? {
        value.range(of: #"^img_[A-Za-z0-9_-]+$"#, options: .regularExpression) == nil ? nil : value
    }

    private static func validChatID(_ value: String) -> String? {
        value.range(of: #"^oc_[A-Za-z0-9_-]+$"#, options: .regularExpression) == nil ? nil : value
    }

    private static func matches(in text: String, pattern: String, captureGroup: Int = 0) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard captureGroup < match.numberOfRanges,
                  let range = Range(match.range(at: captureGroup), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func cardText(in object: [String: Any]) -> String? {
        var parts: [String] = []
        var seen: Set<String> = []
        func append(_ value: String) {
            let normalized = normalizeMarkers(value)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return }
            parts.append(normalized)
        }
        func collect(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                if let content = dictionary["content"] as? String { append(content) }
                if let text = dictionary["text"] as? String { append(text) }
                if let title = dictionary["title"] as? String { append(title) }
                let orderedKeys = ["title", "text", "fields", "elements", "actions", "columns", "body"]
                for key in orderedKeys {
                    if let nested = dictionary[key], !(nested is String) { collect(nested) }
                }
            } else if let array = value as? [Any] {
                for nested in array { collect(nested) }
            }
        }
        if let header = object["header"] { collect(header) }
        if let body = object["body"] { collect(body) }
        if let elements = object["elements"] { collect(elements) }
        if parts.isEmpty { collect(object) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
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
