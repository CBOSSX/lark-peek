import AppKit
import Combine
import LarkPeekCore

@main
@MainActor
final class LarkPeekApp: NSObject, NSApplicationDelegate {
    private let model = PeekModel()
    private let hoverResolver = HoveredConversationResolver()
    private lazy var panelController = PeekPanelController(model: model)
    private var statusItem: NSStatusItem?
    private var monitors: [Any] = []
    private var subscriptions = Set<AnyCancellable>()
    private var peekTask: Task<Void, Never>?
    private var optionHoldTask: Task<Void, Never>?
    private var isOptionHeld = false
    private var isOptionPeekActive = false

    static func main() {
        let application = NSApplication.shared
        let delegate = LarkPeekApp()
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        installEventMonitors()
        model.$statusMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &subscriptions)

        if ProcessInfo.processInfo.arguments.contains("--preview-fixtures") {
            panelController.showPreviewFixture(anchor: previewAnchor())
        } else {
            if !hoverResolver.isAccessibilityTrusted {
                _ = hoverResolver.requestAccessibilityPermission()
            }
            Task { await model.start() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        peekTask?.cancel()
        optionHoldTask?.cancel()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "eye.circle.fill", accessibilityDescription: "Lark Peek")
        item.button?.toolTip = "Lark Peek · 悬停会话后长按 ⌥，或按 ⌃⌥P"
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let status = NSMenuItem(title: model.statusMessage, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let guide = NSMenuItem(title: "悬停会话后：长按 ⌥，或按 ⌃⌥P", action: nil, keyEquivalent: "")
        guide.isEnabled = false
        menu.addItem(guide)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "检查辅助功能权限…", action: #selector(requestAccessibility), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "选择 lark-cli…", action: #selector(selectCLI), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Lark Peek", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        statusItem?.menu = menu
    }

    private func installEventMonitors() {
        let globalKeys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.handleKey(event) }
        }
        let localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.handleKey(event) }
            return event
        }
        let globalModifiers = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handleModifierFlags(event) }
        }
        let localModifiers = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handleModifierFlags(event) }
            return event
        }
        let globalClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let clickLocation = NSEvent.mouseLocation
            Task { @MainActor in self?.closeIfClickIsOutside(at: clickLocation) }
        }
        if let globalKeys { monitors.append(globalKeys) }
        if let localKeys { monitors.append(localKeys) }
        if let globalModifiers { monitors.append(globalModifiers) }
        if let localModifiers { monitors.append(localModifiers) }
        if let globalClicks { monitors.append(globalClicks) }
    }

    private func handleKey(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        if event.keyCode == 53, panelController.isVisible {
            if panelController.dismissPresentedImage() { return }
            closePeek()
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.keyCode == 35, flags.contains([.control, .option]) else { return }
        activatePeek(showResolutionErrors: true)
    }

    private func handleModifierFlags(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let conflictingModifiers: NSEvent.ModifierFlags = [.control, .command, .shift]
        let optionOnly = flags.contains(.option) && flags.intersection(conflictingModifiers).isEmpty
        let optionKeyCodes: Set<UInt16> = [58, 61]

        if optionOnly {
            // Only an actual left/right Option key-down starts a hold gesture.
            // Releasing another modifier while Option remains down must not start one.
            guard optionKeyCodes.contains(event.keyCode) else { return }
            guard !isOptionHeld else { return }
            isOptionHeld = true
            optionHoldTask?.cancel()
            optionHoldTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let self, self.isOptionHeld else { return }
                self.optionHoldTask = nil
                self.isOptionPeekActive = true
                self.activatePeek(showResolutionErrors: false)
            }
            return
        }

        isOptionHeld = false
        optionHoldTask?.cancel()
        optionHoldTask = nil
        if isOptionPeekActive {
            isOptionPeekActive = false
            closePeek()
        }
    }

    private func activatePeek(showResolutionErrors: Bool) {
        do {
            let conversation = try hoverResolver.resolveCurrentConversation()
            peekTask?.cancel()
            panelController.show(anchor: conversation.rowFrame)
            peekTask = Task { [weak self] in
                await self?.model.peek(conversation)
            }
        } catch HoverResolverError.accessibilityPermissionMissing {
            guard showResolutionErrors else { return }
            _ = hoverResolver.requestAccessibilityPermission()
            panelController.showError(
                "需要辅助功能权限",
                detail: "授权后不需要重启飞书。把鼠标停在会话行上，长按 ⌥，或按 ⌃⌥P。",
                anchor: cursorAnchor()
            )
        } catch {
            guard showResolutionErrors else { return }
            panelController.showError("无法识别会话", detail: error.localizedDescription, anchor: cursorAnchor())
        }
    }

    private func closePeek() {
        optionHoldTask?.cancel()
        optionHoldTask = nil
        isOptionPeekActive = false
        peekTask?.cancel()
        // The controller dismisses the model after the fly-out animation finishes.
        panelController.close()
    }

    private func closeIfClickIsOutside(at point: CGPoint) {
        guard panelController.isVisible else { return }
        if !panelController.contains(point) { closePeek() }
    }

    @objc private func requestAccessibility() {
        _ = hoverResolver.requestAccessibilityPermission()
    }

    @objc private func selectCLI() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "选择 lark-cli"
        panel.message = "请选择文件名为 lark-cli 的可执行文件。"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.configureCLI(at: url) }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func cursorAnchor() -> CGRect {
        let point = CGEvent(source: nil)?.location ?? .zero
        return CGRect(x: point.x, y: point.y, width: 1, height: 1)
    }

    private func previewAnchor() -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 900
        return CGRect(x: 200, y: primaryHeight - 480, width: 420, height: 62)
    }
}
