import Combine
import CryptoKit
import Foundation
import OSLog

private let peekModelLogger = Logger(subsystem: "io.github.cbossx.larkpeek", category: "Pagination")
private let chatMatchLogger = Logger(subsystem: "io.github.cbossx.larkpeek", category: "ChatMatching")

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

            var matches = ChatMatcher.exactMatches(name: conversation.name, in: recentChats)
            chatMatchLogger.info(
                "Checked cached chats target=\(conversation.name, privacy: .private(mask: .hash)) cachedCount=\(self.recentChats.count) exactCount=\(matches.count)"
            )
            if matches.isEmpty {
                // The activity-sorted first page is only a startup snapshot. A
                // newly active P2P chat may have moved into it since prewarming.
                try await loadFirstChatPage(using: client)
                matches = ChatMatcher.exactMatches(name: conversation.name, in: recentChats)
                chatMatchLogger.info(
                    "Refreshed recent chats target=\(conversation.name, privacy: .private(mask: .hash)) refreshedCount=\(self.recentChats.count) exactCount=\(matches.count)"
                )
            }
            if matches.isEmpty {
                matches = try await findExactByPagingRecentChats(name: conversation.name, using: client)
                chatMatchLogger.info(
                    "Finished exact paged lookup target=\(conversation.name, privacy: .private(mask: .hash)) indexedCount=\(self.recentChats.count) exactCount=\(matches.count)"
                )
            }
            if matches.isEmpty {
                // +chat-search only searches groups. Its fuzzy results must not
                // prevent a P2P exact match from being found in chat-list pages.
                let result = try await client.run(.searchChats(query: conversation.name, pageSize: 30))
                let searched = try LarkCLIParser.chats(from: result.data)
                mergeChats(searched)
                matches = ChatMatcher.exactMatches(name: conversation.name, in: searched)
                chatMatchLogger.info(
                    "Checked group search target=\(conversation.name, privacy: .private(mask: .hash)) searchedCount=\(searched.count) exactCount=\(matches.count)"
                )
            }
            if matches.isEmpty {
                matches = ChatMatcher.fuzzyMatches(name: conversation.name, in: recentChats)
                chatMatchLogger.info(
                    "Falling back to fuzzy candidates target=\(conversation.name, privacy: .private(mask: .hash)) candidateCount=\(matches.count)"
                )
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
            let client = try requireClient()
            let result = try await client.run(
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
            let namedMessages = await resolveSharedChatNames(in: mergedMessages, using: client)
            let threadedMessages = await hydrateThreadReplies(in: namedMessages, using: client)
            state = .messages(
                conversation,
                chat,
                threadedMessages,
                Date()
            )
            let hydratedMessages = await downloadImages(in: threadedMessages, using: client)
            guard case let .messages(_, hydratedChat, _, _) = state,
                  hydratedChat.id == chat.id else { return }
            state = .messages(conversation, chat, hydratedMessages, Date())
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
            LarkMessage(id: "om_preview_1", chatID: chat.id, createTime: now.addingTimeInterval(-320), sender: MessageSender(name: "林澈"), content: "<p>新的 **Markdown** 预览已经可以体验了。</p><p>- 无序列表\n  - 嵌套列表\n> 引用内容</p>"),
            LarkMessage(id: "om_preview_2", chatID: chat.id, type: "interactive", createTime: now.addingTimeInterval(-180), sender: MessageSender(name: "周然"), content: "**体验提醒**\n鼠标停在飞书会话上，长按 ⌥，或按 ⌃⌥P 查看最近消息。"),
            LarkMessage(
                id: "om_preview_3",
                chatID: chat.id,
                type: "merge_forward",
                createTime: now.addingTimeInterval(-120),
                sender: MessageSender(name: "周然"),
                content: "合并转发 · 3 条消息",
                forwardedMessages: [
                    ForwardedMessageItem(createTime: now.addingTimeInterval(-900), senderName: "林澈", content: "第一条转发内容"),
                    ForwardedMessageItem(createTime: now.addingTimeInterval(-840), senderName: "周然", content: "支持 **Markdown** 和多行正文"),
                    ForwardedMessageItem(createTime: now.addingTimeInterval(-780), senderName: "林澈", content: "阅读起来更像聊天记录")
                ]
            ),
            LarkMessage(
                id: "om_preview_4",
                chatID: chat.id,
                createTime: now.addingTimeInterval(-75),
                sender: MessageSender(name: "林澈"),
                content: "这个方案大家觉得怎么样？",
                threadID: "omt_preview",
                threadReplies: [
                    LarkMessage(id: "om_preview_reply_1", chatID: chat.id, createTime: now.addingTimeInterval(-65), sender: MessageSender(name: "周然"), content: "信息层级清楚多了。"),
                    LarkMessage(id: "om_preview_reply_2", chatID: chat.id, createTime: now.addingTimeInterval(-55), sender: MessageSender(name: "林澈"), content: "那就按这个方向继续。")
                ],
                threadRepliesLoaded: true
            ),
            LarkMessage(id: "om_preview_5", chatID: chat.id, type: "share_chat", createTime: now.addingTimeInterval(-45), sender: MessageSender(name: "Lark Peek"), content: "分享了一个群聊", sharedChatID: "oc_preview_shared", sharedChatName: "产品设计交流群")
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

    private func findExactByPagingRecentChats(name: String, using client: LarkCLIClient) async throws -> [LarkChat] {
        var token = nextPageToken
        for _ in 0..<4 {
            try Task.checkCancellation()
            guard let pageToken = token else { return [] }
            let result = try await client.run(.recentChats(pageToken: pageToken, pageSize: 100))
            let page = try LarkCLIParser.chatPage(from: result.data)
            mergeChats(page.chats)
            nextPageToken = page.nextPageToken
            let matches = ChatMatcher.exactMatches(name: name, in: page.chats)
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
        let namedMessages = await resolveSharedChatNames(in: messages, using: client)
        try Task.checkCancellation()
        guard case let .messages(_, namedChat, _, _) = state,
              namedChat.id == chat.id else { return }
        state = .messages(conversation, chat, namedMessages, Date())
        let threadedMessages = await hydrateThreadReplies(in: namedMessages, using: client)
        try Task.checkCancellation()
        guard case let .messages(_, threadedChat, _, _) = state,
              threadedChat.id == chat.id else { return }
        state = .messages(conversation, chat, threadedMessages, Date())
        let hydratedMessages = await downloadImages(in: threadedMessages, using: client)
        try Task.checkCancellation()
        guard case let .messages(_, visibleChat, _, _) = state,
              visibleChat.id == chat.id else { return }
        state = .messages(conversation, chat, hydratedMessages, Date())
        peekModelLogger.info(
            "Loaded initial messages chat=\(chat.id, privacy: .private(mask: .hash)) count=\(messages.count) hasMore=\(page.nextPageToken != nil)"
        )
    }

    private func resetMessagePagination() {
        messageNextPageToken = nil
        hasOlderMessages = false
        isLoadingOlderMessages = false
    }

    private struct ImageRequest: Hashable, Sendable {
        let messageID: String
        let key: String
    }

    private func resolveSharedChatNames(
        in messages: [LarkMessage],
        using client: LarkCLIClient
    ) async -> [LarkMessage] {
        var names = Dictionary(uniqueKeysWithValues: recentChats.map { ($0.id, $0.name) })
        for message in messages {
            if let id = message.sharedChatID, let name = message.sharedChatName {
                names[id] = name
            }
        }
        let unresolved = Array(Set(messages.compactMap { message -> String? in
            guard let id = message.sharedChatID, names[id] == nil else { return nil }
            return id
        }))

        for start in stride(from: 0, to: unresolved.count, by: 3) {
            if Task.isCancelled { return messages }
            let batch = Array(unresolved[start..<min(start + 3, unresolved.count)])
            let chats = await withTaskGroup(of: LarkChat?.self) { group in
                for chatID in batch {
                    group.addTask {
                        guard let result = try? await client.run(.chatDetails(chatID: chatID)) else { return nil }
                        return try? LarkCLIParser.chatDetails(from: result.data, chatID: chatID)
                    }
                }
                var values: [LarkChat] = []
                for await value in group {
                    if let value { values.append(value) }
                }
                return values
            }
            mergeChats(chats)
            for chat in chats { names[chat.id] = chat.name }
        }

        return messages.map { message in
            var message = message
            if let id = message.sharedChatID { message.sharedChatName = names[id] }
            return message
        }
    }

    private struct ImageDownload: Sendable {
        let data: Data?
    }

    private func hydrateThreadReplies(
        in messages: [LarkMessage],
        using client: LarkCLIClient
    ) async -> [LarkMessage] {
        let threadIDs = Array(Set(messages.compactMap { message -> String? in
            guard !message.threadRepliesLoaded else { return nil }
            return message.threadID
        }))
        guard !threadIDs.isEmpty else { return messages }

        var pages: [String: LarkCLIParser.MessagePage] = [:]
        for start in stride(from: 0, to: threadIDs.count, by: 3) {
            if Task.isCancelled { return messages }
            let batch = Array(threadIDs[start..<min(start + 3, threadIDs.count)])
            let results = await withTaskGroup(of: (String, LarkCLIParser.MessagePage?).self) { group in
                for threadID in batch {
                    group.addTask {
                        guard let result = try? await client.run(.threadMessages(threadID: threadID)),
                              let page = try? LarkCLIParser.messagePage(from: result.data, fallbackChatID: "")
                        else { return (threadID, nil) }
                        return (threadID, page)
                    }
                }
                var values: [(String, LarkCLIParser.MessagePage?)] = []
                for await value in group { values.append(value) }
                return values
            }
            for (threadID, page) in results {
                if let page { pages[threadID] = page }
            }
        }

        let requested = Set(threadIDs)
        return messages.map { message in
            guard let threadID = message.threadID, requested.contains(threadID) else { return message }
            var message = message
            message.threadRepliesLoaded = true
            if let page = pages[threadID] {
                message.threadReplies = page.messages.sorted(by: LarkMessage.isChronologicallyBefore)
                message.threadHasMore = page.nextPageToken != nil
            }
            return message
        }
    }

    private func downloadImages(in messages: [LarkMessage], using client: LarkCLIClient) async -> [LarkMessage] {
        let allMessages = messages + messages.flatMap(\.threadReplies)
        let requests = allMessages.flatMap { message in
            message.images.compactMap { image in
                image.data == nil && !image.attempted
                    ? ImageRequest(messageID: message.id, key: image.key)
                    : nil
            }
        }
        guard !requests.isEmpty else { return messages }

        var downloaded: [ImageRequest: ImageDownload] = [:]
        let workingDirectory = self.workingDirectory
        for start in stride(from: 0, to: requests.count, by: 3) {
            if Task.isCancelled { return messages }
            let batch = Array(requests[start..<min(start + 3, requests.count)])
            let results = await withTaskGroup(of: (ImageRequest, ImageDownload).self) { group in
                for request in batch {
                    group.addTask {
                        let data = await Self.downloadImage(
                            request,
                            using: client,
                            workingDirectory: workingDirectory
                        )
                        return (request, ImageDownload(data: data))
                    }
                }
                var values: [(ImageRequest, ImageDownload)] = []
                for await value in group { values.append(value) }
                return values
            }
            for (request, download) in results { downloaded[request] = download }
        }

        return messages.map { message in
            var message = message
            message = applying(downloaded, to: message)
            message.threadReplies = message.threadReplies.map { applying(downloaded, to: $0) }
            return message
        }
    }

    private func applying(_ downloaded: [ImageRequest: ImageDownload], to message: LarkMessage) -> LarkMessage {
        var message = message
        message.images = message.images.map { image in
            let request = ImageRequest(messageID: message.id, key: image.key)
            guard let result = downloaded[request] else { return image }
            return MessageImage(key: image.key, data: result.data, attempted: true)
        }
        return message
    }

    private nonisolated static func downloadImage(
        _ request: ImageRequest,
        using client: LarkCLIClient,
        workingDirectory: URL
    ) async -> Data? {
        let digest = SHA256.hash(data: Data("\(request.messageID):\(request.key)".utf8))
        let filename = "lark-peek-image-"
            + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
            + "-" + UUID().uuidString + ".image"
        let requestedURL = workingDirectory.appendingPathComponent(filename)
        defer { try? FileManager.default.removeItem(at: requestedURL) }
        do {
            let result = try await client.run(.messageImage(
                messageID: request.messageID,
                fileKey: request.key,
                outputPath: filename
            ))
            let savedPath = try LarkCLIParser.downloadedResourcePath(from: result.data)
            let fileURL = URL(fileURLWithPath: savedPath, relativeTo: workingDirectory).standardizedFileURL
            let rootPath = workingDirectory.standardizedFileURL.path
            guard fileURL.path == rootPath || fileURL.path.hasPrefix(rootPath + "/") else { return nil }
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= 15 * 1_024 * 1_024 else {
                return nil
            }
            return try Data(contentsOf: fileURL)
        } catch {
            peekModelLogger.debug(
                "Image download unavailable message=\(request.messageID, privacy: .private(mask: .hash)) key=\(request.key, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private)"
            )
            return nil
        }
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
