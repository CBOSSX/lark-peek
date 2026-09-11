import Combine
import CryptoKit
import Foundation

private let peekModelLogger = LarkPeekDiagnostics.pagination
private let chatMatchLogger = LarkPeekDiagnostics.chatMatching
private let threadMatchLogger = LarkPeekDiagnostics.threadMatching
private let hoverRouteLogger = LarkPeekDiagnostics.hoverRouting

public enum PeekState: Equatable {
    case waiting
    case loading(HoveredConversation)
    case candidates(HoveredConversation, [LarkChat])
    case threadCandidates(HoveredConversation, [ThreadCandidate], Bool)
    case messages(HoveredConversation, LarkChat, [LarkMessage], Date)
    case error(HoveredConversation?, String)
}

@MainActor
public final class PeekModel: ObservableObject {
    @Published public private(set) var state: PeekState = .waiting
    @Published public private(set) var authStatus = AuthStatus()
    @Published public private(set) var isAuthorizing = false
    @Published public private(set) var cliPath: String?
    @Published public private(set) var statusMessage = "正在准备只读预览…"
    @Published public var isPresentingPreview = false
    public let timeline = TimelineSession()
    public var hasOlderMessages: Bool { timeline.pagination.cursor != nil }
    public var isLoadingOlderMessages: Bool { timeline.pagination.isLoading }
    @Published public private(set) var diagnosticTriggerID: String?
    @Published public private(set) var previewNotice: String?
    @Published public private(set) var isCachedPreview = false
    @Published public private(set) var newerPagination: TimelinePagination = .exhausted
    public var isSearchContext: Bool { searchHit != nil }
    private var newerConsumedTokens: Set<String> = []
    private var contextStart: String?
    private var contextEnd: String?
    private var searchHit: MessageSearchHit?
    public private(set) var readingState = PreviewReadingState()
    private var previewCache: [String: (page: LarkCLIParser.MessagePage, date: Date, reading: PreviewReadingState)] = [:]

    private var client: LarkCLIClient?
    private var recentChats: [LarkChat] = []
    private var nextPageToken: String?
    private var imageCache: [ImageRequest: Data] = [:]
    private var imageCacheOrder: [ImageRequest] = []
    private var imageCacheBytes = 0
    private var activeThreadReplyRequestCount = 0
    private var pendingThreadReplyRequests: [CheckedContinuation<Void, Never>] = []
    private let defaults: UserDefaults
    private let workingDirectory: URL

    private static let maximumImageCacheBytes = 64 * 1_024 * 1_024

    public init(defaults: UserDefaults = .standard, workingDirectory: URL = FileManager.default.temporaryDirectory) {
        self.defaults = defaults
        self.workingDirectory = workingDirectory
        configureClient()
        timeline.onChange = { [weak self] in
            guard let self, let conversation = self.timeline.conversation,
                  let chat = self.timeline.chat else { return }
            self.state = .messages(conversation, chat, self.timeline.messages, Date())
        }
    }

    public func start() async {
        await verifyAndPrewarm()
    }

    public func authorize(openVerificationURL: (URL) -> Bool) async {
        guard let client, !isAuthorizing else { return }
        isAuthorizing = true
        defer { isAuthorizing = false }
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
        saveCachedPreview()
        state = .loading(conversation)
        resetTimeline()
        readingState = PreviewReadingState()
        contextEnd = nil
        searchHit = nil
        previewNotice = nil
        isCachedPreview = false
        await timeline.schedule(key: "initial") { [weak self] in
            await self?.performPeek(conversation)
        }.value
    }

    private func performPeek(_ conversation: HoveredConversation) async {
        let trigger = LarkPeekDiagnostics.triggerID ?? "none"
        diagnosticTriggerID = trigger
        publishState(.loading(conversation))
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

            if conversation.hasThreadAvatar || hint != nil {
                guard let hint else {
                    publishState(.error(conversation, "已识别为话题，但无法读取完整摘要。请在飞书中查看该话题。"))
                    return
                }
                let resolution = try await ThreadResolver(run: { try await client.run($0) }).resolve(hint)
                try timeline.checkCurrentRequest()
                threadMatchLogger.info("event=thread_resolution trigger=\(trigger, privacy: .public) candidates=\(resolution.candidates.count) complete=\(resolution.complete)")
                if let candidate = resolution.automaticCandidate {
                    try await loadThread(root: candidate.root, chat: candidate.chat, conversation: conversation, using: client)
                } else if !resolution.candidates.isEmpty {
                    publishState(.threadCandidates(conversation, resolution.candidates, resolution.complete))
                } else {
                    publishState(.error(conversation, resolution.complete
                        ? "没有找到与这条摘要对应的话题。消息可能已更新，或尚未被搜索收录。"
                        : "话题查询尚未完成，未能在本次查询范围内确认。请在飞书中查看，或稍后重试。"))
                }
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
                publishState(.error(conversation, "没有找到“\(conversation.name)”对应的已加入会话。"))
            case 1:
                try await loadMessages(for: matches[0], conversation: conversation, using: client)
            default:
                publishState(.candidates(conversation, matches))
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
            publishState(.error(conversation, error.localizedDescription))
        }
    }

    public func select(_ chat: LarkChat, for conversation: HoveredConversation) async {
        saveCachedPreview()
        state = .loading(conversation)
        resetTimeline()
        readingState = PreviewReadingState()
        contextEnd = nil
        searchHit = nil
        previewNotice = nil
        isCachedPreview = false
        await timeline.schedule(key: "initial") { [weak self] in
            guard let self else { return }
            self.publishState(.loading(conversation))
            self.remember(chatID: chat.id, for: conversation)
            do {
                try await self.loadMessages(for: chat, conversation: conversation, using: self.requireClient())
            } catch is CancellationError {
                return
            } catch {
                self.publishState(.error(conversation, error.localizedDescription))
            }
        }.value
    }

    private func publishState(_ state: PeekState) {
        if let id = TimelineRequestContext.sessionID, !timeline.isCurrent(id) { return }
        self.state = state
    }

    public func retryCurrent() async {
        if let searchHit {
            await previewSearchHit(searchHit)
            return
        }
        previewCache.removeAll()
        let conversation: HoveredConversation?
        switch state {
        case let .loading(value), let .candidates(value, _), let .threadCandidates(value, _, _), let .messages(value, _, _, _): conversation = value
        case let .error(value, _): conversation = value
        case .waiting: conversation = nil
        }
        guard let conversation else { return }
        await peek(conversation)
    }

    public func dismiss() {
        saveCachedPreview()
        state = .waiting
        cancelTransientRequests()
        resetTimeline()
        diagnosticTriggerID = nil
        state = .waiting
        searchHit = nil
        contextEnd = nil
        previewNotice = nil
        isCachedPreview = false
    }

    public struct PreviewSnapshot {
        fileprivate let conversation: HoveredConversation
        fileprivate let chat: LarkChat
        fileprivate let messages: [LarkMessage]
        fileprivate let pagination: TimelinePagination
        fileprivate let replyErrors: [String: String]
        fileprivate let reading: PreviewReadingState
        fileprivate let notice: String?
        fileprivate let cached: Bool
    }

    public func capturePreview() -> PreviewSnapshot? {
        guard !isSearchContext, let conversation = timeline.conversation, let chat = timeline.chat else { return nil }
        return PreviewSnapshot(conversation: conversation, chat: chat, messages: timeline.messages,
            pagination: timeline.pagination, replyErrors: timeline.replyErrors, reading: readingState,
            notice: previewNotice, cached: isCachedPreview)
    }

    public func restorePreview(_ snapshot: PreviewSnapshot) {
        state = .loading(snapshot.conversation)
        resetTimeline()
        readingState = snapshot.reading
        previewNotice = snapshot.notice
        isCachedPreview = snapshot.cached
        timeline.restore(conversation: snapshot.conversation, chat: snapshot.chat, messages: snapshot.messages,
            pagination: snapshot.pagination, replyErrors: snapshot.replyErrors)
        if let client { scheduleEnrichment(using: client) }
    }

    public func searchMessages(_ command: ReadOnlyCommand) async throws -> MessageSearchPage {
        guard case .searchMessages = command else { throw CommandPolicyError.invalidQuery }
        // Capture known names before awaiting: the user may navigate while search is running.
        var knownChats = Dictionary(recentChats.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        if let chat = timeline.chat { knownChats[chat.id] = chat }
        let result = try await requireClient().run(command)
        return try LarkCLIParser.messageSearchPage(from: result.data, knownChats: knownChats)
    }

    public func previewSearchHit(_ hit: MessageSearchHit) async {
        let sessionID = prepareSearchHit(hit)
        await loadSearchContext(hit, sessionID: sessionID)
    }

    public func prepareSearchHit(_ hit: MessageSearchHit) -> UUID {
        saveCachedPreview()
        let conversation = HoveredConversation(name: hit.chat.name, rowFrame: .zero, rowTexts: [])
        state = .loading(conversation)
        resetTimeline()
        readingState = PreviewReadingState()
        searchHit = hit
        contextEnd = ISO8601DateFormatter().string(from: hit.message.createTime.addingTimeInterval(1))
            .replacingOccurrences(of: "Z", with: "+00:00")
        contextStart = ISO8601DateFormatter().string(from: hit.message.createTime)
            .replacingOccurrences(of: "Z", with: "+00:00")
        readingState.position = TimelineReadingPosition(messageID: hit.message.id, screenY: 100, isAtBottom: false)
        previewNotice = "搜索命中及前后消息"
        isCachedPreview = false
        return timeline.id
    }

    public func loadSearchContext(_ hit: MessageSearchHit, sessionID: UUID) async {
        guard timeline.isCurrent(sessionID), searchHit?.id == hit.id,
              case let .loading(conversation) = state else { return }
        await timeline.schedule(key: "initial") { [weak self] in
            guard let self else { return }
            let sessionID = self.timeline.id
            do {
                let client = try self.requireClient()
                // Keep the loading page until both sides are ready, then transition once.
                let before = try await client.run(.recentMessages(chatID: hit.chat.id, pageSize: 20, end: self.contextEnd))
                try self.timeline.checkCurrentRequest()
                let after = try await client.run(.recentMessages(chatID: hit.chat.id, pageSize: 20, start: self.contextStart))
                try self.timeline.checkCurrentRequest()
                let older = try LarkCLIParser.messagePage(from: before.data, fallbackChatID: hit.chat.id)
                let newer = try LarkCLIParser.messagePage(from: after.data, fallbackChatID: hit.chat.id)
                self.newerPagination = newer.nextPageToken.map(TimelinePagination.ready) ?? .exhausted
                self.timeline.install(conversation: conversation, chat: hit.chat,
                    messages: MessageTimeline.merging(older.messages + newer.messages, into: [hit.message]),
                    cursor: older.nextPageToken, sessionID: sessionID)
                self.scheduleEnrichment(using: client)
            } catch {
                guard self.timeline.isCurrent(sessionID), !Task.isCancelled else { return }
                self.previewNotice = "已显示命中消息；上下文加载失败，可刷新重试"
                self.newerPagination = .paused(nil, "上下文未加载，请刷新重试")
                self.timeline.install(conversation: conversation, chat: hit.chat, messages: [hit.message], cursor: nil, sessionID: sessionID)
            }
        }.value
    }

    public func loadNewerMessages(automatic: Bool = false) async {
        await timeline.schedule(key: "newer-page") { [weak self] in
            guard let self, let chat = self.timeline.chat, let start = self.contextStart,
                  let cursor = self.newerPagination.cursor, !self.newerPagination.isLoading,
                  !automatic || self.newerPagination.allowsAutomaticLoading else { return }
            let sessionID = self.timeline.id
            self.newerPagination = .loading(UUID(), cursor)
            do {
                let client = try self.requireClient()
                let result = try await client.run(.recentMessages(chatID: chat.id, pageToken: cursor, pageSize: 20, start: start))
                try self.timeline.checkCurrentRequest()
                let page = try LarkCLIParser.messagePage(from: result.data, fallbackChatID: chat.id)
                self.newerConsumedTokens.insert(cursor)
                if let next = page.nextPageToken {
                    self.newerPagination = self.newerConsumedTokens.contains(next)
                        ? .paused(nil, "分页游标没有前进，请刷新重试") : .ready(next)
                } else {
                    self.newerPagination = .exhausted
                }
                self.timeline.appendMessages(page.messages, sessionID: sessionID)
                self.scheduleEnrichment(using: client)
            } catch {
                guard self.timeline.isCurrent(sessionID), !Task.isCancelled else { return }
                self.newerPagination = .failed(cursor, error.localizedDescription)
            }
        }.value
    }

    public func presentError(_ message: String) {
        cancelTransientRequests()
        resetTimeline()
        publishState(.error(nil, message))
    }

    public func loadOlderMessages(automatic: Bool = false) async {
        await timeline.schedule(key: "older-page") { [weak self] in
            await self?.performOlderPageLoad(automatic: automatic)
        }.value
    }

    private func performOlderPageLoad(automatic: Bool) async {
        let sessionID = timeline.id
        guard let chat = timeline.chat,
              let request = timeline.beginPage(sessionID: sessionID, automatic: automatic) else { return }
        var cursor = request.cursor
        var visited = Set<String>()
        do {
            let client = try requireClient()
            for attempt in 0..<3 {
                try timeline.checkCurrentRequest()
                visited.insert(cursor)
                let result = try await client.run(.recentMessages(chatID: chat.id, pageToken: cursor, pageSize: 20, end: contextEnd))
                try timeline.checkCurrentRequest()
                let page = try LarkCLIParser.messagePage(from: result.data, fallbackChatID: chat.id)
                let knownIDs = Set(timeline.messages.map(\.id))
                let addedCount = Set(page.messages.map(\.id)).subtracting(knownIDs).count
                let nextState: TimelinePagination
                if let next = page.nextPageToken {
                    if visited.contains(next) || timeline.consumedPageTokens.contains(next) {
                        nextState = .paused(nil, "分页游标没有前进，请重新打开预览")
                    } else if addedCount > 0 {
                        nextState = .ready(next)
                    } else if attempt == 2 {
                        nextState = .paused(next, "本次未读到更早消息")
                    } else {
                        nextState = .loading(request.id, next)
                    }
                } else {
                    nextState = .exhausted
                }
                timeline.receivePage(page, requestID: request.id, sessionID: sessionID, nextState: nextState)
                scheduleEnrichment(using: client)
                peekModelLogger.info("event=older_page_received added=\(addedCount) total=\(self.timeline.messages.count) attempt=\(attempt + 1)")
                guard case let .loading(_, next) = nextState else { return }
                cursor = next
            }
        } catch is CancellationError {
            timeline.finishPage(.ready(cursor), requestID: request.id, sessionID: sessionID)
        } catch {
            timeline.finishPage(.failed(cursor, error.localizedDescription), requestID: request.id, sessionID: sessionID)
            peekModelLogger.error("event=older_page_failed code=\(LarkPeekDiagnostics.errorKind(error), privacy: .public)")
        }
    }

    public func showPreviewFixture() {
        readingState = PreviewReadingState()
        diagnosticTriggerID = "fixture"
        resetTimeline()
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
        timeline.install(conversation: conversation, chat: chat, messages: messages, cursor: nil, sessionID: timeline.id)
        statusMessage = "视觉预览模式"
    }

    public func configureCLI(at url: URL?) async {
        dismiss()
        if let url { defaults.set(url.path, forKey: "selectedLarkCLIPath") }
        else { defaults.removeObject(forKey: "selectedLarkCLIPath") }
        configureClient()
        recentChats = []
        nextPageToken = nil
        removeAllCachedImages()
        await verifyAndPrewarm()
    }

    func handleAuthorizationFailure(_ error: LarkCLIError) {
        guard case let .authorization(message, missingScopes) = error else { return }
        // An expired credential invalidates the previously cached scope grant.
        let missing = Set(missingScopes).intersection(AuthStatus.requiredScopes)
        if missing.isEmpty {
            authStatus.scopes = []
        } else {
            authStatus.scopes.subtract(missing)
        }
        authStatus.state = .needsLogin
        previewCache.removeAll()
        statusMessage = "飞书授权已失效或权限不足，请重新授权。" + message
    }

    private func configureClient() {
        previewCache.removeAll()
        let selected = defaults.string(forKey: "selectedLarkCLIPath").map(URL.init(fileURLWithPath:))
        do {
            let resolved = try LarkCLIClient(
                executableURL: selected, workingDirectory: workingDirectory,
                onAuthorizationFailure: { [weak self] error in
                    self?.handleAuthorizationFailure(error)
                }
            )
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
            if let cliError = error as? LarkCLIError, case .authorization = cliError {
                handleAuthorizationFailure(cliError)
            } else {
                authStatus = AuthStatus(state: .error(error.localizedDescription))
                statusMessage = error.localizedDescription
            }
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
        try timeline.checkCurrentRequest()
        let sessionID = timeline.id
        previewCache = previewCache.filter { Date().timeIntervalSince($0.value.date) < 15 }
        let page: LarkCLIParser.MessagePage
        if let cached = previewCache[chat.id] {
            page = cached.page
            readingState = cached.reading
            isCachedPreview = true
        } else {
            let result = try await client.run(.recentMessages(chatID: chat.id, pageSize: 20))
            try timeline.checkCurrentRequest()
            page = try LarkCLIParser.messagePage(from: result.data, fallbackChatID: chat.id)
            if previewCache.count >= 4, let oldest = previewCache.min(by: { $0.value.date < $1.value.date })?.key {
                previewCache[oldest] = nil
            }
            previewCache[chat.id] = (page, Date(), readingState)
        }
        timeline.install(conversation: conversation, chat: chat, messages: page.messages, cursor: page.nextPageToken, sessionID: sessionID)
        scheduleEnrichment(using: client)
    }

    private func saveCachedPreview() {
        guard searchHit == nil, let chat = timeline.chat,
              let cached = previewCache[chat.id], Date().timeIntervalSince(cached.date) < 15,
              !timeline.messages.isEmpty else { return }
        // Preserve loaded history and expansion without retaining another copy of image binaries.
        func withoutImageData(_ value: LarkMessage) -> LarkMessage {
            var message = value
            message.images = message.images.map { MessageImage(key: $0.key) }
            message.threadReplies = message.threadReplies.map(withoutImageData)
            return message
        }
        let page = LarkCLIParser.MessagePage(messages: timeline.messages.map(withoutImageData), nextPageToken: timeline.pagination.cursor)
        previewCache[chat.id] = (page, cached.date, cached.reading)
    }

    public func selectThread(_ candidate: ThreadCandidate, conversation: HoveredConversation) async {
        guard case let .threadCandidates(current, candidates, _) = state,
              current == conversation, candidates.contains(candidate) else { return }
        publishState(.loading(conversation))
        await timeline.schedule(key: "initial") { [weak self] in
            guard let self else { return }
            do {
                let client = try self.requireClient()
                let result = try await client.run(.messageDetails(messageID: candidate.root.id))
                try self.timeline.checkCurrentRequest()
                guard let root = try LarkCLIParser.messages(from: result.data, fallbackChatID: candidate.chat.id)
                    .first(where: { $0.id == candidate.root.id && $0.chatID == candidate.chat.id
                        && $0.threadID == candidate.root.threadID && $0.isThreadRoot && !$0.deleted }) else {
                    throw LarkCLIError.malformedResponse
                }
                try await self.loadThread(root: root, chat: candidate.chat, conversation: conversation, using: client)
            } catch is CancellationError {
                return
            } catch {
                self.publishState(.error(conversation, error.localizedDescription))
            }
        }.value
    }

    private func loadThread(
        root: LarkMessage,
        chat: LarkChat,
        conversation: HoveredConversation,
        using client: LarkCLIClient
    ) async throws {
        try timeline.checkCurrentRequest()
        let sessionID = timeline.id
        guard let threadID = root.threadID else { throw LarkCLIError.malformedResponse }
        var root = root
        if root.threadRepliesLoaded {
            timeline.install(conversation: conversation, chat: chat, messages: [root], cursor: nil, sessionID: sessionID)
            scheduleEnrichment(using: client)
            return
        }
        let result = try await client.run(.threadMessages(threadID: threadID, pageSize: 50))
        try timeline.checkCurrentRequest()
        let page = try LarkCLIParser.messagePage(from: result.data, fallbackChatID: chat.id)
        root.threadReplies = page.messages.sorted(by: LarkMessage.isChronologicallyBefore)
        root.threadRepliesLoaded = true
        root.threadHasMore = page.nextPageToken != nil
        timeline.install(conversation: conversation, chat: chat, messages: [root], cursor: nil, sessionID: sessionID)
        scheduleEnrichment(using: client)
    }

    private func resetTimeline() {
        searchHit = nil
        contextEnd = nil
        contextStart = nil
        newerPagination = .exhausted
        newerConsumedTokens = []
        timeline.reset()
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
        guard let root = timeline.messages.first(where: { $0.id == messageID }),
              root.isThreadRoot, let threadID = root.threadID, !root.threadRepliesLoaded else { return }
        await timeline.schedule(key: "thread:" + threadID) { [weak self] in
            await self?.performThreadReplyLoad(threadID: threadID)
        }.value
    }

    public func cancelTransientRequests() {
        timeline.invalidateRequests()
    }

    /// Freeze the displayed snapshot during the close animation, but invalidate all writers now.
    public func invalidatePreviewRequests() {
        timeline.invalidateRequests()
    }

    private func performThreadReplyLoad(threadID: String) async {
        let sessionID = timeline.id
        timeline.beginReplies(threadID: threadID, sessionID: sessionID)
        await acquireThreadReplyRequestSlot()
        defer { releaseThreadReplyRequestSlot() }
        do {
            try timeline.checkCurrentRequest()
            let client = try requireClient()
            let result = try await client.run(.threadMessages(threadID: threadID, pageSize: 50))
            try timeline.checkCurrentRequest()
            let page = try LarkCLIParser.messagePage(from: result.data, fallbackChatID: timeline.chat?.id ?? "")
            timeline.applyReplies(page.messages, threadID: threadID, hasMore: page.nextPageToken != nil, sessionID: sessionID)
            scheduleEnrichment(using: client)
        } catch is CancellationError {
            return
        } catch {
            timeline.failReplies(threadID: threadID, error: error.localizedDescription, sessionID: sessionID)
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

    private func scheduleEnrichment(using client: LarkCLIClient) {
        timeline.schedule(key: "names") { [weak self] in
            guard let self else { return }
            let sessionID = self.timeline.id
            var attempted = Set<String>()
            while self.timeline.isCurrent(sessionID), !Task.isCancelled {
                let unresolved = self.timeline.messages.flatMap { [$0] + $0.threadReplies }.filter {
                    guard let id = $0.sharedChatID else { return false }
                    return $0.sharedChatName == nil && !attempted.contains(id)
                }
                guard !unresolved.isEmpty else { return }
                attempted.formUnion(unresolved.compactMap(\.sharedChatID))
                let resolved = await self.resolveSharedChatNames(in: unresolved, using: client)
                guard self.timeline.isCurrent(sessionID), !Task.isCancelled else { return }
                let names = resolved.reduce(into: [String: String]()) { result, message in
                    if let id = message.sharedChatID, let name = message.sharedChatName { result[id] = name }
                }
                self.timeline.applyNames(names, sessionID: sessionID)
            }
        }
        // One resource worker per session caps all overlapping page/reply downloads at three.
        timeline.schedule(key: "images") { [weak self] in
            await self?.hydrateImages(using: client)
        }
    }

    private func hydrateImages(using client: LarkCLIClient) async {
        let sessionID = timeline.id
        while timeline.isCurrent(sessionID), !Task.isCancelled {
            let allMessages = timeline.messages.reversed().flatMap { [$0] + $0.threadReplies.reversed() }
            var seen = Set<ImageRequest>()
            let pending = allMessages.flatMap { message in
                message.images.compactMap { image -> ImageRequest? in
                    guard image.data == nil, !image.attempted else { return nil }
                    let request = ImageRequest(messageID: message.id, key: image.key)
                    return seen.insert(request).inserted ? request : nil
                }
            }
            guard !pending.isEmpty else { return }
            let batch = Array(pending.prefix(3))
            let workingDirectory = self.workingDirectory
            await withTaskGroup(of: (ImageRequest, ImageDownload).self) { group in
                for request in batch {
                    if let cached = imageCache[request] {
                        timeline.applyImage(messageID: request.messageID, key: request.key, data: cached, sessionID: sessionID)
                    } else {
                        group.addTask {
                            let data = await Self.downloadImage(request, using: client, workingDirectory: workingDirectory)
                            return (request, ImageDownload(data: data))
                        }
                    }
                }
                while let (request, result) = await group.next() {
                    guard timeline.isCurrent(sessionID), !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    if let data = result.data { cacheImage(data, for: request) }
                    timeline.applyImage(messageID: request.messageID, key: request.key, data: result.data, sessionID: sessionID)
                }
            }
        }
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

}
