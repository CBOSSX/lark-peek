import AppKit
import LarkPeekCore
import SwiftUI

@MainActor
public struct MessageTimelineView: View {
    @ObservedObject private var model: PeekModel
    private let messages: [LarkMessage]
    private let expandThreadsByDefault: Bool
    private let onOpenImage: (PresentedImage) -> Void
    @State private var expandedCards: [String: Bool] = [:]
    @State private var interactionAnchor: String?
    @State private var interactionRevision = 0

    public init(model: PeekModel, messages: [LarkMessage], expandThreadsByDefault: Bool, onOpenImage: @escaping (PresentedImage) -> Void) {
        self.model = model
        self.messages = messages
        self.expandThreadsByDefault = expandThreadsByDefault
        self.onOpenImage = onOpenImage
    }

    public var body: some View {
        let sessionID = model.timeline.id
        let revision = model.timeline.revision
        return NativeMessageTimeline(sessionID: sessionID, rows: timelineRows, interactionAnchor: interactionAnchor, interactionRevision: interactionRevision) {
            Task {
                guard model.timeline.id == sessionID, model.timeline.revision == revision else { return }
                await model.loadOlderMessages(automatic: true)
            }
        }
        .onChange(of: model.timeline.id) { expandedCards = [:] }
    }

    private struct RowVersion: Hashable {
        let message: LarkMessage
        let expanded: [String: Bool]
        let replyError: String?
    }

    private var timelineRows: [TimelineRow] {
        var rows = [TimelineRow(id: "timeline-pagination", version: model.timeline.pagination, content: AnyView(paginationRow))]
        if messages.isEmpty {
            rows.append(TimelineRow(id: "timeline-empty", version: 0, content: AnyView(
                ContentUnavailableView("没有可显示的消息", systemImage: "bubble.left").frame(height: 220)
            )))
        }
        rows += messages.map { message in
            let ids = Set([message.id] + message.threadReplies.map(\.id))
            let version = RowVersion(message: message, expanded: expandedCards.filter { ids.contains($0.key) }, replyError: message.threadID.flatMap { model.timeline.replyErrors[$0] })
            return TimelineRow(id: message.id, version: version, content: AnyView(
                messageRow(message).transaction { $0.disablesAnimations = true }
            ))
        }
        return rows
    }

    private var paginationRow: some View {
        HStack(spacing: 6) {
            switch model.timeline.pagination {
            case .ready:
                Button("加载更早消息") { Task { await model.loadOlderMessages() } }
            case .loading:
                ProgressView().controlSize(.mini)
                Text("正在加载更早消息…")
            case let .failed(_, reason):
                Text("加载失败").help(reason)
                Button("重试") { Task { await model.loadOlderMessages() } }
            case let .paused(cursor, reason):
                Text(reason).lineLimit(1).help(reason)
                if cursor != nil {
                    Button("继续查找") { Task { await model.loadOlderMessages() } }
                }
            case .exhausted:
                Text("已到最早消息")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 28)
    }

    private func messageRow(_ message: LarkMessage) -> some View {
        // Both measuring and displayed hosts read this immutable expansion snapshot.
        let expansionSnapshot = expandedCards
        let expansion = Binding(get: { expansionSnapshot }, set: {
            interactionAnchor = message.id
            interactionRevision += 1
            // A reused row may hold an older snapshot of other cards. Apply only this action's delta.
            for key in Set(expansionSnapshot.keys).union($0.keys) where expansionSnapshot[key] != $0[key] {
                expandedCards[key] = $0[key]
            }
        })
        return HStack(alignment: .top, spacing: 10) {
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
                    expandedCards: expansion,
                    replyError: message.threadID.flatMap { model.timeline.replyErrors[$0] },
                    onLoadThreadReplies: {
                        await model.loadThreadReplies(for: message.id)
                    },
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
    @Binding var expandedCards: [String: Bool]
    let replyError: String?
    let onLoadThreadReplies: () async -> Void
    let onOpenImage: (PresentedImage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MessageBodyView(message: message, expandedCards: $expandedCards, onOpenImage: onOpenImage)
            if message.threadID != nil, message.isThreadRoot {
                TopicRepliesCard(
                    message: message,
                    onLoadReplies: onLoadThreadReplies,
                    onOpenImage: onOpenImage,
                    isExpanded: expandedCards[message.id] ?? expandThreadByDefault,
                    expandedCards: $expandedCards,
                    replyError: replyError
                )
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MessageBodyView: View {
    let message: LarkMessage
    @Binding var expandedCards: [String: Bool]
    let onOpenImage: (PresentedImage) -> Void
    @State private var imageFrames: [String: CGRect] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.forwardedMessages.isEmpty {
                ForwardedMessagesCard(items: message.forwardedMessages, isExpanded: Binding(get: { expandedCards[message.id] ?? false }, set: { expandedCards[message.id] = $0 }))
            } else if let calendarShare = message.calendarShare {
                CalendarShareCard(calendarShare: calendarShare)
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
        ZStack(alignment: .leading) {
            if let data = image.data, let decodedImage = NSImage(data: data) {
                Image(nsImage: decodedImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 300, maxHeight: 180)
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
                    .background {
                        ScreenFrameReader { frame in
                            if imageFrames[image.key] != frame {
                                imageFrames[image.key] = frame
                            }
                        }
                    }
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            openImage(
                                decodedImage,
                                key: image.key,
                                localClickLocation: value.location
                            )
                        }
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                    .help("点击查看大图")
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("打开来自\(message.sender.name)的图片预览")
                    .accessibilityHint("在浮窗中放大查看")
                    .accessibilityIdentifier("peek-image-thumbnail-\(image.key)")
                    .accessibilityAction {
                        openImage(decodedImage, key: image.key, localClickLocation: nil)
                    }
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
        .frame(maxWidth: 300, alignment: .leading)
        .frame(height: 180)
        .clipped()
    }

    private func openImage(
        _ image: NSImage,
        key: String,
        localClickLocation: CGPoint?
    ) {
        let measuredFrame = imageFrames[key] ?? .zero
        let sourceFrame: CGRect
        if let localClickLocation, measuredFrame.width > 2, measuredFrame.height > 2 {
            let click = NSEvent.mouseLocation
            sourceFrame = CGRect(
                x: click.x - localClickLocation.x,
                y: click.y - (measuredFrame.height - localClickLocation.y),
                width: measuredFrame.width,
                height: measuredFrame.height
            )
        } else {
            sourceFrame = measuredFrame
        }
        onOpenImage(PresentedImage(
            id: "\(message.id):\(key)",
            image: image,
            senderName: message.sender.name,
            sourceFrame: sourceFrame
        ))
    }
}

private struct CalendarShareCard: View {
    let calendarShare: CalendarShare

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "calendar")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text("日历分享")
                    .font(.system(size: 12, weight: .semibold))
                Text(dateText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(timeText)
                    .font(.system(size: 13, weight: .medium))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
        }
    }

    private var dateText: String {
        Self.dateFormatter.string(from: calendarShare.startTime)
    }

    private var timeText: String {
        if Calendar.current.isDate(calendarShare.startTime, inSameDayAs: calendarShare.endTime) {
            return "\(Self.timeFormatter.string(from: calendarShare.startTime)) – \(Self.timeFormatter.string(from: calendarShare.endTime))"
        }
        return "\(Self.dateTimeFormatter.string(from: calendarShare.startTime)) – \(Self.dateTimeFormatter.string(from: calendarShare.endTime))"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("yMMMMdEEEE")
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("HHmm")
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MdHHmm")
        return formatter
    }()
}

private struct ForwardedMessagesCard: View {
    let items: [ForwardedMessageItem]
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
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
    let onLoadReplies: () async -> Void
    let onOpenImage: (PresentedImage) -> Void
    let isExpanded: Bool
    @Binding var expandedCards: [String: Bool]
    let replyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                let willExpand = !isExpanded
                expandedCards[message.id] = willExpand
                if willExpand, !message.threadRepliesLoaded {
                    Task { await onLoadReplies() }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                    Text("话题回复")
                        .fontWeight(.semibold)
                    Spacer()
                    if isExpanded, !message.threadRepliesLoaded, replyError == nil {
                        ProgressView().controlSize(.mini)
                    } else if !message.threadRepliesLoaded {
                        Text("展开加载")
                            .foregroundStyle(.secondary)
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
                } else if let replyError {
                    HStack {
                        Text("回复加载失败").help(replyError)
                        Button("重试") { Task { await onLoadReplies() } }
                    }
                    .font(.system(size: 11))
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
                MessageBodyView(message: reply, expandedCards: $expandedCards, onOpenImage: onOpenImage)
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
