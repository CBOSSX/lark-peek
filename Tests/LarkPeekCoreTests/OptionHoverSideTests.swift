import AppKit
import Testing
@testable import LarkPeekCore

struct OptionHoverSideTests {
    @Test func selectedSideTracksReleaseEvenWhenOtherOptionRemainsDown() {
        let left = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x20)
        let right = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)
        let both = left.union(right)
        #expect(OptionHoverSide.left.isHeld(in: left))
        #expect(!OptionHoverSide.left.isHeld(in: right))
        #expect(OptionHoverSide.right.isHeld(in: right))
        #expect(!OptionHoverSide.right.isHeld(in: left))
        for side in OptionHoverSide.allCases {
            #expect(side.isHeld(in: both))
            #expect(!side.isHeld(in: []))
        }
        #expect(OptionHoverSide.either.isHeld(in: left))
        #expect(OptionHoverSide.either.isHeld(in: right))
        // Left released while right remains held must not start a new gesture.
        #expect(!OptionHoverSide.either.isKeyDown(keyCode: 58, flags: right))
        #expect(!OptionHoverSide.left.isKeyDown(keyCode: 61, flags: both))
        #expect(!OptionHoverSide.right.isKeyDown(keyCode: 58, flags: both))
        #expect(OptionHoverSide.left.isKeyDown(keyCode: 58, flags: both))
        #expect(OptionHoverSide.right.isKeyDown(keyCode: 61, flags: both))
        // Releasing Shift with Option still held cannot begin a gesture.
        #expect(!OptionHoverSide.either.isKeyDown(keyCode: 56, flags: both))
    }
}
