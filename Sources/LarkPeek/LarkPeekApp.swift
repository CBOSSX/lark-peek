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
    private var authorizationTask: Task<Void, Never>?
    private var optionHoldTask: Task<Void, Never>?
    private var isOptionHeld = false
    private var isOptionPeekActive = false
    private var activeTriggerID: String?

    static func main() {
        let application = NSApplication.shared
        let delegate = LarkPeekApp()
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        LarkPeekDiagnostics.lifecycle.notice(
            "event=app_launch version=\(self.appVersion, privacy: .public) build=\(self.appBuild, privacy: .public) os=\(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public) arch=\(self.architecture, privacy: .public) accessibility=\(self.hoverResolver.isAccessibilityTrusted)"
        )
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
        LarkPeekDiagnostics.lifecycle.notice("event=app_terminate")
        peekTask?.cancel()
        authorizationTask?.cancel()
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
        if model.authStatus.state == .needsLogin {
            menu.addItem(NSMenuItem(title: "授权飞书只读访问…", action: #selector(authorizeLark), keyEquivalent: ""))
        }
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
        LarkPeekDiagnostics.input.notice(
            "event=monitors_installed globalKey=\(globalKeys != nil) localKey=\(localKeys != nil) globalModifiers=\(globalModifiers != nil) localModifiers=\(localModifiers != nil) globalClicks=\(globalClicks != nil) retained=\(self.monitors.count)"
        )
    }

    private func handleKey(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        if event.keyCode == 53, panelController.isVisible {
            if panelController.dismissPresentedImage() { return }
            closePeek(reason: "escape")
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.keyCode == 35, flags.contains([.control, .option]) else { return }
        activatePeek(source: "control_option_p", showResolutionErrors: true)
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
            LarkPeekDiagnostics.input.debug(
                "event=option_hold_started keyCode=\(event.keyCode)"
            )
            optionHoldTask?.cancel()
            optionHoldTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let self, self.isOptionHeld else { return }
                self.optionHoldTask = nil
                self.isOptionPeekActive = true
                self.activatePeek(source: "option_hold", showResolutionErrors: false)
            }
            return
        }

        isOptionHeld = false
        optionHoldTask?.cancel()
        optionHoldTask = nil
        if isOptionPeekActive {
            isOptionPeekActive = false
            closePeek(reason: "option_release")
        }
    }

    private func activatePeek(source: String, showResolutionErrors: Bool) {
        let triggerID = LarkPeekDiagnostics.makeTriggerID()
        LarkPeekDiagnostics.input.notice(
            "event=preview_trigger trigger=\(triggerID, privacy: .public) source=\(source, privacy: .public) showErrors=\(showResolutionErrors)"
        )
        do {
            let conversation = try hoverResolver.resolveCurrentConversation(triggerID: triggerID)
            peekTask?.cancel()
            activeTriggerID = triggerID
            panelController.show(anchor: conversation.rowFrame, triggerID: triggerID)
            peekTask = Task { [weak self] in
                await LarkPeekDiagnostics.$triggerID.withValue(triggerID) {
                    await self?.model.peek(conversation)
                }
            }
        } catch HoverResolverError.accessibilityPermissionMissing {
            LarkPeekDiagnostics.input.error(
                "event=preview_aborted trigger=\(triggerID, privacy: .public) source=\(source, privacy: .public) code=permission_missing feedback=\(showResolutionErrors)"
            )
            guard showResolutionErrors else { return }
            _ = hoverResolver.requestAccessibilityPermission()
            panelController.showError(
                "需要辅助功能权限",
                detail: "授权后不需要重启飞书。把鼠标停在会话行上，长按 ⌥，或按 ⌃⌥P。",
                anchor: cursorAnchor(),
                triggerID: triggerID
            )
        } catch {
            LarkPeekDiagnostics.input.error(
                "event=preview_aborted trigger=\(triggerID, privacy: .public) source=\(source, privacy: .public) code=\(LarkPeekDiagnostics.errorKind(error), privacy: .public) feedback=\(showResolutionErrors)"
            )
            guard showResolutionErrors else { return }
            panelController.showError(
                "无法识别会话",
                detail: error.localizedDescription,
                anchor: cursorAnchor(),
                triggerID: triggerID
            )
        }
    }

    private func closePeek(reason: String) {
        optionHoldTask?.cancel()
        optionHoldTask = nil
        isOptionPeekActive = false
        peekTask?.cancel()
        // The controller dismisses the model after the fly-out animation finishes.
        panelController.close(triggerID: activeTriggerID, reason: reason)
        activeTriggerID = nil
    }

    private func closeIfClickIsOutside(at point: CGPoint) {
        guard panelController.isVisible else { return }
        if !panelController.contains(point) { closePeek(reason: "outside_click") }
    }

    @objc private func requestAccessibility() {
        NSApp.activate(ignoringOtherApps: true)
        LarkPeekDiagnostics.accessibility.notice(
            "event=permission_menu_clicked trusted=\(self.hoverResolver.isAccessibilityTrusted)"
        )

        if hoverResolver.isAccessibilityTrusted {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "辅助功能权限已开启"
            alert.informativeText = "Lark Peek 已获准读取鼠标下方的飞书会话信息。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "尚未开启辅助功能权限"
        alert.informativeText = "请在“系统设置 → 隐私与安全性 → 辅助功能”中开启 Lark Peek。如果列表里已有旧副本，请移除后重新添加当前应用。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ), NSWorkspace.shared.open(settingsURL) else {
            LarkPeekDiagnostics.accessibility.error("event=settings_open_failed pane=accessibility")
            let failureAlert = NSAlert()
            failureAlert.alertStyle = .warning
            failureAlert.messageText = "无法自动打开系统设置"
            failureAlert.informativeText = "请手动进入“系统设置 → 隐私与安全性 → 辅助功能”。"
            failureAlert.addButton(withTitle: "好")
            failureAlert.runModal()
            return
        }
        LarkPeekDiagnostics.accessibility.notice("event=settings_opened pane=accessibility")
    }

    @objc private func selectCLI() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "选择 lark-cli"
        panel.message = "请选择文件名为 lark-cli 的可执行文件。"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        // Homebrew installs lark-cli as a symlink to run.js. Preserve the
        // selected link so validation sees the expected executable name.
        panel.resolvesAliases = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.configureCLI(at: url) }
    }

    @objc private func authorizeLark() {
        authorizationTask?.cancel()
        authorizationTask = Task { [weak self] in
            guard let self else { return }
            await self.model.authorize { NSWorkspace.shared.open($0) }
            self.authorizationTask = nil
        }
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

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
    }

    private var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
