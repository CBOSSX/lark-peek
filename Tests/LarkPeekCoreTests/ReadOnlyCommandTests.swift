import Testing
@testable import LarkPeekCore

@Test func completeCommandSurfaceIsSmallAndAuditable() throws {
    #expect(try ReadOnlyCommand.authStatus.arguments() == ["auth", "status", "--json", "--verify"])
    #expect(try ReadOnlyCommand.recentChats().arguments() == [
        "im", "+chat-list", "--as", "user", "--types", "p2p,group", "--sort", "active_time", "--page-size", "100", "--format", "json"
    ])
    #expect(try ReadOnlyCommand.searchChats(query: "产品群").arguments() == [
        "im", "+chat-search", "--as", "user", "--query", "产品群", "--search-types", "private,public_joined,external", "--page-size", "20", "--format", "json"
    ])
    #expect(try ReadOnlyCommand.searchMessages(query: "更新下各业务线开发进展").arguments() == [
        "im", "+messages-search", "--as", "user", "--query", "更新下各业务线开发进展", "--page-size", "10", "--no-reactions", "--format", "json"
    ])
    #expect(try ReadOnlyCommand.chatDetails(chatID: "oc_safe").arguments() == [
        "im", "chats", "get", "--as", "user", "--chat-id", "oc_safe", "--format", "json"
    ])
    #expect(try ReadOnlyCommand.recentMessages(chatID: "oc_safe").arguments() == [
        "im", "+chat-messages-list", "--as", "user", "--chat-id", "oc_safe", "--order", "desc", "--page-size", "20", "--no-reactions", "--format", "json"
    ])
    #expect(try ReadOnlyCommand.recentMessages(chatID: "oc_safe", pageToken: "older-page").arguments() == [
        "im", "+chat-messages-list", "--as", "user", "--chat-id", "oc_safe", "--order", "desc", "--page-size", "20", "--no-reactions", "--format", "json", "--page-token", "older-page"
    ])
    #expect(try ReadOnlyCommand.threadMessages(threadID: "omt_safe").arguments() == [
        "im", "+threads-messages-list", "--as", "user", "--thread", "omt_safe", "--order", "asc", "--page-size", "50", "--no-reactions", "--format", "json"
    ])
    #expect(try ReadOnlyCommand.messageImage(
        messageID: "om_safe",
        fileKey: "img_safe",
        outputPath: "lark-peek-image-safe"
    ).arguments() == [
        "im", "+messages-resources-download", "--as", "user",
        "--message-id", "om_safe", "--file-key", "img_safe", "--type", "image",
        "--output", "lark-peek-image-safe", "--format", "json"
    ])
}

@Test func untrustedValuesCannotInjectArguments() {
    #expect(throws: (any Error).self) { try ReadOnlyCommand.recentMessages(chatID: "oc_safe;rm").arguments() }
    #expect(throws: (any Error).self) { try ReadOnlyCommand.recentMessages(chatID: "oc_safe", pageToken: "next\n--yes").arguments() }
    #expect(throws: (any Error).self) { try ReadOnlyCommand.recentChats(pageToken: "next\n--yes").arguments() }
    #expect(throws: (any Error).self) { try ReadOnlyCommand.searchChats(query: "").arguments() }
    #expect(throws: (any Error).self) { try ReadOnlyCommand.searchChats(query: String(repeating: "x", count: 65)).arguments() }
    #expect(throws: (any Error).self) { try ReadOnlyCommand.searchMessages(query: "").arguments() }
    #expect(throws: (any Error).self) { try ReadOnlyCommand.searchMessages(query: "安全查询\n--yes").arguments() }
    #expect(throws: (any Error).self) {
        try ReadOnlyCommand.searchMessages(query: "6", start: "2026-08-17 --yes").arguments()
    }
    #expect(throws: (any Error).self) { try ReadOnlyCommand.threadMessages(threadID: "omt_safe\n--yes").arguments() }
    #expect(throws: (any Error).self) {
        try ReadOnlyCommand.messageImage(messageID: "om_safe", fileKey: "img_safe", outputPath: "../escape").arguments()
    }
}

@Test func shortThreadSearchCanBeNarrowedByChatAndDate() throws {
    #expect(try ReadOnlyCommand.searchMessages(
        query: "6",
        chatIDs: ["oc_one", "oc_two"],
        start: "2026-08-17T00:00:00+08:00",
        end: "2026-08-18T00:00:00+08:00",
        pageSize: 50
    ).arguments() == [
        "im", "+messages-search", "--as", "user", "--query", "6",
        "--chat-id", "oc_one,oc_two",
        "--start", "2026-08-17T00:00:00+08:00",
        "--end", "2026-08-18T00:00:00+08:00",
        "--page-size", "50", "--no-reactions", "--format", "json"
    ])
}

@Test func allowedCommandsContainNoServerMutationOrGenericAPIEntrypoint() throws {
    let commands: [ReadOnlyCommand] = [
        .authStatus,
        .recentChats(),
        .recentChats(pageToken: "next"),
        .searchChats(query: "产品群"),
        .searchMessages(query: "更新下各业务线开发进展"),
        .chatDetails(chatID: "oc_safe"),
        .recentMessages(chatID: "oc_safe"),
        .recentMessages(chatID: "oc_safe", pageToken: "older-page"),
        .threadMessages(threadID: "omt_safe"),
        .messageImage(messageID: "om_safe", fileKey: "img_safe", outputPath: "lark-peek-image-safe")
    ]
    let forbidden = [
        "+messages-send", "+messages-reply", "+flag-create", "+feed-shortcut-create",
        "create", "delete", "update", "forward", "urgent", "reactions", "--yes", "api"
    ]
    for arguments in try commands.map({ try $0.arguments() }) {
        let normalized = arguments.map { $0.lowercased() }
        for word in forbidden { #expect(!normalized.contains(word), "Unexpected write capability in \(arguments)") }
    }
}

@Test func keychainFailureExplainsRecoveryWithoutRequestingRelogin() {
    let description = LarkCLIError.keychainAccessBlocked.localizedDescription
    #expect(description.contains("解锁 login 钥匙串"))
    #expect(description.contains("登录数据仍然保留"))
    #expect(!description.contains("重新登录"))
}

@Test func diagnosticCommandNamesNeverContainUserControlledValues() {
    let sensitiveQuery = "内部项目名称"
    let commands: [ReadOnlyCommand] = [
        .authStatus,
        .recentChats(pageToken: "private-page-token"),
        .searchChats(query: sensitiveQuery),
        .searchMessages(query: sensitiveQuery, chatIDs: ["oc_private"]),
        .chatDetails(chatID: "oc_private"),
        .recentMessages(chatID: "oc_private"),
        .threadMessages(threadID: "omt_private"),
        .messageImage(messageID: "om_private", fileKey: "img_private", outputPath: "private-file")
    ]

    #expect(Set(commands.map(\.diagnosticName)) == [
        "auth.status", "im.chat_list", "im.chat_search", "im.message_search",
        "im.chat_details", "im.recent_messages", "im.thread_messages", "im.image_download"
    ])
    #expect(commands.allSatisfy { !$0.diagnosticName.contains(sensitiveQuery) })
    #expect(commands.allSatisfy { !$0.diagnosticName.contains("private") })
}
