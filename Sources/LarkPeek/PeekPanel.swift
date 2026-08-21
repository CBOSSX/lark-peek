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

private struct PresentedImage: Identifiable {
    let id: String
    let image: NSImage
    let senderName: String
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
    private lazy var imagePreviewController = ImagePreviewPanelController()
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
            },
            onOpenImage: { [weak self] item in self?.showPresentedImage(item) }
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
        dismissPresentedImage()
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
        dismissPresentedImage()
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

    @discardableResult
    func dismissPresentedImage() -> Bool {
        imagePreviewController.dismiss()
    }

    func contains(_ point: CGPoint) -> Bool {
        lastCardFrame.contains(point) || imagePreviewController.contains(point)
    }

    private func showPresentedImage(_ item: PresentedImage) {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(lastCardFrame) }) ?? NSScreen.main
        imagePreviewController.show(item, on: screen)
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
    let onOpenImage: (PresentedImage) -> Void

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
        case let .messages(conversation, _, messages, _):
            MessageTimelineView(
                model: model,
                messages: messages,
                expandThreadsByDefault: conversation.threadHint != nil,
                onOpenImage: onOpenImage
            )
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
            Text("长按 ⌥，或按 ⌃⌥P 读取最近消息")
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

private struct ImageLightboxView: View {
    let item: PresentedImage
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Button(action: onDismiss) {
                Color.black.opacity(0.82)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭图片预览背景")
            .accessibilityIdentifier("peek-image-backdrop")

            Image(nsImage: item.image)
                .resizable()
                .scaledToFit()
                .contentShape(Rectangle())
                .onTapGesture { }
                .padding(28)
                .accessibilityLabel("来自\(item.senderName)的图片")
                .accessibilityIdentifier("peek-image-lightbox")

            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 30, height: 30)
                            .background(.ultraThinMaterial, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭图片预览")
                    .accessibilityIdentifier("peek-image-close")
                }
                Spacer()
            }
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

@MainActor
private final class ImagePreviewPanelController {
    private static let maximumSize = CGSize(width: 1_200, height: 900)
    private static let screenFraction: CGFloat = 0.86

    private let panel: PeekPanel

    init() {
        panel = PeekPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.title = "图片预览"
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow
        panel.becomesKeyOnlyIfNeeded = true
    }

    func show(_ item: PresentedImage, on screen: NSScreen?) {
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let size = CGSize(
            width: min(Self.maximumSize.width, visible.width * Self.screenFraction),
            height: min(Self.maximumSize.height, visible.height * Self.screenFraction)
        )
        let frame = CGRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        let hostingView = NSHostingView(rootView: ImageLightboxView(
            item: item,
            onDismiss: { [weak self] in self?.dismiss() }
        ))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    @discardableResult
    func dismiss() -> Bool {
        guard panel.isVisible else { return false }
        panel.orderOut(nil)
        panel.contentView = nil
        return true
    }

    func contains(_ point: CGPoint) -> Bool {
        panel.isVisible && panel.frame.contains(point)
    }
}

private struct MessageTimelineView: View {
    @ObservedObject var model: PeekModel
    let messages: [LarkMessage]
    let expandThreadsByDefault: Bool
    let onOpenImage: (PresentedImage) -> Void

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
                    // The initial page is capped at 20 messages. Eagerly laying
                    // them out lets the bottom anchor measure the real document
                    // height before choosing its initial viewport. A LazyVStack
                    // can leave the bottom rows unrealized and produce an empty
                    // viewport for tall conversations.
                    VStack(alignment: .leading, spacing: 10) {
                        if messages.isEmpty {
                            ContentUnavailableView("没有可显示的消息", systemImage: "bubble.left")
                                .frame(maxWidth: .infinity)
                                .padding(.top, 110)
                        }
                        ForEach(messages) { message in
                            messageRow(message)
                                .padding(.bottom, message.id == messages.last?.id ? 8 : 0)
                                .id(message.id)
                                .onAppear {
                                    guard message.id == messages.first?.id
                                            || message.id == messages.last?.id else { return }
                                    timelineLogger.info(
                                        "Timeline boundary row appeared chat=\(chatID ?? "none", privacy: .private(mask: .hash)) message=\(message.id, privacy: .private(mask: .hash)) count=\(messages.count)"
                                    )
                                }
                        }
                    }
                }
                .padding(.horizontal, 14)
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
            // Establish the initial viewport during SwiftUI's first layout pass.
            // ScrollViewReader is retained only for restoring the visible anchor
            // after prepending an older page; it does not drive initial scrolling.
            .defaultScrollAnchor(.bottom)
            .task(id: chatID) {
                initializedChatID = nil
                await Task.yield()
                guard !Task.isCancelled else { return }
                initializedChatID = chatID
                timelineLogger.info(
                    "Timeline initialized with eager bottom layout chat=\(chatID ?? "none", privacy: .private(mask: .hash)) count=\(messages.count)"
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
        timelineLogger.info(
            "Preserving timeline position while loading older messages chat=\(chatID ?? "none", privacy: .private(mask: .hash)) anchor=\(anchorID, privacy: .private(mask: .hash)) count=\(previousCount)"
        )
        loadTask = Task { @MainActor in
            await model.loadOlderMessages()
            guard !Task.isCancelled else {
                timelineLogger.info("Timeline position preservation cancelled")
                loadTask = nil
                return
            }
            await Task.yield()
            guard !Task.isCancelled else {
                loadTask = nil
                return
            }
            proxy.scrollTo(anchorID, anchor: .top)
            let currentCount: Int
            if case let .messages(_, _, currentMessages, _) = model.state {
                currentCount = currentMessages.count
            } else {
                currentCount = previousCount
            }
            timelineLogger.info(
                "Preserved timeline position after loading older messages anchor=\(anchorID, privacy: .private(mask: .hash)) previousCount=\(previousCount) currentCount=\(currentCount)"
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
                MessageContentView(
                    message: message,
                    expandThreadByDefault: expandThreadsByDefault,
                    onOpenImage: onOpenImage
                )
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

private struct MessageContentView: View {
    let message: LarkMessage
    let expandThreadByDefault: Bool
    let onOpenImage: (PresentedImage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MessageBodyView(message: message, onOpenImage: onOpenImage)
            if message.threadID != nil {
                TopicRepliesCard(
                    message: message,
                    initiallyExpanded: expandThreadByDefault,
                    onOpenImage: onOpenImage
                )
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MessageBodyView: View {
    let message: LarkMessage
    let onOpenImage: (PresentedImage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.forwardedMessages.isEmpty {
                ForwardedMessagesCard(items: message.forwardedMessages)
            } else if message.sharedChatID != nil {
                sharedChatCard
            } else if message.type == "interactive" {
                interactiveCard
            } else {
                orderedContent
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var interactiveCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("互动卡片", systemImage: "rectangle.on.rectangle.angled")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.blue)
            if contentParts.isEmpty || message.content == "[互动卡片]" {
                Text("这张卡片暂时没有可提取的文本内容")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                orderedContent
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.blue.opacity(0.18), lineWidth: 1)
        }
    }

    private var sharedChatCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.teal.gradient, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(message.sharedChatName ?? "群聊名片")
                    .font(.system(size: 12, weight: .semibold))
                Text(message.sharedChatName == nil ? "分享了一个群聊" : "群聊名片")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var contentParts: [MessageMarkdown.ContentPart] {
        MessageMarkdown.contentParts(from: message.content, imageKeys: message.images.map(\.key))
    }

    private var orderedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(contentParts.enumerated()), id: \.offset) { _, part in
                switch part {
                case let .text(content):
                    MarkdownMessageView(content: content)
                case let .image(key):
                    if let image = message.images.first(where: { $0.key == key }) {
                        messageImage(image)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func messageImage(_ image: MessageImage) -> some View {
        if let data = image.data, let decodedImage = NSImage(data: data) {
            Button {
                onOpenImage(PresentedImage(
                    id: "\(message.id):\(image.key)",
                    image: decodedImage,
                    senderName: message.sender.name
                ))
            } label: {
                Image(nsImage: decodedImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 300, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Color.black.opacity(0.58), in: Circle())
                            .padding(7)
                    }
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .help("点击查看大图")
            .accessibilityLabel("打开来自\(message.sender.name)的图片预览")
            .accessibilityHint("在浮窗中放大查看")
            .accessibilityIdentifier("peek-image-thumbnail-\(image.key)")
        } else if image.attempted {
            Label("图片暂不可用", systemImage: "photo.badge.exclamationmark")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("正在加载图片…")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }
}

private struct ForwardedMessagesCard: View {
    let items: [ForwardedMessageItem]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "text.bubble.fill")
                    Text("聊天记录")
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(items.count) 条")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.system(size: 11))
            .foregroundStyle(.purple)

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        if index > 0 {
                            Divider().opacity(0.55)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(item.senderName)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(SenderAvatar.color(for: item.senderName))
                                if let time = item.createTime {
                                    Text(Self.timeFormatter.string(from: time))
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            if !item.content.isEmpty {
                                MarkdownMessageView(content: item.content)
                            }
                        }
                        .padding(.vertical, 7)
                    }
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.purple.opacity(0.17), lineWidth: 1)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

private struct TopicRepliesCard: View {
    let message: LarkMessage
    let onOpenImage: (PresentedImage) -> Void
    @State private var isExpanded: Bool

    init(
        message: LarkMessage,
        initiallyExpanded: Bool = false,
        onOpenImage: @escaping (PresentedImage) -> Void
    ) {
        self.message = message
        self.onOpenImage = onOpenImage
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                    Text("话题回复")
                        .fontWeight(.semibold)
                    Spacer()
                    if !message.threadRepliesLoaded {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(replyCountLabel)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.system(size: 11))
            .foregroundStyle(.blue)

            if isExpanded {
                if message.threadRepliesLoaded {
                    if message.threadReplies.isEmpty {
                        Text("暂未读到回复")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(message.threadReplies) { reply in
                            replyRow(reply)
                        }
                        if message.threadHasMore {
                            Text("回复较多，当前展示前 50 条")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Text("正在读取话题回复…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.blue.opacity(0.15), lineWidth: 1)
        }
    }

    private var replyCountLabel: String {
        "\(message.threadReplies.count)\(message.threadHasMore ? "+" : "") 条"
    }

    private func replyRow(_ reply: LarkMessage) -> some View {
        HStack(alignment: .top, spacing: 7) {
            SenderAvatar(name: reply.sender.name)
                .scaleEffect(0.75, anchor: .topLeading)
                .frame(width: 23, height: 23)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(reply.sender.name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SenderAvatar.color(for: reply.sender.name))
                    Text(Self.timeFormatter.string(from: reply.createTime))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    if reply.updated {
                        Text("已编辑")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
                MessageBodyView(message: reply, onOpenImage: onOpenImage)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

private struct MarkdownMessageView: View {
    let content: String

    private var blocks: [MessageMarkdown.Block] {
        MessageMarkdown.blocks(from: content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func blockView(_ block: MessageMarkdown.Block) -> some View {
        switch block.kind {
        case .paragraph:
            inlineText(block.content)

        case let .heading(level):
            inlineText(block.content)
                .font(.system(size: max(13, 18 - CGFloat(level)), weight: .bold))

        case let .unordered(level):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").frame(width: 10, alignment: .trailing)
                inlineText(block.content)
            }
            .padding(.leading, CGFloat(level * 14))

        case let .ordered(number, level):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).").frame(minWidth: 16, alignment: .trailing)
                inlineText(block.content)
            }
            .padding(.leading, CGFloat(level * 14))

        case let .quote(level):
            HStack(alignment: .top, spacing: 8) {
                Capsule()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 3)
                inlineText(block.content).foregroundStyle(.secondary)
            }
            .padding(.leading, CGFloat(level * 12))

        case .code:
            Text(block.content)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func inlineText(_ value: String) -> some View {
        Text(MessageMarkdown.attributedString(from: value))
            .font(.system(size: 13))
            .lineSpacing(3)
            .textSelection(.enabled)
    }
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
