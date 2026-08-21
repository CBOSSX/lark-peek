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
    #expect(throws: (any Error).self) { try ReadOnlyCommand.threadMessages(threadID: "omt_safe\n--yes").arguments() }
    #expect(throws: (any Error).self) {
        try ReadOnlyCommand.messageImage(messageID: "om_safe", fileKey: "img_safe", outputPath: "../escape").arguments()
    }
}

@Test func allowedCommandsContainNoServerMutationOrGenericAPIEntrypoint() throws {
    let commands: [ReadOnlyCommand] = [
        .authStatus,
        .recentChats(),
        .recentChats(pageToken: "next"),
        .searchChats(query: "产品群"),
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
