import AppKit
import LarkPeekCore
import SwiftUI

private final class PeekPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PeekPanelController {
    private let model: PeekModel
    private let panel: PeekPanel

    init(model: PeekModel) {
        self.model = model
        panel = PeekPanel(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 540),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow

        installContentView()
    }

    private func installContentView() {
        panel.contentView = NSHostingView(rootView: PeekPanelView(
            model: model,
            onClose: { [weak self] in self?.close() },
            onSelect: { [weak model] chat, conversation in
                Task { @MainActor in await model?.select(chat, for: conversation) }
            },
            onRetry: { [weak model] in
                Task { @MainActor in await model?.retryCurrent() }
            }
        ))
    }

    var isVisible: Bool { panel.isVisible }
    var frame: CGRect { panel.frame }

    func show(anchor axFrame: CGRect) {
        panel.setFrameOrigin(origin(for: axFrame, panelSize: panel.frame.size))
        panel.orderFrontRegardless()
    }

    func showPreviewFixture(anchor: CGRect) {
        model.showPreviewFixture()
        installContentView()
        show(anchor: anchor)
    }

    func showError(_ title: String, detail: String, anchor: CGRect) {
        model.presentError("\(title)：\(detail)")
        show(anchor: anchor)
    }

    func close() {
        model.dismiss()
        panel.orderOut(nil)
    }

    private func origin(for axFrame: CGRect, panelSize: CGSize) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let anchor = CGRect(
            x: axFrame.minX,
            y: primaryHeight - axFrame.maxY,
            width: axFrame.width,
            height: axFrame.height
        )
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let preferredRight = anchor.maxX + 10
        let preferredLeft = anchor.minX - panelSize.width - 10
        let x = preferredRight + panelSize.width <= visible.maxX ? preferredRight : max(visible.minX, preferredLeft)
        let desiredY = anchor.maxY - panelSize.height
        let y = min(max(desiredY, visible.minY + 8), visible.maxY - panelSize.height - 8)
        return CGPoint(x: x, y: y)
    }
}

private struct PeekPanelView: View {
    @ObservedObject var model: PeekModel
    let onClose: () -> Void
    let onSelect: (LarkChat, HoveredConversation) -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            content
        }
        .frame(width: 480, height: 540)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "eye.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.blue)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 12)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭（Esc）")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .waiting:
            instructionView
        case let .loading(conversation):
            loadingView(conversation)
        case let .candidates(conversation, chats):
            candidateView(conversation, chats: chats)
        case let .messages(_, _, messages, _):
            MessageTimelineView(model: model, messages: messages)
        case let .error(_, message):
            errorView(message)
        }
    }

    private var instructionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "cursorarrow.motionlines")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("把鼠标停在飞书会话行上")
                .font(.headline)
            Text("按 ⌃⌥P 读取这个会话的最近消息")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadingView(_ conversation: HoveredConversation) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("正在读取“\(conversation.name)”")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func candidateView(_ conversation: HoveredConversation, chats: [LarkChat]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("发现多个同名会话")
                .font(.headline)
            Text("请选择一次。Lark Peek 只保存匿名映射，不保存消息正文。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(chats) { chat in
                        Button { onSelect(chat, conversation) } label: {
                            HStack(spacing: 11) {
                                Image(systemName: chat.kind == .p2p ? "person.fill" : "person.2.fill")
                                    .frame(width: 28, height: 28)
                                    .background(Color.blue.opacity(0.12), in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(chat.name).font(.system(size: 13, weight: .medium))
                                    Text([chat.kind.label, chat.external ? "外部" : nil].compactMap { $0 }.joined(separator: " · "))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(10)
                            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 13) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("预览失败").font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("重试", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var title: String {
        switch model.state {
        case .waiting: "Lark Peek"
        case let .loading(conversation): conversation.name
        case let .candidates(conversation, _): conversation.name
        case let .messages(_, chat, _, _): chat.name
        case .error: "Lark Peek"
        }
    }

}

private struct MessageTimelineView: View {
    @ObservedObject var model: PeekModel
    let messages: [LarkMessage]

    @State private var initializedChatID: String?
    @State private var loadTask: Task<Void, Never>?

    private var chatID: String? { messages.first?.chatID }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.hasOlderMessages {
                        olderMessagesTrigger
                    }
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if messages.isEmpty {
                            ContentUnavailableView("没有可显示的消息", systemImage: "bubble.left")
                                .frame(maxWidth: .infinity)
                                .padding(.top, 110)
                        }
                        ForEach(messages) { message in
                            messageRow(message).id(message.id)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .background {
                    ScrollTopObserver {
                        guard initializedChatID == chatID else { return }
                        loadOlderMessages(using: proxy)
                    }
                }
            }
            .coordinateSpace(name: "message-timeline")
            .onPreferenceChange(TimelineTopOffsetKey.self) { offset in
                guard initializedChatID == chatID, offset >= -4 else { return }
                loadOlderMessages(using: proxy)
            }
            .task(id: chatID) {
                initializedChatID = nil
                guard let last = messages.last else { return }
                try? await Task.sleep(for: .milliseconds(40))
                proxy.scrollTo(last.id, anchor: .bottom)
                try? await Task.sleep(for: .milliseconds(40))
                initializedChatID = chatID
            }
            .onDisappear {
                loadTask?.cancel()
                loadTask = nil
            }
        }
    }

    private var olderMessagesTrigger: some View {
        HStack {
            Spacer()
            if model.isLoadingOlderMessages {
                ProgressView().controlSize(.small)
            }
            Spacer()
        }
        .frame(height: 24)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: TimelineTopOffsetKey.self,
                    value: geometry.frame(in: .named("message-timeline")).minY
                )
            }
        }
    }

    private func loadOlderMessages(using proxy: ScrollViewProxy) {
        guard loadTask == nil,
              model.hasOlderMessages,
              !model.isLoadingOlderMessages,
              let anchorID = messages.first?.id else { return }
        loadTask = Task { @MainActor in
            await model.loadOlderMessages()
            guard !Task.isCancelled else {
                loadTask = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(40))
            proxy.scrollTo(anchorID, anchor: .top)
            loadTask = nil
        }
    }

    private func messageRow(_ message: LarkMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(message.sender.name)
                    .font(.system(size: 12, weight: .semibold))
                Text(Self.timeFormatter.string(from: message.createTime))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                if message.updated {
                    Text("已编辑").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            Text(message.content)
                .font(.system(size: 13))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

private struct TimelineTopOffsetKey: PreferenceKey {
    static let defaultValue = -CGFloat.greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollTopObserver: NSViewRepresentable {
    let onReachedTop: () -> Void

    func makeNSView(context: Context) -> ScrollTopObserverView {
        let view = ScrollTopObserverView()
        view.onReachedTop = onReachedTop
        return view
    }

    func updateNSView(_ view: ScrollTopObserverView, context: Context) {
        view.onReachedTop = onReachedTop
        view.attachToEnclosingScrollView()
    }
}

@MainActor
private final class ScrollTopObserverView: NSView {
    var onReachedTop: (() -> Void)?
    private weak var observedClipView: NSClipView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.attachToEnclosingScrollView()
        }
    }

    func attachToEnclosingScrollView() {
        guard let clipView = enclosingScrollView?.contentView,
              observedClipView !== clipView else { return }
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClipView)
        observedClipView = clipView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    @objc private func clipViewBoundsDidChange() {
        guard let scrollView = enclosingScrollView,
              let documentView = scrollView.documentView else { return }
        let visibleRect = scrollView.documentVisibleRect
        let documentRect = documentView.bounds
        let distanceFromTop: CGFloat
        if documentView.isFlipped {
            distanceFromTop = visibleRect.minY - documentRect.minY
        } else {
            distanceFromTop = documentRect.maxY - visibleRect.maxY
        }
        if distanceFromTop <= 6 {
            onReachedTop?()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
