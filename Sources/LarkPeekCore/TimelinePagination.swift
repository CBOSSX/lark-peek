import Foundation

public enum TimelinePagination: Equatable, Hashable, Sendable {
    case ready(String)
    case loading(UUID, String)
    case failed(String, String)
    case paused(String?, String)
    case exhausted

    public var cursor: String? {
        switch self {
        case let .ready(cursor), let .loading(_, cursor), let .failed(cursor, _): cursor
        case let .paused(cursor, _): cursor
        case .exhausted: nil
        }
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var allowsAutomaticLoading: Bool {
        if case .ready = self { return true }
        return false
    }
}
