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
    #expect(model.timeline.messages.map(\.id) == ["om_previous", "om_match", "om_after"])
    await model.loadOlderMessages()
    #expect(model.timeline.messages.map(\.id) == ["om_older", "om_previous", "om_match", "om_after"])
    await model.loadNewerMessages()
    #expect(model.timeline.messages.map(\.id) == ["om_older", "om_previous", "om_match", "om_after", "om_latest"])
    #expect(model.newerPagination == .exhausted)
    #expect(model.readingState.position?.messageID == "om_match")
    await model.retryCurrent()
    let commands = try String(contentsOf: fixture.commands, encoding: .utf8).split(separator: "\n")
    #expect(commands.count == 6)
    #expect(commands.filter { $0.contains("--order desc") }.allSatisfy { $0.contains("--end 2023-11-14T22:13:21+00:00") })
    #expect(commands.filter { $0.contains("--order asc") }.allSatisfy { $0.contains("--start 2023-11-14T22:13:20+00:00") })
    #expect(commands[2].contains("--page-token next"))
    #expect(model.timeline.messages.contains { $0.id == "om_match" })
}

@Test @MainActor func newerContextRetriesFailuresStopsCursorCyclesAndResetsOnExit() async throws {
    let fixture = try ContextFixture()
    defer { fixture.remove() }
    let model = PeekModel(defaults: fixture.defaults, workingDirectory: fixture.directory)
    let hit = try #require(try await model.searchMessages(.searchMessages(query: "match")).hits.first)
    await model.previewSearchHit(hit)
    let olderState = model.timeline.pagination
    let fail = fixture.directory.appendingPathComponent("fail-newer")
    try Data().write(to: fail)
    await model.loadNewerMessages()
    guard case .failed = model.newerPagination else { Issue.record("Expected retryable newer failure"); return }
    #expect(model.timeline.pagination == olderState)
    try FileManager.default.removeItem(at: fail)
    try Data().write(to: fixture.directory.appendingPathComponent("cycle-newer"))
    await model.loadNewerMessages()
    #expect(model.newerPagination.cursor == nil)
    guard case .paused = model.newerPagination else { Issue.record("Expected cyclic cursor to stop"); return }
    #expect(model.timeline.messages.filter { $0.id == "om_match" }.count == 1)
    #expect(model.timeline.pagination == olderState)
    model.dismiss()
    #expect(!model.isSearchContext && model.newerPagination == .exhausted)
}

@Test @MainActor func aPreparedContextCannotLoadAfterAnotherNavigation() async throws {
    let fixture = try ContextFixture()
    defer { fixture.remove() }
    let model = PeekModel(defaults: fixture.defaults, workingDirectory: fixture.directory)
    let page = try await model.searchMessages(.searchMessages(query: "match"))
    let hit = try #require(page.hits.first)
    let session = model.prepareSearchHit(hit)
    guard case .loading = model.state else { Issue.record("Preparation must synchronously enter loading"); return }
    model.dismiss()
    await model.loadSearchContext(hit, sessionID: session)
    #expect(model.state == .waiting)
    #expect(!FileManager.default.fileExists(atPath: fixture.commands.path))
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
    // Refresh fetches the initial page and automatically fills its short batch again.
    #expect(try String(contentsOf: fixture.commands, encoding: .utf8).split(separator: "\n").count == 4)
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
              *" --page-token later "*)
                if [ -f '\(directory.path)/fail-newer' ]; then exit 1; fi
                if [ -f '\(directory.path)/cycle-newer' ]; then
                  printf '%s' '{"ok":true,"data":{"messages":[],"has_more":true,"page_token":"later"}}'
                  exit 0
                fi
                printf '%s' '{"ok":true,"data":{"messages":[{"message_id":"om_latest","create_time":"1700000200000","content":"latest"}],"has_more":false}}'
                ;;
              *" --order asc "*)
                printf '%s' '{"ok":true,"data":{"messages":[{"message_id":"om_match","create_time":"1700000000000","content":"match"},{"message_id":"om_after","create_time":"1700000100000","content":"after"}],"has_more":true,"page_token":"later"}}'
                ;;
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
