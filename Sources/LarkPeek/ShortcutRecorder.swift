import AppKit
import LarkPeekCore
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: PeekShortcut
    let title: String
    let onRecord: (PeekShortcut) -> Bool

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.shortcut = shortcut
        button.onRecord = onRecord
        button.setAccessibilityLabel("\(title)快捷键")
        button.refreshTitle()
    }
}

@MainActor
final class ShortcutRecorderButton: NSButton {
    var shortcut = PeekShortcut.preview
    var onRecord: ((PeekShortcut) -> Bool)?
    private(set) var isRecording = false

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        target = self
        action = #selector(beginRecording)
        toolTip = "点击后按下快捷键，Esc 取消"
        setAccessibilityHelp("点击后按下组合键，按 Escape 取消录入。")
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    @objc func beginRecording() {
        window?.makeFirstResponder(self)
        isRecording.toggle()
        refreshTitle()
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        refreshTitle()
        return super.resignFirstResponder()
    }

    func refreshTitle() {
        title = isRecording ? "请按下快捷键…" : shortcut.label
        setAccessibilityValue(title)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        let modifiers = PeekShortcut.modifierLabel(event.modifierFlags)
        title = modifiers.isEmpty ? "请按下快捷键…" : modifiers + "…"
    }

    // Capture Command combinations before the app menu handles them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        guard !event.isARepeat else { return }
        if event.keyCode == 53 {
            isRecording = false
            refreshTitle()
            return
        }
        if event.keyCode == 48, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            isRecording = false
            refreshTitle()
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
            return
        }
        let candidate = PeekShortcut(keyCode: event.keyCode, modifiers: event.modifierFlags)
        if onRecord?(candidate) == true {
            shortcut = candidate
            isRecording = false
        }
        refreshTitle()
    }
}
