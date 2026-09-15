import AppKit
import LarkPeekCore
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(settings: PeekSettings, model: PeekModel, onAuthorize: @escaping () -> Void, onCheckAccessibility: @escaping () -> Void, onSelectCLI: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
        )
        window.title = "Lark Peek 设置"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(
            settings: settings, model: model, onAuthorize: onAuthorize, onCheckAccessibility: onCheckAccessibility, onSelectCLI: onSelectCLI
        ))
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: PeekSettings
    @ObservedObject var model: PeekModel
    let onAuthorize: () -> Void
    let onCheckAccessibility: () -> Void
    let onSelectCLI: () -> Void
    @State private var shortcutError: String?
    @State private var delayText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "eye.circle.fill")
                    .font(.system(size: 36)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("让预览更顺手").font(.title2.weight(.semibold))
                    Text("按你的习惯调整 Lark Peek").foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Form {
                Section {
                    Picker("会话查找范围", selection: $settings.indexLimit) {
                        ForEach(PeekSettings.indexLimits, id: \.self) { value in
                            Text("最近 \(value) 个\(value == 500 ? "（默认）" : "")").tag(value)
                        }
                    }
                } header: {
                    Label("会话识别", systemImage: "tray.full")
                } footer: {
                    Text("启动时先加载最近 100 个会话。未找到匹配时，再按需查找到所选范围。范围越大，查找可能越慢；下次查找生效。")
                }
                Section {
                    shortcutRow("固定 / 关闭预览", forSearch: false)
                    shortcutRow("搜索消息", forSearch: true)
                    if let shortcutError {
                        Text(shortcutError).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Label("快捷键", systemImage: "keyboard")
                } footer: {
                    Text("点击快捷键后直接按下新组合，Esc 取消。请包含 ⌃、⌥ 或 ⌘，并避开系统和其他应用的快捷键。")
                }
                Section {
                    Toggle("长按 Option 预览", isOn: $settings.optionHoverEnabled)
                    HStack {
                        Text("触发延迟")
                        Spacer()
                        TextField("120", text: $delayText)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .accessibilityLabel("触发延迟毫秒数")
                            .onChange(of: delayText) { _, value in
                                if let delay = Int(value), PeekSettings.holdDelayRange.contains(delay) {
                                    settings.holdDelay = delay
                                }
                            }
                        Text("毫秒").foregroundStyle(.secondary)
                    }.disabled(!settings.optionHoverEnabled)
                    if !validDelay {
                        Text("请输入 0–5000 的整数，当前仍使用 \(settings.holdDelay) 毫秒。")
                            .font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Label("悬停预览", systemImage: "cursorarrow")
                } footer: {
                    Text("鼠标停在飞书会话上时生效，松开 Option 即关闭。增大延迟可减少误触。")
                }
                Section {
                    HStack {
                        Text("辅助功能权限")
                        Spacer()
                        Button("检查权限…", action: onCheckAccessibility)
                    }
                    HStack {
                        Text("lark-cli")
                        Spacer()
                        Button("选择可执行文件…", action: onSelectCLI)
                            .disabled(model.isAuthorizing || model.authStatus.state == .checking)
                    }
                } header: {
                    Label("权限与连接", systemImage: "gearshape.2")
                }
                Section {
                    HStack {
                        Text(scopeStatus)
                        Spacer()
                        if model.authStatus.state == .checking || model.isAuthorizing {
                            ProgressView().controlSize(.small)
                        }
                        Button("检测权限") { Task { await model.checkAuthorization() } }
                            .disabled(model.authStatus.state == .checking || model.isAuthorizing)
                    }
                    ForEach(AuthStatus.requiredScopes, id: \.self) { scope in
                        HStack {
                            Text(scope).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Text(scopeState(scope)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if model.authStatus.state == .needsLogin || model.isAuthorizing {
                        Button(model.isAuthorizing ? "等待浏览器授权…" : (model.authStatus.missingRequiredScopes.isEmpty ? "重新授权" : "一键申请缺失权限"), action: onAuthorize)
                            .disabled(model.isAuthorizing)
                    }
                    if case let .error(message) = model.authStatus.state {
                        Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                } header: {
                    Label("飞书只读权限", systemImage: "checkmark.shield")
                }
            }.formStyle(.grouped)
            HStack {
                Text("更改自动保存").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认设置") {
                    settings.restoreDefaults()
                    delayText = String(settings.holdDelay)
                    shortcutError = nil
                }
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }.frame(width: 560, height: 620)
            .onAppear { delayText = String(settings.holdDelay) }
            .onChange(of: settings.holdDelay) { _, value in delayText = String(value) }
    }

    private var validDelay: Bool {
        guard let value = Int(delayText) else { return false }
        return PeekSettings.holdDelayRange.contains(value)
    }

    private var scopeStatus: String {
        if model.isAuthorizing { return "正在申请授权" }
        switch model.authStatus.state {
        case .checking: return "正在检测…"
        case .ready: return "所需权限已齐全"
        case .needsLogin:
            let count = model.authStatus.missingRequiredScopes.count
            return count == 0 ? "登录已失效，需要重新授权" : "缺少 \(count) 项权限"
        case .error: return "检测失败，请重试"
        }
    }

    private func scopeState(_ scope: String) -> String {
        switch model.authStatus.state {
        case .checking: return "检测中"
        case .error: return "未确认"
        case .ready, .needsLogin: return model.authStatus.scopes.contains(scope) ? "已授权" : "缺失"
        }
    }

    private func shortcutRow(_ title: String, forSearch: Bool) -> some View {
        let current = forSearch ? settings.searchShortcut : settings.previewShortcut
        return HStack {
            Text(title)
            Spacer()
            ShortcutRecorder(shortcut: current, title: title) { shortcut in
                guard shortcut.isValid else {
                    shortcutError = "请使用 ⌃、⌥ 或 ⌘ 搭配字母、数字、符号、方向键或 F1–F12。"
                    return false
                }
                let accepted = settings.setShortcut(shortcut, forSearch: forSearch)
                shortcutError = accepted ? nil : "两个操作不能使用相同的快捷键，请换一个组合。"
                return accepted
            }.frame(width: 170, height: 30)

        }
    }

}
