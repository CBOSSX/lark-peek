import Combine
import CryptoKit
import Foundation

private let peekModelLogger = LarkPeekDiagnostics.pagination
private let chatMatchLogger = LarkPeekDiagnostics.chatMatching
private let threadMatchLogger = LarkPeekDiagnostics.threadMatching
private let hoverRouteLogger = LarkPeekDiagnostics.hoverRouting

private struct StoredThreadResolution: Codable {
    let threadID: String
    let rootMessageID: String
    let chat: LarkChat
}

private struct ThreadReplyTask {
    let id: UUID
    let task: Task<Void, Never>
}

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
    @Published public private(set) var diagnosticTriggerID: String?

    private var client: LarkCLIClient?
    private var recentChats: [LarkChat] = []
    private var nextPageToken: String?
    private var messageNextPageToken: String?
    private var imageCache: [ImageRequest: Data] = [:]
    private var imageCacheOrder: [ImageRequest] = []
    private var imageCacheBytes = 0
    private var threadReplyTasks: [String: ThreadReplyTask] = [:]
    private var activeThreadReplyRequestCount = 0
    private var pendingThreadReplyRequests: [CheckedContinuation<Void, Never>] = []
    private let defaults: UserDefaults
    private let workingDirectory: URL

    private static let maximumImageCacheBytes = 64 * 1_024 * 1_024

    public init(defaults: UserDefaults = .standard, workingDirectory: URL = FileManager.default.temporaryDirectory) {
        self.defaults = defaults
        self.workingDirectory = workingDirectory
        configureClient()
    }

    public func start() async {
        await verifyAndPrewarm()
    }

    public func authorize(openVerificationURL: (URL) -> Bool) async {
        guard let client else { return }
        let missingScopes = authStatus.missingRequiredScopes
        guard !missingScopes.isEmpty else {
            await verifyAndPrewarm()
            return
        }

        authStatus.state = .checking
        statusMessage = "正在准备飞书最小权限授权…"
        LarkPeekDiagnostics.lifecycle.notice(
            "event=authorization_started missingScopes=\(missingScopes.count)"
        )
        do {
            let result = try await client.run(.begin(scopes: missingScopes))
            let request = try LarkCLIParser.authorizationRequest(from: result.data)
            guard openVerificationURL(request.verificationURL) else {
                authStatus.state = .needsLogin
                statusMessage = "无法打开飞书授权页面，请重试。"
                return
            }

            statusMessage = "请在浏览器中确认飞书只读权限…"
            _ = try await client.run(.complete(deviceCode: request.deviceCode))
            LarkPeekDiagnostics.lifecycle.notice("event=authorization_completed")
            statusMessage = "授权成功，正在验证权限…"
            await verifyAndPrewarm()
        } catch is CancellationError {
            LarkPeekDiagnostics.lifecycle.info("event=authorization_cancelled")
            authStatus.state = .needsLogin
            statusMessage = "飞书授权已取消"
        } catch {
            LarkPeekDiagnostics.lifecycle.error(
                "event=authorization_failed code=\(LarkPeekDiagnostics.errorKind(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
            // Keep the authorization action available after an expired device
            // code, a browser cancellation, or a transient network failure.
            authStatus.state = .needsLogin
            statusMessage = error.localizedDescription
        }
    }

    public func peek(_ conversation: HoveredConversation) async {
        cancelTransientRequests()
        let trigger = LarkPeekDiagnostics.triggerID ?? "none"
        diagnosticTriggerID = trigger
        resetMessagePagination()
        state = .loading(conversation)
        hoverRouteLogger.info(
            "event=peek_started trigger=\(trigger, privacy: .public) nodes=\(conversation.rowTexts.count)"
        )
        do {
            let client = try requireClient()
            let hint = conversation.threadHint
            let rowShape = conversation.rowTexts.map { text in
                let hasColon = text.contains(":") || text.contains("：")
                let hasClock = text.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil
                return "\(text.count):\(hasColon ? "c" : "-")\(hasClock ? "t" : "-")"
            }.joined(separator: ",")
            hoverRouteLogger.info(
                "event=route_classified trigger=\(trigger, privacy: .public) nodes=\(conversation.rowTexts.count) shape=\(rowShape, privacy: .public) threadHint=\(hint != nil) target=\(conversation.name, privacy: .private(mask: .hash))"
            )

            if let hint {
                if let stored = rememberedThread(for: hint) {
                    let cachedRoot = LarkMessage(
                        id: stored.rootMessageID,
                        chatID: stored.chat.id,
                        createTime: Date(),
                        sender: MessageSender(name: hint.rootSender),
                        content: hint.rootExcerpt,
                        threadID: stored.threadID
                    )
                    do {
                        try await loadThread(
                            root: cachedRoot,
                            chat: stored.chat,
                            conversation: conversation,
                            using: client
                        )
                        return
                    } catch is CancellationError {
                        return
                    } catch {
                        forgetThread(for: hint)
                        threadMatchLogger.info(
                            "event=stale_mapping_discarded trigger=\(trigger, privacy: .public) key=\(hint.stableFingerprint, privacy: .private(mask: .hash)) code=\(LarkPeekDiagnostics.errorKind(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)"
                        )
                    }
                }

                do {
                    if let hit = try await findThread(for: hint, using: client) {
                        remember(thread: hit, for: hint)
                        try await loadThread(
                            root: hit.rootMessage,
                            chat: hit.chat,
                            conversation: conversation,
                            using: client
                        )
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    threadMatchLogger.info(
                        "event=fast_path_failed trigger=\(trigger, privacy: .public) query=\(hint.searchQuery, privacy: .private(mask: .hash)) code=\(LarkPeekDiagnostics.errorKind(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)"
                    )
                    state = .error(conversation, "话题检索失败，请稍后重试。")
                    return
                }

                // This row has the standalone-topic shape. Falling through to
                // chat/contact matching can open an unrelated P2P conversation
                // whose name happens to equal the topic author.
                state = .error(conversation, "没有定位到这个话题，请稍后重试。")
                return
            }

            if recentChats.isEmpty { try await loadFirstChatPage(using: client) }

            if let rememberedID = rememberedChatID(for: conversation),
               let remembered = recentChats.first(where: { $0.id == rememberedID }) {
                try await loadMessages(for: remembered, conversation: conversation, using: client)
                return
            }

            var matches = ChatMatcher.exactMatches(name: conversation.name, in: recentChats)
            chatMatchLogger.info(
                "event=cached_lookup trigger=\(trigger, privacy: .public) target=\(conversation.name, privacy: .private(mask: .hash)) chats=\(self.recentChats.count) exact=\(matches.count)"
            )
            if matches.isEmpty {
                // The activity-sorted first page is only a startup snapshot. A
                // newly active P2P chat may have moved into it since prewarming.
                try await loadFirstChatPage(using: client)
                matches = ChatMatcher.exactMatches(name: conversation.name, in: recentChats)
                chatMatchLogger.info(
                    "event=refreshed_lookup trigger=\(trigger, privacy: .public) target=\(conversation.name, privacy: .private(mask: .hash)) chats=\(self.recentChats.count) exact=\(matches.count)"
                )
            }
            if matches.isEmpty {
                matches = try await findExactByPagingRecentChats(name: conversation.name, using: client)
                chatMatchLogger.info(
                    "event=paged_lookup_completed trigger=\(trigger, privacy: .public) target=\(conversation.name, privacy: .private(mask: .hash)) chats=\(self.recentChats.count) exact=\(matches.count)"
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
                    "event=group_search_completed trigger=\(trigger, privacy: .public) target=\(conversation.name, privacy: .private(mask: .hash)) searched=\(searched.count) exact=\(matches.count)"
                )
            }
            if matches.isEmpty {
                matches = ChatMatcher.fuzzyMatches(name: conversation.name, in: recentChats)
                chatMatchLogger.info(
                    "event=fuzzy_fallback trigger=\(trigger, privacy: .public) target=\(conversation.name, privacy: .private(mask: .hash)) candidates=\(matches.count)"
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
            hoverRouteLogger.info(
                "event=peek_cancelled trigger=\(trigger, privacy: .public)"
            )
            return
        } catch {
            hoverRouteLogger.error(
                "event=peek_failed trigger=\(trigger, privacy: .public) code=\(LarkPeekDiagnostics.errorKind(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
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
        cancelTransientRequests()
        resetMessagePagination()
        diagnosticTriggerID = nil
        state = .waiting
    }

    public func presentError(_ message: String) {
        cancelTransientRequests()
        resetMessagePagination()
        state = .error(nil, message)
    }

    public func loadOlderMessages() async {
        let trigger = LarkPeekDiagnostics.triggerID ?? diagnosticTriggerID ?? "none"
        guard !isLoadingOlderMessages else {
            peekModelLogger.debug(
                "event=older_page_ignored trigger=\(trigger, privacy: .public) reason=already_loading"
            )
            return
        }
        guard let pageToken = messageNextPageToken else {
            peekModelLogger.debug(
                "event=older_page_ignored trigger=\(trigger, privacy: .public) reason=no_page_token"
            )
            return
        }
        guard case let .messages(conversation, chat, currentMessages, _) = state else {
            peekModelLogger.debug(
                "event=older_page_ignored trigger=\(trigger, privacy: .public) reason=timeline_not_visible"
            )
            return
        }

        let startedAt = Date()
        peekModelLogger.info(
            "event=older_page_started trigger=\(trigger, privacy: .public) chat=\(chat.id, privacy: .private(mask: .hash)) token=\(pageToken, privacy: .private(mask: .hash)) current=\(currentMessages.count)"
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
                peekModelLogger.debug(
                    "event=older_page_discarded trigger=\(trigger, privacy: .public) reason=chat_changed"
                )
                return
            }

            if page.nextPageToken == pageToken {
                peekModelLogger.error(
                    "event=pagination_stopped trigger=\(trigger, privacy: .public) reason=repeated_token chat=\(chat.id, privacy: .private(mask: .hash))"
                )
                messageNextPageToken = nil
                hasOlderMessages = false
            } else {
                messageNextPageToken = page.nextPageToken
                hasOlderMessages = page.nextPageToken != nil
            }
            let mergedMessages = MessageTimeline.merging(page.messages, into: currentMessages)
            let namedMessages = await resolveSharedChatNames(in: mergedMessages, using: client)
            state = .messages(conversation, chat, namedMessages, Date())
            let hydratedMessages = await downloadImages(in: namedMessages, using: client)
            guard case let .messages(_, hydratedChat, _, _) = state,
                  hydratedChat.id == chat.id else { return }
            state = .messages(conversation, chat, hydratedMessages, Date())
            let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
            peekModelLogger.info(
                "event=older_page_succeeded trigger=\(trigger, privacy: .public) chat=\(chat.id, privacy: .private(mask: .hash)) pageCount=\(page.messages.count) mergedCount=\(mergedMessages.count) hasMore=\(page.nextPageToken != nil) elapsedMs=\(elapsedMilliseconds)"
            )
        } catch is CancellationError {
            peekModelLogger.debug(
                "event=older_page_cancelled trigger=\(trigger, privacy: .public) chat=\(chat.id, privacy: .private(mask: .hash))"
            )
            return
        } catch {
            peekModelLogger.error(
                "event=older_page_failed trigger=\(trigger, privacy: .public) chat=\(chat.id, privacy: .private(mask: .hash)) code=\(LarkPeekDiagnostics.errorKind(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
            statusMessage = "加载更早消息失败：\(error.localizedDescription)"
        }
    }

    public func showPreviewFixture() {
        diagnosticTriggerID = "fixture"
        resetMessagePagination()
        let conversation = HoveredConversation(
            name: "产品体验群",
            rowFrame: CGRect(x: 280, y: 220, width: 420, height: 62),
            rowTexts: ["产品体验群", "14:20", "林澈", "新的悬停预览已经可以体验了"]
        )
        let chat = LarkChat(id: "oc_preview", name: "产品体验群", kind: .group)
        let now = Date()
        let fixtureImageData = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAGCAIAAABxZ0isAAAAK0lEQVR42mNQa/kPRDVWb4HojcdMIPo9yQaIGHBKYApBlOKWwBSCKMUpAQAyLlKZwbl2DQAAAABJRU5ErkJggg=="
        )!
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
            LarkMessage(id: "om_preview_5", chatID: chat.id, type: "share_chat", createTime: now.addingTimeInterval(-45), sender: MessageSender(name: "Lark Peek"), content: "分享了一个群聊", sharedChatID: "oc_preview_shared", sharedChatName: "产品设计交流群"),
            LarkMessage(
                id: "om_preview_image",
                chatID: chat.id,
                createTime: now.addingTimeInterval(-15),
                sender: MessageSender(name: "Lark Peek"),
                content: "点击图片查看大图\n![Image](img_preview_fixture)",
                images: [
                    MessageImage(
                        key: "img_preview_fixture",
                        data: fixtureImageData,
                        attempted: true
                    )
                ]
            )
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
        removeAllCachedImages()
        await verifyAndPrewarm()
    }

    private func configureClient() {
        let selected = defaults.string(forKey: "selectedLarkCLIPath").map(URL.init(fileURLWithPath:))
        do {
            let resolved = try LarkCLIClient(executableURL: selected, workingDirectory: workingDirectory)
            client = resolved
            cliPath = resolved.cliURL.path
            statusMessage = "只读预览已就绪"
            LarkPeekDiagnostics.lifecycle.notice(
                "event=cli_configured source=\(selected == nil ? "discovered" : "selected", privacy: .public) path=\(resolved.cliURL.path, privacy: .private(mask: .hash))"
            )
        } catch {
            client = nil
            cliPath = nil
            authStatus = AuthStatus(state: .error(error.localizedDescription))
            statusMessage = error.localizedDescription
            LarkPeekDiagnostics.lifecycle.error(
                "event=cli_configuration_failed source=\(selected == nil ? "discovered" : "selected", privacy: .public) code=\(LarkPeekDiagnostics.errorKind(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private func verifyAndPrewarm() async {
        guard let client else { return }
        authStatus = AuthStatus(state: .checking)
        statusMessage = "正在检查 lark-cli 登录状态…"
        LarkPeekDiagnostics.lifecycle.info("event=prewarm_started")
        do {
            let auth = try await client.run(.authStatus)
            authStatus = try LarkCLIParser.authStatus(from: auth.data)
            guard authStatus.state == .ready else {
                let count = authStatus.missingRequiredScopes.count
                LarkPeekDiagnostics.lifecycle.notice(
                    "event=auth_not_ready state=\(self.authStatus.state.diagnosticCode, privacy: .public) missingScopes=\(count)"
                )
                statusMessage = count == AuthStatus.requiredScopes.count
                    ? "需要授权飞书只读访问"
                    : "还缺少 \(count) 项飞书只读权限"
                return
            }
            statusMessage = "正在缓存最近会话索引…"
            try await loadFirstChatPage(using: client)
            statusMessage = "只读预览已就绪 · 已索引最近 \(recentChats.count) 个会话"
            LarkPeekDiagnostics.lifecycle.notice(
                "event=prewarm_succeeded chats=\(self.recentChats.count)"
            )
        } catch {
            authStatus = AuthStatus(state: .error(error.localizedDescription))
            statusMessage = error.localizedDescription
            LarkPeekDiagnostics.lifecycle.error(
                "event=prewarm_failed code=\(LarkPeekDiagnostics.errorKind(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
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
        let hydratedMessages = await downloadImages(in: namedMessages, using: client)
        try Task.checkCancellation()
        guard case let .messages(_, visibleChat, _, _) = state,
              visibleChat.id == chat.id else { return }
        state = .messages(conversation, chat, hydratedMessages, Date())
        peekModelLogger.info(
            "event=initial_messages_succeeded trigger=\(LarkPeekDiagnostics.triggerID ?? "none", privacy: .public) chat=\(chat.id, privacy: .private(mask: .hash)) count=\(messages.count) hasMore=\(page.nextPageToken != nil)"
        )
    }

    private func findThread(
        for hint: ThreadRowHint,
        using client: LarkCLIClient
    ) async throws -> ThreadSearchHit? {
        let trigger = LarkPeekDiagnostics.triggerID ?? diagnosticTriggerID ?? "none"
        try Task.checkCancellation()
        if hint.searchQuery.count >= 6 {
            let result = try await client.run(.searchMessages(query: hint.searchQuery, pageSize: 10))
            let hits = try LarkCLIParser.threadSearchHits(from: result.data)
            if let matched = ThreadSearchMatcher.bestHit(for: hint, in: hits) {
                threadMatchLogger.info(
                    "event=root_query_matched trigger=\(trigger, privacy: .public) query=\(hint.searchQuery, privacy: .private(mask: .hash)) hits=\(hits.count)"
                )
                return usingKnownChat(for: matched)
            }
            threadMatchLogger.info(
                "event=root_query_inconclusive trigger=\(trigger, privacy: .public) query=\(hint.searchQuery, privacy: .private(mask: .hash)) hits=\(hits.count)"
            )
        }

        guard let replyQuery = hint.replySearchQuery,
              let bounds = activityDateBounds(for: hint.activityMarker) else { return nil }
        let replyResult = try await client.run(.searchMessages(
            query: replyQuery,
            start: bounds.start,
            end: bounds.end,
            pageSize: 50
        ))
        let replyHits = try LarkCLIParser.threadSearchHits(from: replyResult.data)
        let replyCandidates = matchingReplyHits(for: hint, in: replyHits)
        threadMatchLogger.info(
            "event=reply_fallback_checked trigger=\(trigger, privacy: .public) query=\(replyQuery, privacy: .private(mask: .hash)) hits=\(replyHits.count) candidates=\(replyCandidates.count)"
        )
        if replyCandidates.count == 1, let replyHit = replyCandidates.first {
            return syntheticRootHit(for: hint, from: replyHit, createTime: bounds.date)
        }

        let candidateChatIDs = Array(Set(replyCandidates.map(\.chat.id))).sorted()
        guard !candidateChatIDs.isEmpty else { return nil }
        let rootResult = try await client.run(.searchMessages(
            query: hint.searchQuery,
            chatIDs: candidateChatIDs,
            start: bounds.start,
            end: bounds.end,
            pageSize: 50
        ))
        let narrowedHits = try LarkCLIParser.threadSearchHits(from: rootResult.data)
        let exactRoots = narrowedHits.filter { hit in
            ConversationText.normalize(hit.rootMessage.sender.name) == ConversationText.normalize(hint.rootSender)
                && ConversationText.normalize(hit.rootMessage.content) == ConversationText.normalize(hint.rootExcerpt)
        }
        guard exactRoots.count == 1, let matched = exactRoots.first else {
            threadMatchLogger.info(
                "event=short_root_ambiguous trigger=\(trigger, privacy: .public) chats=\(candidateChatIDs.count) hits=\(narrowedHits.count) exact=\(exactRoots.count)"
            )
            return nil
        }
        threadMatchLogger.info(
            "event=short_root_matched trigger=\(trigger, privacy: .public) chats=\(candidateChatIDs.count)"
        )
        return usingKnownChat(for: matched)
    }

    private func usingKnownChat(for hit: ThreadSearchHit) -> ThreadSearchHit {
        var matched = hit
        if let knownChat = recentChats.first(where: { $0.id == matched.chat.id }) {
            matched = ThreadSearchHit(rootMessage: matched.rootMessage, chat: knownChat)
        }
        return matched
    }

    private func matchingReplyHits(
        for hint: ThreadRowHint,
        in hits: [ThreadSearchHit]
    ) -> [ThreadSearchHit] {
        guard let replyQuery = hint.replySearchQuery else { return [] }
        let query = ConversationText.normalize(replyQuery)
        let expectedSender = hint.latestReplySender.map(ConversationText.normalize)
        var byThreadID: [String: ThreadSearchHit] = [:]
        for hit in hits {
            guard let threadID = hit.rootMessage.threadID,
                  ConversationText.normalize(hit.rootMessage.content).contains(query) else { continue }
            if let expectedSender,
               ConversationText.normalize(hit.rootMessage.sender.name) != expectedSender { continue }
            byThreadID[threadID] = hit
        }
        return Array(byThreadID.values)
    }

    private func syntheticRootHit(
        for hint: ThreadRowHint,
        from replyHit: ThreadSearchHit,
        createTime: Date
    ) -> ThreadSearchHit {
        let threadID = replyHit.rootMessage.threadID ?? ""
        let root = LarkMessage(
            id: "thread-root-\(threadID)",
            chatID: replyHit.chat.id,
            createTime: createTime,
            sender: MessageSender(name: hint.rootSender),
            content: hint.rootExcerpt,
            threadID: threadID
        )
        return usingKnownChat(for: ThreadSearchHit(rootMessage: root, chat: replyHit.chat))
    }

    private func activityDateBounds(for marker: String, now: Date = Date()) -> (date: Date, start: String, end: String)? {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: now)
        let date: Date?
        switch marker {
        case "昨天": date = calendar.date(byAdding: .day, value: -1, to: today)
        case "前天": date = calendar.date(byAdding: .day, value: -2, to: today)
        default:
            if marker.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil {
                date = today
            } else {
                let parts = marker
                    .replacingOccurrences(of: "日", with: "")
                    .split(separator: "月")
                    .compactMap { Int($0) }
                guard parts.count == 2 else { return nil }
                var components = calendar.dateComponents([.year], from: now)
                components.month = parts[0]
                components.day = parts[1]
                guard var candidate = calendar.date(from: components) else { return nil }
                if candidate > (calendar.date(byAdding: .day, value: 1, to: today) ?? now),
                   let previousYear = calendar.date(byAdding: .year, value: -1, to: candidate) {
                    candidate = previousYear
                }
                date = calendar.startOfDay(for: candidate)
            }
        }
        guard let date, let endDate = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .autoupdatingCurrent
        return (date, formatter.string(from: date), formatter.string(from: endDate))
    }

    private func loadThread(
        root: LarkMessage,
        chat: LarkChat,
        conversation: HoveredConversation,
        using client: LarkCLIClient
    ) async throws {
        let trigger = LarkPeekDiagnostics.triggerID ?? diagnosticTriggerID ?? "none"
        guard let threadID = root.threadID else { throw LarkCLIError.malformedResponse }
        resetMessagePagination()
        var root = root
        root.threadRepliesLoaded = false
        state = .messages(conversation, chat, [root], Date())

        let result = try await client.run(.threadMessages(threadID: threadID, pageSize: 50))
        let page = try LarkCLIParser.messagePage(from: result.data, fallbackChatID: chat.id)
        try Task.checkCancellation()
        root.threadReplies = page.messages.sorted(by: LarkMessage.isChronologicallyBefore)
        root.threadRepliesLoaded = true
        root.threadHasMore = page.nextPageToken != nil
        state = .messages(conversation, chat, [root], Date())

        let hydrated = await downloadImages(in: [root], using: client)
        try Task.checkCancellation()
        guard case let .messages(_, visibleChat, _, _) = state,
              visibleChat.id == chat.id else { return }
        state = .messages(conversation, chat, hydrated, Date())
        threadMatchLogger.info(
            "event=thread_loaded trigger=\(trigger, privacy: .public) chat=\(chat.id, privacy: .private(mask: .hash)) replies=\(root.threadReplies.count) hasMore=\(page.nextPageToken != nil)"
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

    public func loadThreadReplies(for messageID: String) async {
        guard case let .messages(_, _, messages, _) = state,
              let root = messages.first(where: { $0.id == messageID }),
              root.isThreadRoot,
              let threadID = root.threadID,
              !root.threadRepliesLoaded else { return }

        if let existing = threadReplyTasks[threadID] {
            await existing.task.value
            return
        }

        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.threadReplyTasks[threadID]?.id == taskID {
                    self.threadReplyTasks[threadID] = nil
                }
            }
            await self.performThreadReplyLoad(threadID: threadID, chatID: root.chatID)
        }
        threadReplyTasks[threadID] = ThreadReplyTask(id: taskID, task: task)
        await task.value
    }

    public func cancelTransientRequests() {
        let tasks = threadReplyTasks.values.map(\.task)
        threadReplyTasks.removeAll()
        for task in tasks { task.cancel() }
    }

    private func performThreadReplyLoad(threadID: String, chatID: String) async {
        let trigger = LarkPeekDiagnostics.triggerID ?? diagnosticTriggerID ?? "none"
        await acquireThreadReplyRequestSlot()
        defer { releaseThreadReplyRequestSlot() }
        do {
            try Task.checkCancellation()
            let client = try requireClient()
            let result = try await client.run(.threadMessages(threadID: threadID, pageSize: 50))
            let page = try LarkCLIParser.messagePage(from: result.data, fallbackChatID: chatID)
            try Task.checkCancellation()
            guard case let .messages(conversation, chat, currentMessages, _) = state,
                  chat.id == chatID else { return }

            let replies = page.messages.sorted(by: LarkMessage.isChronologicallyBefore)
            let updatedMessages = currentMessages.map { current -> LarkMessage in
                guard current.isThreadRoot, current.threadID == threadID else { return current }
                var current = current
                current.threadReplies = replies
                current.threadRepliesLoaded = true
                current.threadHasMore = page.nextPageToken != nil
                return current
            }
            state = .messages(conversation, chat, updatedMessages, Date())

            let hydratedMessages = await downloadImages(in: updatedMessages, using: client)
            try Task.checkCancellation()
            guard case let .messages(_, visibleChat, visibleMessages, _) = state,
                  visibleChat.id == chatID else { return }
            state = .messages(
                conversation,
                chat,
                MessageTimeline.merging(hydratedMessages, into: visibleMessages),
                Date()
            )
            threadMatchLogger.info(
                "event=lazy_thread_loaded trigger=\(trigger, privacy: .public) chat=\(chatID, privacy: .private(mask: .hash)) replies=\(replies.count) hasMore=\(page.nextPageToken != nil)"
            )
        } catch is CancellationError {
            threadMatchLogger.info(
                "event=lazy_thread_cancelled trigger=\(trigger, privacy: .public) chat=\(chatID, privacy: .private(mask: .hash))"
            )
        } catch {
            threadMatchLogger.error(
                "event=lazy_thread_failed trigger=\(trigger, privacy: .public) chat=\(chatID, privacy: .private(mask: .hash)) code=\(LarkPeekDiagnostics.errorKind(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private func acquireThreadReplyRequestSlot() async {
        if activeThreadReplyRequestCount < 3 {
            activeThreadReplyRequestCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            pendingThreadReplyRequests.append(continuation)
        }
    }

    private func releaseThreadReplyRequestSlot() {
        if pendingThreadReplyRequests.isEmpty {
            activeThreadReplyRequestCount -= 1
        } else {
            pendingThreadReplyRequests.removeFirst().resume()
        }
    }

    private func downloadImages(in messages: [LarkMessage], using client: LarkCLIClient) async -> [LarkMessage] {
        let chatID = messages.first?.chatID
        var hydratedMessages = applyingImageCache(to: messages)
        if hydratedMessages != messages, let chatID {
            publishImageProgress(hydratedMessages, forChatID: chatID)
        }

        // The timeline opens at the bottom, so prioritize the newest visible
        // messages instead of making the initial viewport wait for old images.
        let allMessages = hydratedMessages.reversed().flatMap { message in
            [message] + message.threadReplies.reversed()
        }
        var seenRequests = Set<ImageRequest>()
        let requests = allMessages.flatMap { message in
            message.images.compactMap { image -> ImageRequest? in
                guard image.data == nil, !image.attempted else { return nil }
                let request = ImageRequest(messageID: message.id, key: image.key)
                return seenRequests.insert(request).inserted ? request : nil
            }
        }
        guard !requests.isEmpty else { return hydratedMessages }

        let workingDirectory = self.workingDirectory
        await withTaskGroup(of: (ImageRequest, ImageDownload).self) { group in
            var nextRequestIndex = 0

            while nextRequestIndex < min(3, requests.count) {
                let request = requests[nextRequestIndex]
                nextRequestIndex += 1
                group.addTask {
                    let data = await Self.downloadImage(
                        request,
                        using: client,
                        workingDirectory: workingDirectory
                    )
                    return (request, ImageDownload(data: data))
                }
            }

            while let (request, download) = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                if let data = download.data {
                    cacheImage(data, for: request)
                }
                hydratedMessages = applying([request: download], to: hydratedMessages)
                if let chatID {
                    publishImageProgress(hydratedMessages, forChatID: chatID)
                }

                if nextRequestIndex < requests.count {
                    let request = requests[nextRequestIndex]
                    nextRequestIndex += 1
                    group.addTask {
                        let data = await Self.downloadImage(
                            request,
                            using: client,
                            workingDirectory: workingDirectory
                        )
                        return (request, ImageDownload(data: data))
                    }
                }
            }
        }

        return hydratedMessages
    }

    private func applying(
        _ downloaded: [ImageRequest: ImageDownload],
        to messages: [LarkMessage]
    ) -> [LarkMessage] {
        return messages.map { message in
            var message = message
            message = applying(downloaded, to: message)
            message.threadReplies = message.threadReplies.map { applying(downloaded, to: $0) }
            return message
        }
    }

    private func applyingImageCache(to messages: [LarkMessage]) -> [LarkMessage] {
        messages.map { message in
            var message = applyingImageCache(to: message)
            message.threadReplies = message.threadReplies.map { applyingImageCache(to: $0) }
            return message
        }
    }

    private func applyingImageCache(to message: LarkMessage) -> LarkMessage {
        var message = message
        message.images = message.images.map { image in
            guard image.data == nil,
                  let data = imageCache[ImageRequest(messageID: message.id, key: image.key)]
            else { return image }
            return MessageImage(key: image.key, data: data, attempted: true)
        }
        return message
    }

    private func publishImageProgress(_ messages: [LarkMessage], forChatID chatID: String) {
        guard case let .messages(conversation, chat, _, _) = state,
              chat.id == chatID else { return }
        state = .messages(conversation, chat, messages, Date())
    }

    private func cacheImage(_ data: Data, for request: ImageRequest) {
        if let existing = imageCache.updateValue(data, forKey: request) {
            imageCacheBytes -= existing.count
            imageCacheOrder.removeAll { $0 == request }
        }
        imageCacheBytes += data.count
        imageCacheOrder.append(request)

        while imageCacheBytes > Self.maximumImageCacheBytes,
              let oldest = imageCacheOrder.first {
            imageCacheOrder.removeFirst()
            if let removed = imageCache.removeValue(forKey: oldest) {
                imageCacheBytes -= removed.count
            }
        }
    }

    private func removeAllCachedImages() {
        imageCache.removeAll(keepingCapacity: false)
        imageCacheOrder.removeAll(keepingCapacity: false)
        imageCacheBytes = 0
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
                "event=image_download_unavailable trigger=\(LarkPeekDiagnostics.triggerID ?? "none", privacy: .public) message=\(request.messageID, privacy: .private(mask: .hash)) key=\(request.key, privacy: .private(mask: .hash)) code=\(LarkPeekDiagnostics.errorKind(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)"
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

    private func threadMappingKey(for hint: ThreadRowHint) -> String {
        let digest = SHA256.hash(data: Data(hint.stableFingerprint.utf8))
        return "threadMapping." + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func rememberedThread(for hint: ThreadRowHint) -> StoredThreadResolution? {
        guard let data = defaults.data(forKey: threadMappingKey(for: hint)) else { return nil }
        return try? JSONDecoder().decode(StoredThreadResolution.self, from: data)
    }

    private func remember(thread hit: ThreadSearchHit, for hint: ThreadRowHint) {
        guard let threadID = hit.rootMessage.threadID else { return }
        let stored = StoredThreadResolution(
            threadID: threadID,
            rootMessageID: hit.rootMessage.id,
            chat: hit.chat
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: threadMappingKey(for: hint))
    }

    private func forgetThread(for hint: ThreadRowHint) {
        defaults.removeObject(forKey: threadMappingKey(for: hint))
    }
}
