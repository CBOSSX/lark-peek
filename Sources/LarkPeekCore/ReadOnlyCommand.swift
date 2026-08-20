import Foundation

public enum CommandPolicyError: LocalizedError, Equatable {
    case invalidIdentifier
    case invalidPageToken
    case invalidQuery

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "会话标识符格式不合法，命令未执行。"
        case .invalidPageToken: "分页令牌格式不合法，命令未执行。"
        case .invalidQuery: "会话名称不适合搜索，命令未执行。"
        }
    }
}

/// The entire server-facing surface of Lark Peek.
///
/// Keeping this as a closed enum makes it impossible for UI input to dispatch
/// arbitrary lark-cli operations. Every case below is classified `Risk: read`
/// by lark-cli 1.0.88.
public enum ReadOnlyCommand: Equatable, Sendable {
    case authStatus
    case recentChats(pageToken: String? = nil, pageSize: Int = 100)
    case searchChats(query: String, pageSize: Int = 20)
    case recentMessages(chatID: String, pageToken: String? = nil, pageSize: Int = 20)

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
}

public enum LarkCLIError: LocalizedError, Equatable {
    case executableNotFound
    case executionFailed(String)
    case malformedResponse
    case authorization(message: String, missingScopes: [String])

    public var errorDescription: String? {
        switch self {
        case .executableNotFound: "未找到 lark-cli。请从菜单栏为 Lark Peek 选择它的位置。"
        case let .executionFailed(message): message
        case .malformedResponse: "lark-cli 返回了无法解析的数据。"
        case let .authorization(message, missing):
            missing.isEmpty ? message : "\(message)（缺少：\(missing.joined(separator: ", "))）"
        }
    }
}
