import AppKit
import Foundation
import Testing
@testable import LarkPeekCore

@MainActor
struct PeekSettingsTests {
    @Test func settingsPersistAndResetWithoutTouchingCLISelection() throws {
        let suite = "PeekSettingsTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/custom/lark-cli", forKey: "selectedLarkCLIPath")
        let settings = PeekSettings(defaults: defaults)
        #expect(settings.indexLimit == 500)
        #expect(settings.holdDelay == 120)
        #expect(settings.optionHoverEnabled)
        settings.indexLimit = 2_000
        settings.holdDelay = 375
        settings.optionHoverEnabled = false
        let custom = PeekShortcut(keyCode: 50, modifiers: [.control, .shift])
        #expect(settings.setShortcut(custom, forSearch: false))
        let reloaded = PeekSettings(defaults: defaults)
        #expect(reloaded.indexLimit == 2_000)
        #expect(reloaded.holdDelay == 375)
        #expect(!reloaded.optionHoverEnabled)
        #expect(reloaded.previewShortcut == custom)
        reloaded.restoreDefaults()
        let restored = PeekSettings(defaults: defaults)
        #expect(restored.indexLimit == 500)
        #expect(restored.previewShortcut == .preview)
        #expect(restored.searchShortcut == .search)
        #expect(restored.optionHoverEnabled)
        #expect(defaults.string(forKey: "selectedLarkCLIPath") == "/custom/lark-cli")
    }

    @Test func invalidPreferencesAndConflictingShortcutsAreRejected() throws {
        let suite = "PeekSettingsTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(-1, forKey: "settings.indexLimit")
        defaults.set(-1, forKey: "settings.holdDelay")
        defaults.set(Data("broken".utf8), forKey: "settings.previewShortcut")
        let settings = PeekSettings(defaults: defaults)
        #expect(settings.indexLimit == 500)
        #expect(settings.holdDelay == 120)
        #expect(!settings.setShortcut(.search, forSearch: false))
        #expect(!settings.setShortcut(PeekShortcut(keyCode: 53, modifiers: []), forSearch: true))
        #expect(settings.previewShortcut == .preview)
        #expect(settings.searchShortcut == .search)
        #expect(PeekShortcut.preview.matches(keyCode: 35, modifiers: [.control, .option, .capsLock]))
        #expect(!PeekShortcut.preview.matches(keyCode: 35, modifiers: [.control, .option, .shift]))
    }

    @Test func conversationLookupUsesChangedIndexLimitWithoutRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IndexFixture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "IndexFixture-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let script = """
        #!/bin/sh
        case " $* " in
          *" +chat-list "*)
            printf 'page\\n' >> '\(directory.path)/requests'
            printf '%s' '{"ok":true,"data":{"chats":[{"chat_id":"oc_other","name":"Other","chat_mode":"group"}],"has_more":true,"page_token":"next"}}'
            ;;
          *" +chat-search "*)
            printf '%s' '{"ok":true,"data":{"chats":[],"has_more":false}}'
            ;;
          *) exit 1 ;;
        esac
        """
        let cli = directory.appendingPathComponent("lark-cli")
        try Data(script.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        defaults.set(cli.path, forKey: "selectedLarkCLIPath")
        let settings = PeekSettings(defaults: defaults)
        settings.indexLimit = 100
        let model = PeekModel(defaults: defaults, workingDirectory: directory, settings: settings)
        let conversation = HoveredConversation(name: "Missing", rowFrame: .zero, rowTexts: ["Missing"])
        await model.peek(conversation)
        let firstCount = try String(contentsOf: directory.appendingPathComponent("requests"), encoding: .utf8).split(separator: "\n").count
        #expect(firstCount == 2) // Initial page plus the existing activity refresh.
        settings.indexLimit = 300
        await model.peek(conversation)
        let total = try String(contentsOf: directory.appendingPathComponent("requests"), encoding: .utf8).split(separator: "\n").count
        #expect(total - firstCount == 3) // Refreshed first page and two older pages.
        model.dismiss()
    }
}
