import SwiftUI

@MainActor
public struct TimelineRow {
    public let id: String
    public let version: AnyHashable
    public let content: AnyView
    public let expansionVersion: AnyHashable?

    public init(id: String, version: AnyHashable, content: AnyView, expansionVersion: AnyHashable? = nil) {
        self.id = id
        self.version = version
        self.content = content
        self.expansionVersion = expansionVersion
    }
}
