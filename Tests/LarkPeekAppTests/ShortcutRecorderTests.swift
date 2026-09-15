import AppKit
import LarkPeekCore
import Testing
@testable import LarkPeek

@MainActor
struct ShortcutRecorderTests {
    private func event(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code
        ))
    }

    @Test func recordsCommandCombinationsBeforeMenuActions() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        let recorder = ShortcutRecorderButton()
        window.contentView = recorder
        var captured: PeekShortcut?
        recorder.onRecord = { captured = $0; return $0.isValid }
        recorder.beginRecording()
        #expect(recorder.performKeyEquivalent(with: try event(35, flags: [.command, .shift])))
        #expect(captured == PeekShortcut(keyCode: 35, modifiers: [.command, .shift]))
        #expect(!recorder.isRecording)
        #expect(recorder.title == "⇧⌘P")
    }

    @Test func rejectedInputKeepsRecordingAndEscapePreservesOriginal() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        let recorder = ShortcutRecorderButton()
        window.contentView = recorder
        recorder.onRecord = { _ in false }
        recorder.beginRecording()
        recorder.keyDown(with: try event(3, flags: [.control, .option]))
        #expect(recorder.isRecording)
        #expect(recorder.shortcut == .preview)
        recorder.keyDown(with: try event(53))
        #expect(!recorder.isRecording)
        #expect(recorder.title == "⌃⌥P")
    }

    @Test func recordedShortcutsSupportSingleModifiersAndNormalizeCapsLock() {
        let shortcut = PeekShortcut(keyCode: 50, modifiers: [.control, .capsLock])
        #expect(shortcut.isValid)
        #expect(shortcut.label == "⌃`")
        #expect(shortcut.matches(keyCode: 50, modifiers: .control))
        #expect(!PeekShortcut(keyCode: 0, modifiers: .shift).isValid)
        #expect(PeekShortcut(keyCode: 18, modifiers: [.option, .shift]).isValid)
    }
}
