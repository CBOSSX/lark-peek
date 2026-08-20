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
    let json = #"{"ok":true,"data":{"messages":[{"message_id":"om_image","msg_type":"image","create_time":"1786400000000","sender":{"name":"A"},"content":"{\"image_key\":\"img_safe\"}"},{"message_id":"om_file","msg_type":"file","create_time":"1786400000001","sender":{"name":"A"},"content":"{\"file_name\":\"plan.pdf\"}"}]}}"#
    let messages = try LarkCLIParser.messages(from: Data(json.utf8), fallbackChatID: "oc_1")

    #expect(messages[0].content == "[图片]")
    #expect(messages[1].content == "附件：plan.pdf")
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

@Test func conversationNameHeuristicSkipsUnreadCountsBadgesAndTimes() {
    let texts = ["432", "公开", "14:20", "Botmux 交流群", "刘兆庆", ":", "最新消息"]
    #expect(ConversationNameHeuristics.chooseName(fromOrderedTexts: texts) == "Botmux 交流群")
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
    #expect(messages.count == 3)
}
