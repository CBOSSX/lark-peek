import AppKit
import LarkPeekCore
import SwiftUI

struct MessageSearchView: View {
    @ObservedObject var model: MessageSearchModel
    let currentChat: LarkChat?
    let onSelect: (MessageSearchHit) -> Void
    let isActive: Bool
    @State private var currentChatOnly = false
    @FocusState private var searchFocused: Bool

    init(model: MessageSearchModel, currentChat: LarkChat?, isActive: Bool = true, onSelect: @escaping (MessageSearchHit) -> Void) {
        self.model = model
        self.currentChat = currentChat
        self.onSelect = onSelect
        self.isActive = isActive
        _currentChatOnly = State(initialValue: currentChat != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索关键词", text: Binding(get: { model.draftQuery }, set: { model.editQuery($0) }))
                        .textFieldStyle(.plain).focused($searchFocused)
                        .padding(.vertical, 9).padding(.horizontal, 11)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                        .onSubmit(submit)
                    Button("搜索", action: submit)
                        .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
                        .disabled(model.draftQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack {
                    scopeButton("全部会话", current: false)
                    if let currentChat { scopeButton(currentChat.name, current: true) }
                    Spacer()
                    Text("只读搜索").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(18)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !model.hasSearched {
                        VStack(spacing: 14) {
                            Image(systemName: "text.magnifyingglass").font(.system(size: 32)).foregroundStyle(.secondary)
                            Text("查找消息、链接或代码").font(.system(size: 16, weight: .semibold))
                            Text("输入关键词并回车，点选结果查看上下文。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.top, 64)
                    } else {
                        Text("“\(model.query)” · 已加载 \(model.hits.count) 条")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(model.hits) { hit in result(hit) }
                        if model.hits.isEmpty, !model.isLoading, model.error == nil {
                            ContentUnavailableView("没有找到匹配消息", systemImage: "magnifyingglass",
                                description: Text("试试更短的关键词，或切换到全部会话。"))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    if model.isLoading {
                        HStack { Spacer(); ProgressView("正在搜索…"); Spacer() }.padding()
                    } else if let error = model.error {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            Button("重试") { model.retry() }
                        }
                    } else if model.nextPageToken != nil {
                        Button("加载更多结果") { model.loadMore() }.frame(maxWidth: .infinity)
                    }
                }
                .padding(18)
            }
        }
        .onAppear { searchFocused = isActive }
        .onChange(of: isActive) { _, active in searchFocused = active }
        .onChange(of: currentChatOnly) { _, _ in
            if model.hasSearched { submit() }
        }
    }

    private func scopeButton(_ title: String, current: Bool) -> some View {
        Button { currentChatOnly = current } label: {
            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(currentChatOnly == current ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04),
                    in: Capsule())
                .foregroundStyle(currentChatOnly == current ? Color.accentColor : Color.secondary)
        }.buttonStyle(.plain)
        .accessibilityValue(currentChatOnly == current ? "已选择" : "未选择")
    }

    private func submit() {
        model.search(model.draftQuery, chatID: currentChatOnly ? currentChat?.id : nil)
    }

    private func result(_ hit: MessageSearchHit) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(hit.chat.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(hit.chat.kind.label).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(hit.message.sender.name)
                Text(hit.message.createTime, format: .dateTime.month().day().hour().minute())
            }.font(.caption).foregroundStyle(.secondary)
            Text(hit.message.content).font(.system(size: 13)).lineLimit(5).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("查看上下文") { onSelect(hit) }
                Button("复制消息") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hit.message.content, forType: .string)
                }
                Spacer()
                if let url = LarkAppLink.chat(hit.chat.id) {
                    Button("打开飞书") { NSWorkspace.shared.open(url) }
                }
            }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.accentColor)
        }
        .padding(14)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
}
