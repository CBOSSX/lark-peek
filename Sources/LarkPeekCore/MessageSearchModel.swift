import Combine
import Foundation

public struct MessageSearchHit: Identifiable, Equatable, Sendable {
    public var id: String { message.id }
    public let message: LarkMessage
    public let chat: LarkChat

    public init(message: LarkMessage, chat: LarkChat) {
        self.message = message
        self.chat = chat
    }
}

public struct MessageSearchPage: Sendable {
    public let hits: [MessageSearchHit]
    public let nextPageToken: String?

    public init(hits: [MessageSearchHit], nextPageToken: String?) {
        self.hits = hits
        self.nextPageToken = nextPageToken
    }
}

@MainActor
public final class MessageSearchModel: ObservableObject {
    public typealias Loader = @MainActor (ReadOnlyCommand) async throws -> MessageSearchPage
    @Published public private(set) var hits: [MessageSearchHit] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    @Published public private(set) var hasSearched = false
    @Published public private(set) var nextPageToken: String?
    @Published public private(set) var query = ""
    @Published public private(set) var draftQuery = ""
    private var chatIDs: [String] = []
    private var generation = UUID()
    private var consumedTokens: Set<String> = []
    private var request: Task<Void, Never>?
    private let loader: Loader

    public init(loader: @escaping Loader) { self.loader = loader }

    public func search(_ text: String, chatID: String? = nil) {
        clearResults()
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        chatIDs = chatID.map { [$0] } ?? []
        hasSearched = true
        load(cursor: nil)
    }

    public func loadMore() {
        guard !isLoading, let nextPageToken else { return }
        load(cursor: nextPageToken)
    }

    public func retry() {
        guard !isLoading else { return }
        if let nextPageToken { load(cursor: nextPageToken) }
        else if hasSearched { search(query, chatID: chatIDs.first) }
    }

    public func clear() {
        clearResults()
        draftQuery = ""
    }

    public func editQuery(_ text: String) {
        guard text != draftQuery else { return }
        draftQuery = text
        clearResults()
    }

    private func clearResults() {
        cancel()
        hits = []
        error = nil
        hasSearched = false
        nextPageToken = nil
        consumedTokens = []
        query = ""
    }

    public func cancel() {
        request?.cancel()
        request = nil
        generation = UUID()
        isLoading = false
    }

    private func load(cursor: String?) {
        let generation = generation
        let command = ReadOnlyCommand.searchMessages(query: query, chatIDs: chatIDs, pageToken: cursor, pageSize: 20)
        isLoading = true
        error = nil
        request = Task { [weak self, loader] in
            do {
                _ = try command.arguments()
                let page = try await loader(command)
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                var known = Set(self.hits.map(\.id))
                self.hits += page.hits.filter { known.insert($0.id).inserted }
                if let cursor { self.consumedTokens.insert(cursor) }
                if let next = page.nextPageToken, self.consumedTokens.contains(next) {
                    self.nextPageToken = nil
                    self.error = "搜索分页没有前进，请重新搜索。"
                } else {
                    self.nextPageToken = page.nextPageToken
                }
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            self.isLoading = false
            self.request = nil
        }
    }
}
