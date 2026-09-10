import Foundation
import Testing
@testable import LarkPeekCore

@Test func directMessageSearchUsesPartnerAndKnownConversationNames() throws {
    let data = Data(#"{"messages":[{"message_id":"om_partner","chat_id":"oc_partner","chat_type":"p2p","chat_name":"未命名会话","chat_partner":{"name":"  周然  "},"sender":{"name":"我"},"content":"自己发送的消息"},{"message_id":"om_current","chat_id":"oc_current","chat_type":"p2p","chat_name":" ","sender":{"name":"我"},"content":"当前会话"},{"message_id":"om_named","chat_id":"oc_named","chat_type":"p2p","chat_name":"新名字","chat_partner":{"name":"旧名字"},"content":"消息"},{"message_id":"om_missing_kind","chat_id":"oc_current","content":"消息"},{"message_id":"om_unknown","chat_id":"oc_unknown","chat_type":"p2p","sender":{"name":"我"},"content":"消息"}],"has_more":false}"#.utf8)
    let known = ["oc_current": LarkChat(id: "oc_current", name: "林澈", kind: .p2p)]
    let page = try LarkCLIParser.messageSearchPage(from: data, knownChats: known)
    #expect(page.hits.map(\.chat.name) == ["周然", "林澈", "新名字", "林澈", "单聊"])
    #expect(page.hits.allSatisfy { $0.chat.kind == .p2p })
}

@Test func searchParsesOrdinaryMessagesRepliesAndDeletedMessages() throws {
    let data = Data(#"{"ok":true,"data":{"messages":[{"message_id":"om_plain","chat_id":"oc_dm","chat_type":"p2p","chat_name":"Alice","content":"hello","sender":{"name":"Alice"}},{"message_id":"om_reply","chat_id":"oc_group","thread_id":"omt_topic","thread_message_position":"0","content":"reply"},{"message_id":"om_deleted","chat_id":"oc_group","content":"secret","deleted":true},{"message_id":"om_bad","chat_id":"oc_unsafe&x=1","content":"bad"}],"has_more":true,"page_token":"next"}}"#.utf8)
    let page = try LarkCLIParser.messageSearchPage(from: data)
    #expect(page.hits.map(\.id) == ["om_plain", "om_reply", "om_deleted"])
    #expect(page.hits[0].chat.kind == .p2p)
    #expect(!page.hits[1].message.isThreadRoot)
    #expect(page.hits[2].message.content == "这条消息已撤回")
    #expect(page.nextPageToken == "next")
    #expect(throws: (any Error).self) { try LarkCLIParser.messageSearchPage(from: Data(#"{"data":{}}"#.utf8)) }
    #expect(try LarkCLIParser.messageSearchPage(from: Data(#"{"messages":[],"has_more":false,"page_token":"stale"}"#.utf8)).nextPageToken == nil)
}

@Test func contextTimeAndAppLinksCannotInjectArgumentsOrQueryItems() throws {
    let end = "2026-09-07T12:00:00+00:00"
    let arguments = try ReadOnlyCommand.recentMessages(chatID: "oc_safe", pageToken: "next", end: end).arguments()
    #expect(arguments.suffix(4) == ["--end", end, "--page-token", "next"])
    #expect(throws: (any Error).self) { try ReadOnlyCommand.recentMessages(chatID: "oc_safe", end: "--yes").arguments() }
    #expect(LarkAppLink.chat("oc_safe&openId=bad") == nil)
    #expect(LarkAppLink.chat("oc_safe")?.absoluteString == "https://applink.feishu.cn/client/chat/open?openChatId=oc_safe")
}

@Suite(.serialized) @MainActor
struct MessageSearchTests {
    @Test func lateSearchAndClosedWindowCannotPublishResults() async {
        let loader = SearchLoader()
        let model = MessageSearchModel(loader: loader.load)
        model.search("old")
        await loader.waitForCount(1)
        model.search("new", chatID: "oc_scope")
        await loader.waitForCount(2)
        #expect(loader.commands[1] == .searchMessages(query: "new", chatIDs: ["oc_scope"], pageSize: 20))
        loader.finish(1, ids: ["om_new"])
        await settle { !model.isLoading }
        loader.finish(0, ids: ["om_old"])
        await Task.yield()
        #expect(model.hits.map(\.id) == ["om_new"])
        model.search("closing")
        await loader.waitForCount(3)
        model.clear()
        loader.finish(2, ids: ["om_late"])
        await Task.yield()
        #expect(model.hits.isEmpty)
        #expect(!model.isLoading && !model.hasSearched)
    }

    @Test func paginationDeduplicatesRetriesAndStopsCycles() async {
        let loader = SearchLoader()
        let model = MessageSearchModel(loader: loader.load)
        model.search("test")
        await loader.waitForCount(1)
        loader.finish(0, ids: ["om_a"], next: "p2")
        await settle { !model.isLoading }
        model.loadMore()
        model.loadMore()
        await loader.waitForCount(2)
        #expect(loader.commands.count == 2)
        loader.pending[1].resume(throwing: URLError(.notConnectedToInternet))
        await settle { !model.isLoading }
        #expect(model.hits.count == 1 && model.nextPageToken == "p2")
        #expect(model.error != nil)
        model.retry()
        await loader.waitForCount(3)
        loader.finish(2, ids: ["om_a", "om_b"], next: "p2")
        await settle { !model.isLoading }
        #expect(model.hits.map(\.id) == ["om_a", "om_b"])
        #expect(model.nextPageToken == nil && model.error != nil)
    }

    @Test func emptyOrInvalidQueriesNeverReachTheLoader() async {
        let loader = SearchLoader()
        let model = MessageSearchModel(loader: loader.load)
        model.search("   ")
        #expect(!model.hasSearched)
        model.search("hello\n--yes")
        await settle { !model.isLoading }
        #expect(model.error != nil)
        #expect(loader.commands.isEmpty)
    }
}

@MainActor
private final class SearchLoader {
    var commands: [ReadOnlyCommand] = []
    var pending: [CheckedContinuation<MessageSearchPage, any Error>] = []

    func load(_ command: ReadOnlyCommand) async throws -> MessageSearchPage {
        commands.append(command)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func waitForCount(_ count: Int) async { await settle { self.pending.count >= count } }

    func finish(_ index: Int, ids: [String], next: String? = nil) {
        let hits = ids.map { id in
            MessageSearchHit(message: LarkMessage(id: id, chatID: "oc_test", createTime: Date(),
                sender: MessageSender(name: "Alice"), content: id), chat: LarkChat(id: "oc_test", name: "Test", kind: .group))
        }
        pending[index].resume(returning: MessageSearchPage(hits: hits, nextPageToken: next))
    }
}

@MainActor
private func settle(_ condition: () -> Bool) async {
    for _ in 0..<1000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Async operation did not settle")
}
