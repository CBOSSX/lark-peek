import AppKit
import LarkPeekCore
import OSLog
import SwiftUI

private let timelineLogger = Logger(subsystem: "io.github.cbossx.larkpeek", category: "MessageTimeline")

private final class PeekPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that only accepts mouse events inside the card. Clicks landing
/// on the transparent in-flight margin fall through to the windows below.
private final class CardHostingView: NSHostingView<PeekPanelView> {
    /// Interactive rect in view coordinates (the card's frame within the window).
    var interactiveRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveRect.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

/// Drives the fly-in / fly-out presentation animation of the peek panel.
@MainActor
private final class PanelPresentation: ObservableObject {
    @Published var isPresented = false
    /// Offset of the card within the window while the window is enlarged to give
    /// the fly-in animation room to render past the card's resting frame.
    @Published var cardOffset: CGSize = .zero
    /// Unit point (in card coordinates) the card scales from — the cursor position.
    var appearAnchor: UnitPoint = .center
}

@MainActor
final class PeekPanelController {
    static let cardSize = CGSize(width: 480, height: 540)
    /// Transparent margin around the card so the SwiftUI shadow has room to draw.
    static let cardPadding: CGFloat = 18
    /// Extra transparent margin used while the fly-in/out animation is in flight.
    private static let flightPadding: CGFloat = 30

    private let model: PeekModel
    private let panel: PeekPanel
    private let presentation = PanelPresentation()
    private var closeTask: Task<Void, Never>?

    init(model: PeekModel) {
        self.model = model
        panel = PeekPanel(
            contentRect: CGRect(
                x: 0, y: 0,
                width: Self.cardSize.width + Self.cardPadding * 2,
                height: Self.cardSize.height + Self.cardPadding * 2
            ),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The shadow is drawn by SwiftUI inside the content view so it scales
        // together with the fly-in animation.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow

        installContentView()
    }

    private func installContentView() {
        let hostingView = CardHostingView(rootView: PeekPanelView(
            model: model,
            presentation: presentation,
            onClose: { [weak self] in self?.close() },
            onSelect: { [weak model] chat, conversation in
                Task { @MainActor in await model?.select(chat, for: conversation) }
            },
            onRetry: { [weak model] in
                Task { @MainActor in await model?.retryCurrent() }
            }
        ))
        // The window is resized manually (it stays enlarged to give the fly-in/out
        // animation room to render), so the hosting view must not clamp it to the
        // SwiftUI ideal size.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
    }

    var isVisible: Bool { panel.isVisible }
    /// Screen frame of the visible card (used for click-outside hit testing).
    var frame: CGRect { lastCardFrame }

    private var lastCardFrame: CGRect = .zero

    func show(anchor axFrame: CGRect) {
        closeTask?.cancel()
        closeTask = nil
        let cardFrame = CGRect(origin: origin(for: axFrame, panelSize: Self.cardSize), size: Self.cardSize)
        lastCardFrame = cardFrame
        let anchor = cursorPoint(NSEvent.mouseLocation, relativeTo: cardFrame)
        presentation.appearAnchor = anchor
        // The window always covers the card's whole flight path from the cursor,
        // so the animation is never clipped at the window edge. The extra area is
        // transparent and click-through.
        let flight = flightFrame(cardFrame: cardFrame, anchor: anchor)
        panel.setFrame(flight, display: false)
        presentation.cardOffset = cardOffset(of: cardFrame, within: flight)
        updateInteractiveRect()
        if panel.isVisible {
            presentation.isPresented = true
            return
        }
        panel.orderFrontRegardless()
        // Let the hidden state render for one pass so the fly-in animation plays.
        DispatchQueue.main.async { [presentation] in
            presentation.isPresented = true
        }
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
        guard panel.isVisible, closeTask == nil else { return }
        // The window already covers the flight path, so the fly-out can start
        // immediately — no re-framing, no jump.
        presentation.isPresented = false
        closeTask = Task { @MainActor [weak self] in
            // Wait for the fly-out animation before removing the window.
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self else { return }
            self.panel.orderOut(nil)
            self.presentation.cardOffset = .zero
            self.model.dismiss()
            self.closeTask = nil
        }
    }

    /// Restricts mouse interaction to the card; the transparent margin around it
    /// lets clicks fall through to the apps below.
    private func updateInteractiveRect() {
        guard let view = panel.contentView as? CardHostingView else { return }
        let windowFrame = panel.frame
        view.interactiveRect = CGRect(
            x: lastCardFrame.minX - windowFrame.minX,
            y: lastCardFrame.minY - windowFrame.minY,
            width: lastCardFrame.width,
            height: lastCardFrame.height
        )
    }

    /// Window frame large enough to contain the card's whole flight path from the
    /// cursor to its resting position, plus room for the shadow.
    private func flightFrame(cardFrame: CGRect, anchor: UnitPoint) -> CGRect {
        let scale: CGFloat = 0.2
        let cursor = CGPoint(
            x: cardFrame.minX + anchor.x * cardFrame.width,
            y: cardFrame.minY + (1 - anchor.y) * cardFrame.height
        )
        let smallOrigin = CGPoint(
            x: scale * cardFrame.minX + (1 - scale) * cursor.x,
            y: scale * cardFrame.minY + (1 - scale) * cursor.y
        )
        let smallRect = CGRect(
            origin: smallOrigin,
            size: CGSize(width: cardFrame.width * scale, height: cardFrame.height * scale)
        )
        return cardFrame.union(smallRect).insetBy(dx: -Self.flightPadding, dy: -Self.flightPadding)
    }

    /// Offset of the card's center from the window's center, in SwiftUI coordinates.
    private func cardOffset(of cardFrame: CGRect, within windowFrame: CGRect) -> CGSize {
        CGSize(
            width: cardFrame.midX - windowFrame.midX,
            height: windowFrame.midY - cardFrame.midY
        )
    }

    /// Cursor position as a unit point in card coordinates. The cursor is usually
    /// outside the card (on the conversation row), so the range is only loosely
    /// clamped — the card should genuinely fly out from the cursor.
    private func cursorPoint(_ cursor: CGPoint, relativeTo cardFrame: CGRect) -> UnitPoint {
        let u = (cursor.x - cardFrame.minX) / cardFrame.width
        let v = 1 - (cursor.y - cardFrame.minY) / cardFrame.height
        return UnitPoint(
            x: min(max(u, -3), 4),
            y: min(max(v, -3), 4)
        )
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
    @ObservedObject var presentation: PanelPresentation
    let onClose: () -> Void
    let onSelect: (LarkChat, HoveredConversation) -> Void
    let onRetry: () -> Void

    private let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            content
                .id(stateKey)
                .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
        }
        .animation(.easeOut(duration: 0.16), value: stateKey)
        .frame(width: PeekPanelController.cardSize.width, height: PeekPanelController.cardSize.height)
        .background { glassBackground }
        .clipShape(cardShape)
        .overlay {
            cardShape.strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.38),
                        Color.white.opacity(0.10),
                        Color.white.opacity(0.03)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
        }
        .shadow(color: .black.opacity(0.30), radius: 12, y: 5)
        // Presentation modifiers apply to the card itself (before the transparent
        // padding is added) so the scale anchor maps exactly to card coordinates.
        .scaleEffect(presentation.isPresented ? 1 : 0.2, anchor: presentation.appearAnchor)
        .opacity(presentation.isPresented ? 1 : 0)
        .blur(radius: presentation.isPresented ? 0 : 14)
        .animation(
            presentation.isPresented
                ? .spring(response: 0.34, dampingFraction: 0.78)
                : .easeIn(duration: 0.18),
            value: presentation.isPresented
        )
        .padding(PeekPanelController.cardPadding)
        // Positions the card inside the enlarged in-flight window. Kept outside
        // the animation modifier so window re-framing never animates.
        .offset(presentation.cardOffset)
        // The card stays centered in the window whatever size the window is.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Frosted-glass gradient: material base, a diagonal light wash, and a soft
    /// accent glow bleeding in from the top edge.
    private var glassBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: [
                    Color.white.opacity(0.14),
                    Color.white.opacity(0.03),
                    Color.black.opacity(0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color.accentColor.opacity(0.10), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 320
            )
        }
    }

    private var hairline: some View {
        LinearGradient(
            colors: [Color.white.opacity(0.20), Color.white.opacity(0.05)],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
    }

    private var stateKey: String {
        switch model.state {
        case .waiting: "waiting"
        case .loading: "loading"
        case .candidates: "candidates"
        case .messages: "messages"
        case .error: "error"
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "eye.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.blue.gradient)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 12)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.07), in: Circle())
                    .contentShape(Circle())
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
                .symbolEffect(.pulse.byLayer, options: .repeating)
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
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .modifier(HoverBackground(cornerRadius: 10))
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
                        olderMessagesTrigger(using: proxy)
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
                        timelineLogger.debug(
                            "Reached timeline top chat=\(chatID ?? "none", privacy: .private(mask: .hash)) count=\(messages.count)"
                        )
                        loadOlderMessages(using: proxy)
                    }
                }
            }
            .task(id: chatID) {
                initializedChatID = nil
                guard let last = messages.last else { return }
                timelineLogger.debug(
                    "Initializing timeline chat=\(chatID ?? "none", privacy: .private(mask: .hash)) count=\(messages.count)"
                )
                try? await Task.sleep(for: .milliseconds(40))
                proxy.scrollTo(last.id, anchor: .bottom)
                try? await Task.sleep(for: .milliseconds(40))
                initializedChatID = chatID
                timelineLogger.debug(
                    "Timeline initialized chat=\(chatID ?? "none", privacy: .private(mask: .hash))"
                )
            }
            .onDisappear {
                if loadTask != nil {
                    timelineLogger.debug(
                        "Cancelling older-message UI task chat=\(chatID ?? "none", privacy: .private(mask: .hash))"
                    )
                }
                loadTask?.cancel()
                loadTask = nil
            }
        }
    }

    private func olderMessagesTrigger(using proxy: ScrollViewProxy) -> some View {
        HStack {
            Spacer()
            if model.isLoadingOlderMessages {
                ProgressView().controlSize(.small)
            } else {
                Button("加载更早消息") {
                    timelineLogger.debug(
                        "Manual older-message request chat=\(chatID ?? "none", privacy: .private(mask: .hash)) count=\(messages.count)"
                    )
                    loadOlderMessages(using: proxy)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(height: 24)
    }

    private func loadOlderMessages(using proxy: ScrollViewProxy) {
        guard loadTask == nil else {
            timelineLogger.debug("Ignoring duplicate older-message UI request: task already active")
            return
        }
        guard model.hasOlderMessages, !model.isLoadingOlderMessages else {
            timelineLogger.debug("Ignoring older-message UI request: no page available or model already loading")
            return
        }
        guard let anchorID = messages.first?.id else {
            timelineLogger.debug("Ignoring older-message UI request: timeline is empty")
            return
        }
        let previousCount = messages.count
        timelineLogger.debug(
            "Starting older-message UI task chat=\(chatID ?? "none", privacy: .private(mask: .hash)) anchor=\(anchorID, privacy: .private(mask: .hash)) count=\(previousCount)"
        )
        loadTask = Task { @MainActor in
            await model.loadOlderMessages()
            guard !Task.isCancelled else {
                timelineLogger.debug("Older-message UI task cancelled")
                loadTask = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(40))
            proxy.scrollTo(anchorID, anchor: .top)
            timelineLogger.debug(
                "Restored timeline anchor=\(anchorID, privacy: .private(mask: .hash)) previousCount=\(previousCount) currentCount=\(messages.count)"
            )
            loadTask = nil
        }
    }

    private func messageRow(_ message: LarkMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            SenderAvatar(name: message.sender.name)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(message.sender.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SenderAvatar.color(for: message.sender.name))
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
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

/// Circular avatar with the sender's initial, tinted by a stable per-sender color.
private struct SenderAvatar: View {
    let name: String

    var body: some View {
        ZStack {
            Circle().fill(Self.color(for: name).gradient)
            Text(String(name.prefix(1)))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 30, height: 30)
    }

    static func color(for name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .mint]
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }
}

/// Subtle rounded background that brightens while the pointer hovers the row.
private struct HoverBackground: ViewModifier {
    let cornerRadius: CGFloat
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                Color.primary.opacity(isHovered ? 0.10 : 0.05),
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
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
    private var wasNearTop: Bool?

    private static let enterThreshold: CGFloat = 6
    private static let leaveThreshold: CGFloat = 24

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
        wasNearTop = nil
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
        let isNearTop: Bool
        if wasNearTop == true {
            isNearTop = distanceFromTop <= Self.leaveThreshold
        } else {
            isNearTop = distanceFromTop <= Self.enterThreshold
        }

        guard let previouslyNearTop = wasNearTop else {
            wasNearTop = isNearTop
            timelineLogger.debug(
                "Top observer initialized distance=\(distanceFromTop, format: .fixed(precision: 1)) nearTop=\(isNearTop)"
            )
            return
        }
        wasNearTop = isNearTop
        if !previouslyNearTop, isNearTop {
            timelineLogger.debug(
                "Top observer crossed threshold distance=\(distanceFromTop, format: .fixed(precision: 1))"
            )
            onReachedTop?()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
