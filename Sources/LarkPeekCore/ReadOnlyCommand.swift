import Foundation

public enum CommandPolicyError: LocalizedError, Equatable {
    case invalidIdentifier
    case invalidPageToken
    case invalidQuery
    case invalidResourceKey
    case invalidOutputPath

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "会话标识符格式不合法，命令未执行。"
        case .invalidPageToken: "分页令牌格式不合法，命令未执行。"
        case .invalidQuery: "会话名称不适合搜索，命令未执行。"
        case .invalidResourceKey: "图片资源标识符格式不合法，命令未执行。"
        case .invalidOutputPath: "图片临时路径不安全，命令未执行。"
        }
    }
}

/// The entire server-facing surface of Lark Peek.
///
/// Keeping this as a closed enum makes it impossible for UI input to dispatch
/// arbitrary lark-cli operations. Every case below is server-side read-only.
/// The image resource command is classified as a local write because it uses a
/// temporary output file; the app removes that file immediately after reading it.
public enum ReadOnlyCommand: Equatable, Sendable {
    case authStatus
    case recentChats(pageToken: String? = nil, pageSize: Int = 100)
    case searchChats(query: String, pageSize: Int = 20)
    case chatDetails(chatID: String)
    case recentMessages(chatID: String, pageToken: String? = nil, pageSize: Int = 20)
    case threadMessages(threadID: String, pageToken: String? = nil, pageSize: Int = 50)
    /// Performs a server-side GET and writes only to an app-controlled temporary file.
    case messageImage(messageID: String, fileKey: String, outputPath: String)

    public func arguments() throws -> [String] {
        switch self {
        case .authStatus:
            return ["auth", "status", "--json", "--verify"]

        case let .recentChats(pageToken, pageSize):
            var arguments = [
                "im", "+chat-list",
                "--as", "user",
                "--types", "p2p,group",
                "--sort", "active_time",
                "--page-size", String(min(max(pageSize, 1), 100)),
                "--format", "json"
            ]
            try appendPageToken(pageToken, to: &arguments)
            return arguments

        case let .searchChats(query, pageSize):
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 64, !trimmed.contains("\0") else {
                throw CommandPolicyError.invalidQuery
            }
            return [
                "im", "+chat-search",
                "--as", "user",
                "--query", trimmed,
                "--search-types", "private,public_joined,external",
                "--page-size", String(min(max(pageSize, 1), 100)),
                "--format", "json"
            ]

        case let .chatDetails(chatID):
            try validateChatID(chatID)
            return [
                "im", "chats", "get",
                "--as", "user",
                "--chat-id", chatID,
                "--format", "json"
            ]

        case let .recentMessages(chatID, pageToken, pageSize):
            try validateChatID(chatID)
            var arguments = [
                "im", "+chat-messages-list",
                "--as", "user",
                "--chat-id", chatID,
                "--order", "desc",
                "--page-size", String(min(max(pageSize, 1), 50)),
                "--no-reactions",
                "--format", "json"
            ]
            try appendPageToken(pageToken, to: &arguments)
            return arguments

        case let .threadMessages(threadID, pageToken, pageSize):
            try validateThreadID(threadID)
            var arguments = [
                "im", "+threads-messages-list",
                "--as", "user",
                "--thread", threadID,
                "--order", "asc",
                "--page-size", String(min(max(pageSize, 1), 50)),
                "--no-reactions",
                "--format", "json"
            ]
            try appendPageToken(pageToken, to: &arguments)
            return arguments

        case let .messageImage(messageID, fileKey, outputPath):
            try validateMessageID(messageID)
            try validateImageKey(fileKey)
            guard !outputPath.isEmpty, outputPath.count <= 512,
                  !outputPath.contains("/"), !outputPath.contains("\\"),
                  !outputPath.contains(".."), !outputPath.contains("\0") else {
                throw CommandPolicyError.invalidOutputPath
            }
            return [
                "im", "+messages-resources-download",
                "--as", "user",
                "--message-id", messageID,
                "--file-key", fileKey,
                "--type", "image",
                "--output", outputPath,
                "--format", "json"
            ]
        }
    }

    private func appendPageToken(_ token: String?, to arguments: inout [String]) throws {
        guard let token, !token.isEmpty else { return }
        guard token.count <= 2048, !token.contains("\0"), !token.contains("\n") else {
            throw CommandPolicyError.invalidPageToken
        }
        arguments.append(contentsOf: ["--page-token", token])
    }

    private func validateChatID(_ value: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard value.hasPrefix("oc_"), value.count <= 256,
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CommandPolicyError.invalidIdentifier
        }
    }

    private func validateMessageID(_ value: String) throws {
        guard isSafeIdentifier(value, prefix: "om_") else {
            throw CommandPolicyError.invalidIdentifier
        }
    }

    private func validateThreadID(_ value: String) throws {
        guard isSafeIdentifier(value, prefix: "omt_") || isSafeIdentifier(value, prefix: "om_") else {
            throw CommandPolicyError.invalidIdentifier
        }
    }

    private func validateImageKey(_ value: String) throws {
        guard isSafeIdentifier(value, prefix: "img_") else {
            throw CommandPolicyError.invalidResourceKey
        }
    }

    private func isSafeIdentifier(_ value: String, prefix: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return value.hasPrefix(prefix) && value.count <= 512
            && value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

public enum LarkCLIError: LocalizedError, Equatable {
    case executableNotFound
    case keychainAccessBlocked
    case executionFailed(String)
    case malformedResponse
    case authorization(message: String, missingScopes: [String])

    public var errorDescription: String? {
        switch self {
        case .executableNotFound: "未找到 lark-cli。请从菜单栏为 Lark Peek 选择它的位置。"
        case .keychainAccessBlocked:
            "无法读取 macOS 登录钥匙串。请先在“钥匙串访问”中解锁 login 钥匙串，再点重试；现有 lark-cli 登录数据仍然保留。"
        case let .executionFailed(message): message
        case .malformedResponse: "lark-cli 返回了无法解析的数据。"
        case let .authorization(message, missing):
            missing.isEmpty ? message : "\(message)（缺少：\(missing.joined(separator: ", "))）"
        }
    }
}
