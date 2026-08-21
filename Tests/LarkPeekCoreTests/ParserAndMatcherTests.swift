import Foundation
import Testing
@testable import LarkPeekCore

@Test func parsesChatPageAndPagination() throws {
    let json = #"{"ok":true,"data":{"chats":[{"chat_id":"oc_1","name":"产品群","chat_mode":"group"},{"chat_id":"oc_2","name":"林澈","chat_mode":"p2p","external":true}],"has_more":true,"page_token":"next-page"}}"#
    let page = try LarkCLIParser.chatPage(from: Data(json.utf8))

    #expect(page.chats.map(\.id) == ["oc_1", "oc_2"])
    #expect(page.chats[1].kind == .p2p)
    #expect(page.chats[1].external)
    #expect(page.nextPageToken == "next-page")
}

@Test func parsesMessagesAndOrdersSameMinuteByPosition() throws {
    let json = #"{"ok":true,"data":{"messages":[{"message_id":"om_new","chat_id":"oc_1","msg_type":"text","create_time":"2026-08-19 14:32","message_position":"185","sender":{"name":"B"},"content":"{\"text\":\"new\"}"},{"message_id":"om_old","chat_id":"oc_1","msg_type":"text","create_time":"2026-08-19 14:32","message_position":"184","sender":{"name":"A"},"content":"{\"text\":\"old\"}"}],"has_more":true,"page_token":"older-page"}}"#
    let page = try LarkCLIParser.messagePage(from: Data(json.utf8), fallbackChatID: "oc_1")
    let messages = page.messages
        .sorted(by: LarkMessage.isChronologicallyBefore)

    #expect(page.nextPageToken == "older-page")
    #expect(messages.map(\.id) == ["om_old", "om_new"])
    #expect(messages.map(\.content) == ["old", "new"])
}

@Test func messageTimelineMergesOlderPagesWithoutDuplicates() {
    let sender = MessageSender(name: "A")
    let current = [
        LarkMessage(id: "om_2", chatID: "oc_1", createTime: Date(timeIntervalSince1970: 2), sender: sender, content: "2"),
        LarkMessage(id: "om_3", chatID: "oc_1", createTime: Date(timeIntervalSince1970: 3), sender: sender, content: "3")
    ]
    let older = [
        LarkMessage(id: "om_1", chatID: "oc_1", createTime: Date(timeIntervalSince1970: 1), sender: sender, content: "1"),
        current[0]
    ]

    #expect(MessageTimeline.merging(older, into: current).map(\.id) == ["om_1", "om_2", "om_3"])
}

@Test func rendersResourcePlaceholdersWithoutDownloading() throws {
    let json = #"{"ok":true,"data":{"messages":[{"message_id":"om_image","msg_type":"image","create_time":"1786400000000","sender":{"name":"A"},"content":"{\"image_key\":\"img_safe\"}"},{"message_id":"om_marker","msg_type":"text","create_time":"1786400000001","sender":{"name":"A"},"content":"[Image: img_v3_from_cli]"},{"message_id":"om_file","msg_type":"file","create_time":"1786400000002","sender":{"name":"A"},"content":"{\"file_name\":\"plan.pdf\"}"}]}}"#
    let messages = try LarkCLIParser.messages(from: Data(json.utf8), fallbackChatID: "oc_1")

    #expect(messages[0].content == "![Image](img_safe)")
    #expect(messages[0].images.map(\.key) == ["img_safe"])
    #expect(messages[1].content == "![Image](img_v3_from_cli)")
    #expect(messages[1].images.map(\.key) == ["img_v3_from_cli"])
    #expect(messages[2].content == "附件：plan.pdf")
}

@Test func keepsInlineImagesInMessageOrderAndRejectsTheImgKeyLabel() throws {
    let content = """
    <card title="产品更新">
    第一段
    🖼️ Image(img_key:img_v3_first)
    中间说明
    Image(img_key:img_v3_second)
    最后一段
    </card>
    """
    let contentData = try JSONEncoder().encode(content)
    let encodedContent = try #require(String(data: contentData, encoding: .utf8))
    let json = #"{"ok":true,"data":{"messages":[{"message_id":"om_card_images","msg_type":"interactive","content":\#(encodedContent)}]}}"#
    let message = try #require(LarkCLIParser.messages(from: Data(json.utf8), fallbackChatID: "oc_1").first)

    #expect(message.images.map(\.key) == ["img_v3_first", "img_v3_second"])
    #expect(!message.images.map(\.key).contains("img_key"))
    #expect(MessageMarkdown.contentParts(from: message.content, imageKeys: message.images.map(\.key)) == [
        .text("**产品更新**\n第一段"),
        .image(key: "img_v3_first"),
        .text("中间说明"),
        .image(key: "img_v3_second"),
        .text("最后一段")
    ])
}

@Test func appendsOnlyImagesWithoutAnInlinePositionAsFallback() {
    #expect(MessageMarkdown.contentParts(
        from: "开头\n![Image](img_inline)\n结尾",
        imageKeys: ["img_inline", "img_unpositioned"]
    ) == [
        .text("开头"),
        .image(key: "img_inline"),
        .text("结尾"),
        .image(key: "img_unpositioned")
    ])
}

@Test func keepsStructuredCardImagesBetweenTheirNeighboringTextBlocks() throws {
    let json = #"{"ok":true,"data":{"messages":[{"message_id":"om_structured_card","msg_type":"interactive","content":"{\"elements\":[{\"tag\":\"div\",\"text\":{\"content\":\"图片之前\"}},{\"tag\":\"img\",\"image_key\":\"img_v3_middle\"},{\"tag\":\"div\",\"text\":{\"content\":\"图片之后\"}}]}"}]}}"#
    let message = try #require(LarkCLIParser.messages(from: Data(json.utf8), fallbackChatID: "oc_1").first)

    #expect(MessageMarkdown.contentParts(from: message.content, imageKeys: message.images.map(\.key)) == [
        .text("图片之前"),
        .image(key: "img_v3_middle"),
        .text("图片之后")
    ])
}

@Test func extractsInteractiveCardTextAndSharedChatMetadata() throws {
    let json = #"{"ok":true,"data":{"messages":[{"message_id":"om_card","msg_type":"interactive","content":"{\"header\":{\"title\":{\"tag\":\"plain_text\",\"content\":\"审批提醒\"}},\"elements\":[{\"tag\":\"div\",\"text\":{\"tag\":\"lark_md\",\"content\":\"**请尽快处理**\"}}]}"},{"message_id":"om_chat","msg_type":"share_chat","content":"[Chat card: oc_shared_123]"}]}}"#
    let messages = try LarkCLIParser.messages(from: Data(json.utf8), fallbackChatID: "oc_1")

    #expect(messages[0].content == "审批提醒\n**请尽快处理**")
    #expect(messages[1].sharedChatID == "oc_shared_123")
}

@Test func parsesMergedForwardIntoStructuredMessages() throws {
    let forwarded = """
    <forwarded_messages>
    [2026-08-20T17:13:43+08:00] 何俊骞:
        神了
    [2026-08-20T17:18:36+08:00] 曹博淳:
        用完了吗
        无敌啊
    </forwarded_messages>
    """
    let contentData = try JSONEncoder().encode(forwarded)
    let encodedContent = try #require(String(data: contentData, encoding: .utf8))
    let json = #"{"ok":true,"data":{"messages":[{"message_id":"om_forward","msg_type":"merge_forward","content":\#(encodedContent)}]}}"#
    let message = try #require(LarkCLIParser.messages(from: Data(json.utf8), fallbackChatID: "oc_1").first)

    #expect(message.content == "合并转发 · 2 条消息")
    #expect(message.forwardedMessages.map(\.senderName) == ["何俊骞", "曹博淳"])
    #expect(message.forwardedMessages.map(\.content) == ["神了", "用完了吗\n无敌啊"])
    #expect(message.forwardedMessages.allSatisfy { $0.createTime != nil })
}

@Test func parsesThreadMetadataAndReplies() throws {
    let rootJSON = #"{"ok":true,"data":{"messages":[{"message_id":"om_root","chat_id":"oc_1","msg_type":"text","thread_id":"omt_topic","content":"测试一下话题。"}]}}"#
    let replyJSON = #"{"ok":true,"data":{"messages":[{"message_id":"om_reply","chat_id":"oc_1","msg_type":"text","thread_id":"omt_topic","thread_message_position":"0","sender":{"name":"曹博淳"},"content":"hi 你好"}],"has_more":false}}"#

    let root = try #require(LarkCLIParser.messages(from: Data(rootJSON.utf8), fallbackChatID: "oc_1").first)
    let replies = try LarkCLIParser.messagePage(from: Data(replyJSON.utf8), fallbackChatID: "oc_1")

    #expect(root.threadID == "omt_topic")
    #expect(replies.messages.map(\.content) == ["hi 你好"])
    #expect(replies.nextPageToken == nil)
}

@Test func parsesThreadSearchHitsWithChatContext() throws {
    let json = #"{"ok":true,"data":{"messages":[{"message_id":"om_root","chat_id":"oc_group","chat_name":"业务侧需求沟通","chat_type":"group","msg_type":"text","thread_id":"omt_topic","sender":{"name":"曹沙沙"},"content":"辛苦大家更新下各业务线开发进展"}]}}"#

    let hits = try LarkCLIParser.threadSearchHits(from: Data(json.utf8))

    #expect(hits.count == 1)
    #expect(hits[0].rootMessage.threadID == "omt_topic")
    #expect(hits[0].chat.id == "oc_group")
    #expect(hits[0].chat.name == "业务侧需求沟通")
}

@Test func removesCardMarkupAndMentionIDs() throws {
    let json = #"{"ok":true,"data":{"messages":[{"message_id":"om_xml_card","msg_type":"interactive","content":"<card title=\"文档内容变更提醒\">\n@王淼 (ou_572cbf21d8d54a4bc69de598df27f44e) 编辑了文档 [来啦！](https://example.com)\n[查看变更详情](https://example.com/detail) [取消关注]\n</card>"}]}}"#
    let message = try #require(LarkCLIParser.messages(from: Data(json.utf8), fallbackChatID: "oc_1").first)

    #expect(message.content == "**文档内容变更提醒**\n@王淼 编辑了文档 [来啦！](https://example.com)\n[查看变更详情](https://example.com/detail) [取消关注]")
    #expect(!message.content.contains("<card"))
    #expect(!message.content.contains("ou_"))
}

@Test func parsesSharedChatDetails() throws {
    let json = #"{"ok":true,"data":{"name":"真实群名","description":"群描述","chat_mode":"group","external":false}}"#
    let chat = try LarkCLIParser.chatDetails(from: Data(json.utf8), chatID: "oc_shared")
    #expect(chat.name == "真实群名")
    #expect(chat.id == "oc_shared")
}

@Test func parsesDownloadedResourcePath() throws {
    let json = #"{"ok":true,"data":{"saved_path":"lark-peek-image-safe.png","size_bytes":42}}"#
    #expect(try LarkCLIParser.downloadedResourcePath(from: Data(json.utf8)) == "lark-peek-image-safe.png")
}

@Test func rendersMessageMarkdownAndPreservesWhitespace() throws {
    let markdown = "**重点**\n[文档](https://example.com) 和 `代码`"
    let rendered = MessageMarkdown.attributedString(from: markdown)

    #expect(String(rendered.characters) == "重点\n文档 和 代码")

    let runs = Array(rendered.runs)
    #expect(runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    #expect(runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    #expect(runs.contains { $0.link?.absoluteString == "https://example.com" })
}

@Test func rendersHTMLParagraphsAsReadableText() {
    let rendered = MessageMarkdown.attributedString(from: "<p>第一段</p><p>第二段<br>下一行 &amp; 更多</p>")
    #expect(String(rendered.characters) == "第一段\n\n第二段\n下一行 & 更多")
}

@Test func parsesMarkdownListsQuotesHeadingsAndCodeBlocks() {
    let markdown = "- 测试 md\n- hhh\n  - 111\n1. aaa\n> 急急急\n>> 积极\n# 标题\n```\nlet x = 1\n```"
    let blocks = MessageMarkdown.blocks(from: markdown)

    #expect(blocks.map(\.kind) == [
        .unordered(level: 0), .unordered(level: 0), .unordered(level: 1),
        .ordered(number: 1, level: 0), .quote(level: 0), .quote(level: 1),
        .heading(level: 1), .code
    ])
    #expect(blocks.map(\.content) == [
        "测试 md", "hhh", "111", "aaa", "急急急", "积极", "标题", "let x = 1"
    ])
}

@Test func chatMatcherPrefersNormalizedExactNames() {
    let chats = [
        LarkChat(id: "oc_exact", name: "Botmux 交流群", kind: .group),
        LarkChat(id: "oc_prefix", name: "Botmux 交流群二群", kind: .group)
    ]
    #expect(ChatMatcher.matches(name: " Botmux　交流群 ", in: chats).map(\.id) == ["oc_exact"])
}

@Test func chatMatcherReturnsDuplicatesForExplicitChoice() {
    let chats = [
        LarkChat(id: "oc_1", name: "产品群", kind: .group),
        LarkChat(id: "oc_2", name: "产品群", kind: .group)
    ]
    #expect(ChatMatcher.matches(name: "产品群", in: chats).count == 2)
}

@Test func chatMatcherDoesNotLetAnEarlierFuzzyGroupHideALaterExactP2P() {
    let fuzzyGroup = LarkChat(id: "oc_group", name: "白卿, 曹博淳, 高俊辉", kind: .group)
    let exactP2P = LarkChat(id: "oc_p2p", name: "白卿", kind: .p2p)

    #expect(ChatMatcher.exactMatches(name: "白卿", in: [fuzzyGroup]).isEmpty)
    #expect(ChatMatcher.fuzzyMatches(name: "白卿", in: [fuzzyGroup]).map(\.id) == ["oc_group"])
    #expect(ChatMatcher.matches(name: "白卿", in: [fuzzyGroup, exactP2P]).map(\.id) == ["oc_p2p"])
}

@Test func conversationNameHeuristicSkipsUnreadCountsBadgesAndTimes() {
    let texts = ["432", "公开", "14:20", "Botmux 交流群", "刘兆庆", ":", "最新消息"]
    #expect(ConversationNameHeuristics.chooseName(fromOrderedTexts: texts) == "Botmux 交流群")
}

@Test func standaloneThreadRowProducesStableRootHintWhenLatestReplyChanges() throws {
    let root = "曹沙沙: @王志鹏 @夏元瑞 辛苦大家 3:30 日会前，更新下各业务线开发进展、风险、问题[比心]-[链接]双日会"
    let first = HoveredConversation(
        name: root,
        rowFrame: .zero,
        rowTexts: ["2", root + " 14:12 田阁良 : CC @韦理静 换成你了哈"]
    )
    let second = HoveredConversation(
        name: root,
        rowFrame: .zero,
        rowTexts: ["5", root + " 15:30 夏元瑞: 今天的风险已经更新"]
    )

    let firstHint = try #require(first.threadHint)
    let secondHint = try #require(second.threadHint)
    #expect(firstHint.rootSender == "曹沙沙")
    #expect(firstHint.latestReplySender == "田阁良")
    #expect(firstHint.searchQuery == "更新下各业务线开发进展")
    #expect(firstHint.stableFingerprint == secondHint.stableFingerprint)
    #expect(first.fingerprint != second.fingerprint)
}

@Test func compactStandaloneThreadWithoutReplySenderIsRecognized() throws {
    let conversation = HoveredConversation(
        name: "曹博淳: 测试一下话题。",
        rowFrame: .zero,
        rowTexts: ["曹博淳: 测试一下话题。 11:49 对的对的"]
    )

    let hint = try #require(conversation.threadHint)
    #expect(hint.rootSender == "曹博淳")
    #expect(hint.rootExcerpt == "测试一下话题。")
    #expect(hint.latestReplySender == nil)
    #expect(hint.latestReplyExcerpt == "对的对的")
    #expect(hint.searchQuery == "测试一下话题")
}

@Test func splitAccessibilityNodesForStandaloneThreadsAreRecognized() throws {
    let compact = HoveredConversation(
        name: "曹博淳: 测试一下话题。",
        rowFrame: .zero,
        rowTexts: ["曹博淳: 测试一下话题。", "11:49", "对的对的"]
    )
    let long = HoveredConversation(
        name: "曹沙沙: @王志鹏 辛苦大家 3:30 日会前，更新下各业务线开发进展、风险、问题",
        rowFrame: .zero,
        rowTexts: [
            "2",
            "曹沙沙: @王志鹏 辛苦大家 3:30 日会前，更新下各业务线开发进展、风险、问题",
            "14:12",
            "田阁良 :",
            "CC @韦理静 换成你了哈"
        ]
    )

    let compactHint = try #require(compact.threadHint)
    let longHint = try #require(long.threadHint)
    #expect(compactHint.rootSender == "曹博淳")
    #expect(compactHint.latestReplySender == nil)
    #expect(compactHint.latestReplyExcerpt == "对的对的")
    #expect(longHint.rootSender == "曹沙沙")
    #expect(longHint.latestReplySender == "田阁良")
    #expect(longHint.searchQuery == "更新下各业务线开发进展")
}

@Test func standaloneThreadQueryIgnoresLongRichLinkTitle() throws {
    let text = "曹沙沙: @王志鹏 @夏元瑞 辛苦大家 3:30 日会前，更新下各业务线开发进展、风险、问题[比心][比心]-[链接]豆包团队订阅 & 企业订阅 跨业务线双日会 14:12 田阁良 : CC @韦理静 换成你了哈"

    let hint = try #require(ThreadRowHeuristics.hint(from: [text]))

    #expect(hint.searchQuery == "更新下各业务线开发进展")
}

@Test func veryShortAndMergedForwardTopicRowsStillProduceFallbackHints() throws {
    let short = try #require(ThreadRowHeuristics.hint(from: [
        "曹博淳: 6", "8月17日", "超过 30 天没来看看了，助理休眠啦，正在唤醒中……预计 1-2 分钟整装完毕满血复活，请稍候"
    ]))
    let mergedForward = try #require(ThreadRowHeuristics.hint(from: [
        "管娟娟: [会话记录]", "7月15日", "曹博淳", ":", "@沈泽楠 还有个想请教下的，就是这个需求之前，豆包文档会打开调get_summary_cache这个接口吗？"
    ]))

    #expect(short.searchQuery == "6")
    #expect(short.activityMarker == "8月17日")
    #expect((short.replySearchQuery?.count ?? 0) >= 6)
    #expect(mergedForward.searchQuery == "[会话记录]")
    #expect(mergedForward.latestReplySender == "曹博淳")
    #expect(mergedForward.replySearchQuery != nil)
}

@Test func ordinaryChatRowsAreNotClassifiedAsStandaloneThreads() {
    let group = HoveredConversation(
        name: "Aime 内测交流6群",
        rowFrame: .zero,
        rowTexts: ["272", "Aime 内测交流6群", "公开", "14:07 王欣 : 陈依扬的话题"]
    )
    let flattenedGroup = HoveredConversation(
        name: "CM 查日志专用群",
        rowFrame: .zero,
        rowTexts: ["173", "CM 查日志专用群 14:26 QEE Oncall 助手 : 请选择业务线请选择查询时间"]
    )

    #expect(group.threadHint == nil)
    #expect(flattenedGroup.threadHint == nil)
}

@Test func threadSearchMatcherRequiresOneHighConfidenceThread() throws {
    let hint = try #require(ThreadRowHeuristics.hint(from: [
        "曹沙沙: 辛苦大家更新下各业务线开发进展 14:12 田阁良: 已更新"
    ]))
    let matching = ThreadSearchHit(
        rootMessage: LarkMessage(
            id: "om_root",
            chatID: "oc_group",
            createTime: .now,
            sender: MessageSender(name: "曹沙沙"),
            content: "辛苦大家更新下各业务线开发进展",
            threadID: "omt_topic"
        ),
        chat: LarkChat(id: "oc_group", name: "业务群", kind: .group)
    )
    let noThread = ThreadSearchHit(
        rootMessage: LarkMessage(
            id: "om_plain",
            chatID: "oc_group",
            createTime: .now,
            sender: MessageSender(name: "曹沙沙"),
            content: "辛苦大家更新下各业务线开发进展"
        ),
        chat: matching.chat
    )

    #expect(ThreadSearchMatcher.bestHit(for: hint, in: [noThread, matching])?.rootMessage.id == "om_root")
    #expect(ThreadSearchMatcher.bestHit(for: hint, in: [matching, matching]) == nil)
}

@Test func larkApplicationIdentityAcceptsElectronHelperProcesses() {
    #expect(LarkApplicationIdentity.matches(bundleIdentifier: "com.electron.lark"))
    #expect(LarkApplicationIdentity.matches(bundleIdentifier: "com.electron.lark.helper"))
    #expect(LarkApplicationIdentity.matches(bundleIdentifier: "com.electron.lark.helper.renderer"))
    #expect(LarkApplicationIdentity.matches(bundleIdentifier: "com.larksuite.suite.helper"))
    #expect(!LarkApplicationIdentity.matches(bundleIdentifier: "com.electron.larkish"))
    #expect(!LarkApplicationIdentity.matches(bundleIdentifier: "io.github.cbossx.larkpeek"))
    #expect(!LarkApplicationIdentity.matches(bundleIdentifier: nil))
}

@Test @MainActor func previewFixtureProducesMessagesWithoutCLI() throws {
    let suite = "LarkPeekFixtureTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = PeekModel(defaults: defaults)
    model.showPreviewFixture()
    guard case let .messages(_, chat, messages, _) = model.state else {
        Issue.record("Expected preview messages")
        return
    }
    #expect(chat.name == "产品体验群")
    #expect(messages.count == 5)
    #expect(messages[2].forwardedMessages.count == 3)
    #expect(messages[3].threadReplies.count == 2)
}
