import Foundation
import Testing
@testable import LarkPeekCore

@Test func conversationRowGeometryRequiresTheOriginalPointerInsideTheRow() {
    let row = CGRect(x: 210, y: 250, width: 442, height: 62)

    #expect(ConversationRowGeometry.isCandidate(row, containing: CGPoint(x: 640, y: 280)))
    #expect(!ConversationRowGeometry.isCandidate(row, containing: CGPoint(x: 700, y: 280)))
}

@Test func conversationRowGeometryRejectsTheWholeListContainer() {
    let list = CGRect(x: 210, y: 150, width: 442, height: 900)

    #expect(!ConversationRowGeometry.isCandidate(list, containing: CGPoint(x: 520, y: 280)))
}

@Test func widerConversationRowWinsOverNestedContent() {
    let nestedContent = CGRect(x: 250, y: 255, width: 300, height: 52)
    let fullRow = CGRect(x: 210, y: 250, width: 442, height: 62)

    #expect(ConversationRowGeometry.prefers(fullRow, over: nestedContent))
    #expect(!ConversationRowGeometry.prefers(nestedContent, over: fullRow))
}

@Test func horizontalProbesStayOnTheSameLineAndExpandNearestFirst() throws {
    let origin = CGPoint(x: 520, y: 280)
    let probes = ConversationRowGeometry.horizontalProbePoints(around: origin)

    #expect(probes.prefix(4).map(\.x) == [488, 552, 456, 584])
    #expect(probes.allSatisfy { $0.y == origin.y })
    #expect(probes.allSatisfy { $0.x >= 0 })
}

@Test func applicationRootFallbackTargetsOnlyTheMainLarkProcess() {
    #expect(LarkApplicationIdentity.isMainApplication(bundleIdentifier: "com.electron.lark"))
    #expect(LarkApplicationIdentity.isMainApplication(bundleIdentifier: "com.larksuite.suite"))
    #expect(!LarkApplicationIdentity.isMainApplication(bundleIdentifier: "com.electron.lark.helper"))
    #expect(!LarkApplicationIdentity.isMainApplication(bundleIdentifier: nil))
}
