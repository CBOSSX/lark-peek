import Combine
import CryptoKit
import Foundation
import OSLog

private let peekModelLogger = Logger(subsystem: "io.github.cbossx.larkpeek", category: "Pagination")

public enum PeekState: Equatable {
    case waiting
    case loading(HoveredConversation)
    case candidates(HoveredConversation, [LarkChat])
    case messages(HoveredConversation, LarkChat, [LarkMessage], Date)
    case error(HoveredConversation?, String)
}

@MainActor
public final class PeekModel: ObservableObject {
    @Published public private(set) var state: PeekState = .waiting
    @Published public private(set) var authStatus = AuthStatus()
    @Published public private(set) var cliPath: String?
    @Published public private(set) var statusMessage = "正在准备只读预览…"
    @Published public private(set) var hasOlderMessages = false
    @Published public private(set) var isLoadingOlderMessages = false

    private var client: LarkCLIClient?
    private var recentChats: [LarkChat] = []
    private var nextPageToken: String?
    private var messageNextPageToken: String?
    private let defaults: UserDefaults
    private let workingDirectory: URL

    public init(defaults: UserDefaults = .standard, workingDirectory: URL = FileManager.default.temporaryDirectory) {
        self.defaults = defaults
        self.workingDirectory = workingDirectory
        configureClient()
    }

    public func start() async {
        await verifyAndPrewarm()
    }

    public func peek(_ conversation: HoveredConversation) async {
        resetMessagePagination()
        state = .loading(conversation)
        do {
            let client = try requireClient()
            if recentChats.isEmpty { try await loadFirstChatPage(using: client) }

            if let rememberedID = rememberedChatID(for: conversation),
               let remembered = recentChats.first(where: { $0.id == rememberedID }) {
                try await loadMessages(for: remembered, conversation: conversation, using: client)
                return
            }

            var matches = ChatMatcher.matches(name: conversation.name, in: recentChats)
            if matches.isEmpty {
                let result = try await client.run(.searchChats(query: conversation.name, pageSize: 30))
                let searched = try LarkCLIParser.chats(from: result.data)
                mergeChats(searched)
                matches = ChatMatcher.matches(name: conversation.name, in: searched)
            }
            if matches.isEmpty {
                matches = try await findByPagingRecentChats(name: conversation.name, using: client)
            }

            switch matches.count {
            case 0:
                state = .error(conversation, "没有找到“\(conversation.name)”对应的已加入会话。")
            case 1:
                try await loadMessages(for: matches[0], conversation: conversation, using: client)
            default:
                state = .candidates(conversation, matches)
            }
        } catch is CancellationError {
            return
        } catch {
            state = .error(conversation, error.localizedDescription)
        }
    }

    public func select(_ chat: LarkChat, for conversation: HoveredConversation) async {
        resetMessagePagination()
        state = .loading(conversation)
        remember(chatID: chat.id, for: conversation)
        do {
            try await loadMessages(for: chat, conversation: conversation, using: requireClient())
        } catch is CancellationError {
            return
        } catch {
            state = .error(conversation, error.localizedDescription)
        }
    }

    public func retryCurrent() async {
        let conversation: HoveredConversation?
        switch state {
        case let .loading(value), let .candidates(value, _), let .messages(value, _, _, _): conversation = value
        case let .error(value, _): conversation = value
        case .waiting: conversation = nil
        }
        guard let conversation else { return }
        await peek(conversation)
    }

    public func dismiss() {
        resetMessagePagination()
        state = .waiting
    }

    public func presentError(_ message: String) {
        resetMessagePagination()
        state = .error(nil, message)
    }

    public func loadOlderMessages() async {
        guard !isLoadingOlderMessages else {
            peekModelLogger.debug("Ignoring older-message request: a page is already loading")
            return
        }
        guard let pageToken = messageNextPageToken else {
            peekModelLogger.debug("Ignoring older-message request: no next-page token")
            return
        }
        guard case let .messages(conversation, chat, currentMessages, _) = state else {
            peekModelLogger.debug("Ignoring older-message request: timeline is not visible")
            return
        }

        let startedAt = Date()
        peekModelLogger.info(
            "Loading older messages chat=\(chat.id, privacy: .private(mask: .hash)) token=\(pageToken, privacy: .private(mask: .hash)) currentCount=\(currentMessages.count)"
        )
        isLoadingOlderMessages = true
        defer { isLoadingOlderMessages = false }
        do {
            let result = try await requireClient().run(
                .recentMessages(chatID: chat.id, pageToken: pageToken, pageSize: 20)
            )
            let page = try LarkCLIParser.messagePage(from: result.data, fallbackChatID: chat.id)
            try Task.checkCancellation()
            guard case let .messages(_, visibleChat, _, _) = state,
                  visibleChat.id == chat.id else {
                peekModelLogger.debug("Discarding older-message page because the visible chat changed")
                return
            }

            if page.nextPageToken == pageToken {
                peekModelLogger.error(
                    "Stopping pagination because the server repeated the same page token chat=\(chat.id, privacy: .private(mask: .hash))"
                )
                messageNextPageToken = nil
                hasOlderMessages = false
            } else {
                messageNextPageToken = page.nextPageToken
                hasOlderMessages = page.nextPageToken != nil
            }
            let mergedMessages = MessageTimeline.merging(page.messages, into: currentMessages)
            state = .messages(
                conversation,
                chat,
                mergedMessages,
                Date()
            )
            let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
            peekModelLogger.info(
                "Loaded older messages chat=\(chat.id, privacy: .private(mask: .hash)) pageCount=\(page.messages.count) mergedCount=\(mergedMessages.count) hasMore=\(page.nextPageToken != nil) elapsedMs=\(elapsedMilliseconds)"
            )
        } catch is CancellationError {
            peekModelLogger.debug(
                "Older-message request cancelled chat=\(chat.id, privacy: .private(mask: .hash))"
            )
            return
        } catch {
            peekModelLogger.error(
                "Older-message request failed chat=\(chat.id, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private)"
            )
            statusMessage = "加载更早消息失败：\(error.localizedDescription)"
        }
    }

    public func showPreviewFixture() {
        resetMessagePagination()
        let conversation = HoveredConversation(
            name: "产品体验群",
            rowFrame: CGRect(x: 280, y: 220, width: 420, height: 62),
            rowTexts: ["产品体验群", "14:20", "林澈", "新的悬停预览已经可以体验了"]
        )
        let chat = LarkChat(id: "oc_preview", name: "产品体验群", kind: .group)
        let now = Date()
        let messages = [
            LarkMessage(id: "om_preview_1", chatID: chat.id, createTime: now.addingTimeInterval(-320), sender: MessageSender(name: "林澈"), content: "新的悬停预览已经可以体验了。"),
            LarkMessage(id: "om_preview_2", chatID: chat.id, createTime: now.addingTimeInterval(-180), sender: MessageSender(name: "周然"), content: "鼠标停在飞书会话上，按 ⌃⌥P 就能看到最近消息。"),
            LarkMessage(id: "om_preview_3", chatID: chat.id, createTime: now.addingTimeInterval(-45), sender: MessageSender(name: "Lark Peek"), content: "不会打开飞书会话，也没有跳转按钮。")
        ]
        state = .messages(conversation, chat, messages, now)
        statusMessage = "视觉预览模式"
    }

    public func configureCLI(at url: URL?) async {
        if let url { defaults.set(url.path, forKey: "selectedLarkCLIPath") }
        else { defaults.removeObject(forKey: "selectedLarkCLIPath") }
        configureClient()
        recentChats = []
        nextPageToken = nil
        await verifyAndPrewarm()
    }

    private func configureClient() {
        let selected = defaults.string(forKey: "selectedLarkCLIPath").map(URL.init(fileURLWithPath:))
        do {
            let resolved = try LarkCLIClient(executableURL: selected, workingDirectory: workingDirectory)
            client = resolved
            cliPath = resolved.cliURL.path
            statusMessage = "只读预览已就绪"
        } catch {
            client = nil
            cliPath = nil
            authStatus = AuthStatus(state: .error(error.localizedDescription))
            statusMessage = error.localizedDescription
        }
    }

    private func verifyAndPrewarm() async {
        guard let client else { return }
        authStatus = AuthStatus(state: .checking)
        statusMessage = "正在检查 lark-cli 登录状态…"
        do {
            let auth = try await client.run(.authStatus)
            authStatus = try LarkCLIParser.authStatus(from: auth.data)
            guard authStatus.state == .ready else {
                statusMessage = "lark-cli 用户登录尚未就绪"
                return
            }
            statusMessage = "正在缓存最近会话索引…"
            try await loadFirstChatPage(using: client)
            statusMessage = "只读预览已就绪 · 已索引最近 \(recentChats.count) 个会话"
        } catch {
            authStatus = AuthStatus(state: .error(error.localizedDescription))
            statusMessage = error.localizedDescription
        }
    }

    private func requireClient() throws -> LarkCLIClient {
        guard let client else { throw LarkCLIError.executableNotFound }
        return client
    }

    private func loadFirstChatPage(using client: LarkCLIClient) async throws {
        let result = try await client.run(.recentChats(pageSize: 100))
        let page = try LarkCLIParser.chatPage(from: result.data)
        recentChats = page.chats
        nextPageToken = page.nextPageToken
    }

    private func findByPagingRecentChats(name: String, using client: LarkCLIClient) async throws -> [LarkChat] {
        var token = nextPageToken
        for _ in 0..<4 {
            try Task.checkCancellation()
            guard let pageToken = token else { return [] }
            let result = try await client.run(.recentChats(pageToken: pageToken, pageSize: 100))
            let page = try LarkCLIParser.chatPage(from: result.data)
            mergeChats(page.chats)
            nextPageToken = page.nextPageToken
            let matches = ChatMatcher.matches(name: name, in: page.chats)
            if !matches.isEmpty { return matches }
            token = page.nextPageToken
        }
        return []
    }

    private func mergeChats(_ chats: [LarkChat]) {
        var known = Set(recentChats.map(\.id))
        for chat in chats where known.insert(chat.id).inserted { recentChats.append(chat) }
    }

    private func loadMessages(
        for chat: LarkChat,
        conversation: HoveredConversation,
        using client: LarkCLIClient
    ) async throws {
        try Task.checkCancellation()
        let result = try await client.run(.recentMessages(chatID: chat.id, pageSize: 20))
        let page = try LarkCLIParser.messagePage(from: result.data, fallbackChatID: chat.id)
        messageNextPageToken = page.nextPageToken
        hasOlderMessages = page.nextPageToken != nil
        let messages = page.messages
            .sorted(by: LarkMessage.isChronologicallyBefore)
        state = .messages(conversation, chat, messages, Date())
        peekModelLogger.info(
            "Loaded initial messages chat=\(chat.id, privacy: .private(mask: .hash)) count=\(messages.count) hasMore=\(page.nextPageToken != nil)"
        )
    }

    private func resetMessagePagination() {
        messageNextPageToken = nil
        hasOlderMessages = false
        isLoadingOlderMessages = false
    }

    private func mappingKey(for conversation: HoveredConversation) -> String {
        let digest = SHA256.hash(data: Data(conversation.fingerprint.utf8))
        return "hoverMapping." + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func rememberedChatID(for conversation: HoveredConversation) -> String? {
        defaults.string(forKey: mappingKey(for: conversation))
    }

    private func remember(chatID: String, for conversation: HoveredConversation) {
        defaults.set(chatID, forKey: mappingKey(for: conversation))
    }
}
