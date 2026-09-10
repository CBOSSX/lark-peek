import Foundation
import Testing
@testable import LarkPeekCore

@Test @MainActor func searchReusesTheResolvedDirectConversationName() async throws {
    let fixture = try ContextFixture()
    defer { fixture.remove() }
    let model = PeekModel(defaults: fixture.defaults, workingDirectory: fixture.directory)
    await model.peek(HoveredConversation(name: "Test", rowFrame: .zero, rowTexts: ["Test"]))
    let page = try await model.searchMessages(.searchMessages(query: "match", chatIDs: ["oc_test"]))
    #expect(page.hits.first?.chat.name == "Test")
    #expect(page.hits.first?.chat.kind == .p2p)
}

@Test @MainActor func searchContextKeepsItsTimeBoundaryAcrossPaginationAndRefresh() async throws {
    let fixture = try ContextFixture()
    defer { fixture.remove() }
    let model = PeekModel(defaults: fixture.defaults, workingDirectory: fixture.directory)
    let page = try await model.searchMessages(.searchMessages(query: "match"))
    let hit = try #require(page.hits.first)
    await model.previewSearchHit(hit)
    #expect(model.timeline.messages.map(\.id) == ["om_previous", "om_match"])
    await model.loadOlderMessages()
    #expect(model.timeline.messages.map(\.id) == ["om_older", "om_previous", "om_match"])
    await model.retryCurrent()
    let commands = try String(contentsOf: fixture.commands, encoding: .utf8).split(separator: "\n")
    #expect(commands.count == 3)
    #expect(commands.allSatisfy { $0.contains("--end 2023-11-14T22:13:21+00:00") })
    #expect(commands[1].contains("--page-token next"))
    #expect(model.timeline.messages.contains { $0.id == "om_match" })
}

@Test @MainActor func revisitingAChatUsesMemoryButRefreshFetchesNewData() async throws {
    let fixture = try ContextFixture()
    defer { fixture.remove() }
    let model = PeekModel(defaults: fixture.defaults, workingDirectory: fixture.directory)
    let conversation = HoveredConversation(name: "Test", rowFrame: .zero, rowTexts: ["Test"])
    await model.peek(conversation)
    await model.loadOlderMessages()
    let position = TimelineReadingPosition(messageID: "om_older", screenY: -14, isAtBottom: false)
    model.readingState.position = position
    model.readingState.expandedCards = ["om_older": true]
    let reading = model.readingState
    model.dismiss()
    await model.peek(conversation)
    #expect(try String(contentsOf: fixture.commands, encoding: .utf8).split(separator: "\n").count == 2)
    #expect(model.readingState === reading)
    #expect(model.readingState.position == position)
    #expect(model.readingState.expandedCards["om_older"] == true)
    #expect(model.timeline.messages.map(\.id) == ["om_older", "om_previous"])
    #expect(model.isCachedPreview)
    await model.retryCurrent()
    #expect(try String(contentsOf: fixture.commands, encoding: .utf8).split(separator: "\n").count == 3)
    #expect(model.previewNotice == nil)
    #expect(model.readingState !== reading)
}

@MainActor private struct ContextFixture {
    let directory: URL
    let commands: URL
    let defaults: UserDefaults
    let suite: String

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PeekContext-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        commands = directory.appendingPathComponent("commands")
        let cli = directory.appendingPathComponent("lark-cli")
        let script = """
        #!/bin/sh
        case " $* " in
          *" +messages-search "*)
            printf '%s' '{"ok":true,"data":{"messages":[{"message_id":"om_match","chat_id":"oc_test","chat_type":"p2p","create_time":"1700000000000","content":"match"}],"has_more":false}}'
            ;;
          *" +chat-list "*)
            printf '%s' '{"ok":true,"data":{"chats":[{"chat_id":"oc_test","name":"Test","chat_mode":"p2p"}],"has_more":false}}'
            ;;
          *" +chat-messages-list "*)
            printf '%s\\n' "$*" >> '\(commands.path)'
            case " $* " in
              *" --page-token next "*)
                printf '%s' '{"ok":true,"data":{"messages":[{"message_id":"om_older","create_time":"1699999800000","content":"older"}],"has_more":false}}'
                ;;
              *)
                printf '%s' '{"ok":true,"data":{"messages":[{"message_id":"om_previous","create_time":"1699999900000","content":"previous"}],"has_more":true,"page_token":"next"}}'
                ;;
            esac
            ;;
          *) exit 1 ;;
        esac
        """
        try Data(script.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        suite = "PeekContext-\(UUID())"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(cli.path, forKey: "selectedLarkCLIPath")
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
