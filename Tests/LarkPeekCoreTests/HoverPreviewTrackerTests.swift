import Foundation
import Testing
@testable import LarkPeekCore

@Test func passingRowsNeverSwitchAndSettledRowsSwitchOnce() {
    let a = HoveredConversation(name: "A", rowFrame: CGRect(x: 0, y: 0, width: 300, height: 60), rowTexts: ["A"])
    let b = HoveredConversation(name: "B", rowFrame: CGRect(x: 0, y: 60, width: 300, height: 60), rowTexts: ["B"])
    var tracker = HoverPreviewTracker()
    tracker.activate(a)
    #expect(tracker.observe(b, at: 1) == nil)
    #expect(tracker.observe(nil, at: 1.1) == nil)
    #expect(tracker.observe(b, at: 2) == nil)
    #expect(tracker.observe(b, at: 2.1) == nil)
    #expect(tracker.observe(b, at: 2.3) == b)
    #expect(tracker.observe(b, at: 3) == nil)
    #expect(tracker.observe(a, at: 4) == nil)
    #expect(tracker.observe(a, at: 4.3) == a)
}

@Test func identicalNamesOnDifferentRowsRequireTheirOwnDwell() {
    let a = HoveredConversation(name: "同名", rowFrame: CGRect(x: 0, y: 0, width: 300, height: 60), rowTexts: [])
    let b = HoveredConversation(name: "同名", rowFrame: CGRect(x: 0, y: 60, width: 300, height: 60), rowTexts: [])
    var tracker = HoverPreviewTracker()
    tracker.activate(a)
    #expect(tracker.observe(b, at: 0) == nil)
    #expect(tracker.observe(b, at: 0.3) == b)
    #expect(tracker.observe(nil, at: 1) == nil)
    #expect(tracker.observe(b, at: 2) == nil)
}
