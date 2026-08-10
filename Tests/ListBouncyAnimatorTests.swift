//
//  ListBouncyAnimatorTests.swift
//  ListViewKit
//

import CoreGraphics
import Foundation
import Testing
@testable import ListViewKit

/// The port's physics, pinned to the original's numbers.
///
/// Every test here drives the model the way the list does — `willUpdate` once
/// per frame, `attach` once per mounted row — and asserts the exact values
/// BouncyLayout's formulas produce: the `/1000` resistance, the min/max cap,
/// the floor, and springs that anchor where a cell was when it was first
/// seen. Where the port deliberately keeps an original behaviour that the
/// retired model rejected — pumping through momentum — the test says so, so
/// a future gate cannot sneak back in as a cleanup.
@MainActor
@Suite(.serialized)
struct ListBouncyAnimatorTests {
    private static let frame: TimeInterval = 1.0 / 120.0

    /// A frame's context, with only what the model reads varying.
    private func context(
        delta: CGFloat = 0,
        dt: TimeInterval = Self.frame,
        touchY: CGFloat = 400,
        interacting: Bool = false
    ) -> ListAnimatorContext {
        .init(
            viewportRect: CGRect(x: 0, y: 0, width: 200, height: 400),
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 4000),
            interactionAnchorY: touchY,
            scrollDelta: delta,
            deltaTime: dt,
            isUserInteracting: interacting
        )
    }

    // MARK: - The pump

    /// `resistance = |touch − anchor| / 1000`, and the row under the hand has
    /// none: it rides the scroll rigidly however hard the frame pumps.
    @Test
    func aRowUnderTheTouchRidesTheScrollRigidly() {
        var animator = ListBouncyAnimator()
        _ = animator.attach(at: 400, key: 0)
        animator.willUpdate(context(delta: 100, dt: 0, touchY: 400))
        #expect(animator.displacement(forKey: 0) == 0)
    }

    /// The bite grades linearly with distance and caps at the full delta —
    /// `min(delta, delta · resistance)` — so a row 1000pt out absorbs every
    /// point of the frame's travel and no row absorbs more.
    @Test
    func theBiteGradesWithDistanceAndCapsAtTheFullDelta() {
        var animator = ListBouncyAnimator()
        _ = animator.attach(at: 150, key: 0) // 250 out: resistance 0.25
        _ = animator.attach(at: -100, key: 1) // 500 out: resistance 0.5
        _ = animator.attach(at: -600, key: 2) // 1000 out: resistance 1
        _ = animator.attach(at: -1600, key: 3) // 2000 out: capped at the delta
        animator.willUpdate(context(delta: 40, dt: 0, touchY: 400))

        #expect(animator.displacement(forKey: 0) == 10)
        #expect(animator.displacement(forKey: 1) == 20)
        #expect(animator.displacement(forKey: 2) == 40)
        #expect(animator.displacement(forKey: 3) == 40)
    }

    /// Both branches of the original's `delta < 0 ? max : min` pick the
    /// smaller magnitude, so the two directions mirror.
    @Test
    func theTwoDirectionsMirror() {
        var animator = ListBouncyAnimator()
        _ = animator.attach(at: -100, key: 0) // 500 out
        animator.willUpdate(context(delta: -40, dt: 0, touchY: 400))
        #expect(animator.displacement(forKey: 0) == -20)
    }

    /// The pump keeps sub-pixel precision — the one deliberate departure from
    /// the original, whose `floor(item.center)` pixel-aligns collection view
    /// cell frames. On a transform channel the floor quantised every row to
    /// 1pt stairs: a slow scroll pumped fractions the floor swallowed whole,
    /// then popped.
    @Test
    func thePumpKeepsSubpixelPrecision() {
        var animator = ListBouncyAnimator()
        _ = animator.attach(at: -100, key: 0) // 500 out
        animator.willUpdate(context(delta: 41, dt: 0, touchY: 400))
        #expect(animator.displacement(forKey: 0) == 20.5)

        var downward = ListBouncyAnimator()
        _ = downward.attach(at: -100, key: 0)
        downward.willUpdate(context(delta: -41, dt: 0, touchY: 400))
        #expect(downward.displacement(forKey: 0) == -20.5)
    }

    /// Momentum pumps too. The original feeds every bounds change through
    /// the same formula and measures resistance from where the hand was last
    /// seen; a gate on `isUserInteracting` is the retired model's idea, not
    /// this one's.
    @Test
    func momentumKeepsPumping() {
        var animator = ListBouncyAnimator()
        _ = animator.attach(at: -100, key: 0)
        animator.willUpdate(context(delta: 40, dt: 0, touchY: 400, interacting: false))
        #expect(animator.displacement(forKey: 0) == 20)
    }

    /// A frame can hand over travel with no time attached — the layout pass
    /// owns the travel, the link owns the clock — and such a frame pumps
    /// without relaxing anything.
    @Test
    func travelWithNoTimeAttachedPumpsWithoutRelaxing() {
        var animator = ListBouncyAnimator()
        _ = animator.attach(at: -600, key: 0)
        animator.willUpdate(context(delta: 40, dt: 0))
        #expect(animator.displacement(forKey: 0) == 40)

        // And the tick that follows relaxes without pumping.
        animator.willUpdate(context(delta: 0, dt: Self.frame))
        let relaxed = animator.displacement(forKey: 0)
        #expect(relaxed < 40)
        #expect(relaxed > 0)
    }

    // MARK: - The spring

    /// A displaced row comes home, and an underdamped style overshoots its
    /// slot on the way — that is what damping below 1 is for.
    @Test
    func theSpringPullsARowHomeAndOvershoots() {
        var animator = ListBouncyAnimator(style: .prominent)
        _ = animator.attach(at: -600, key: 0)
        animator.willUpdate(context(delta: 40, dt: 0))
        #expect(animator.wantsNextFrame)

        var lowest: CGFloat = .greatestFiniteMagnitude
        for _ in 0 ..< 600 {
            animator.willUpdate(context(dt: Self.frame))
            _ = animator.attach(at: -600, key: 0)
            lowest = min(lowest, animator.displacement(forKey: 0))
        }
        #expect(lowest < -1, "damping 0.5 should visibly overshoot the slot")
        #expect(animator.displacement(forKey: 0) == 0)
        #expect(!animator.wantsNextFrame)
    }

    /// A row first seen mid-spread attaches at its slot and shows no
    /// displacement: the original anchors a behaviour at the cell's current
    /// centre, wherever the springs around it happen to be.
    @Test
    func aNewRowAttachesUndisplaced() {
        var animator = ListBouncyAnimator()
        _ = animator.attach(at: -100, key: 0)
        animator.willUpdate(context(delta: 40, dt: 0))
        #expect(animator.displacement(forKey: 0) != 0)

        #expect(animator.attach(at: -300, key: 1) == 0)
    }

    // MARK: - Bookkeeping

    /// Rebasing moves the anchors with the content space, so a resistance
    /// measured after a compensation reads the same distance the reader sees.
    @Test
    func rebaseMovesTheAnchorsWithTheContent() {
        var rebased = ListBouncyAnimator()
        _ = rebased.attach(at: 300, key: 0)
        rebased.rebase(byContentOffset: 500)
        rebased.willUpdate(context(delta: 40, dt: 0, touchY: 900))

        var still = ListBouncyAnimator()
        _ = still.attach(at: 300, key: 0)
        still.willUpdate(context(delta: 40, dt: 0, touchY: 400))

        #expect(rebased.displacement(forKey: 0) == still.displacement(forKey: 0))
    }

    /// Resetting leaves nothing to prune, relax, or show.
    @Test
    func resetDropsEveryAttachment() {
        var animator = ListBouncyAnimator()
        _ = animator.attach(at: -100, key: 0)
        animator.willUpdate(context(delta: 200, dt: 0))
        #expect(animator.wantsNextFrame)

        animator.reset()
        #expect(animator.board.attachments.isEmpty)
        #expect(!animator.wantsNextFrame)
    }

    /// An attachment whose row stops being offered belongs to a row that is
    /// no longer mounted, and it is dropped rather than kept forever.
    @Test
    func attachmentsForUnseenRowsArePruned() {
        var animator = ListBouncyAnimator()
        _ = animator.attach(at: -100, key: 0)
        _ = animator.attach(at: -200, key: 1)

        for _ in 0 ..< 10 {
            animator.willUpdate(context(dt: 0.25))
            _ = animator.attach(at: -100, key: 0)
        }

        #expect(animator.board.attachments[0] != nil)
        #expect(animator.board.attachments[1] == nil)
    }

    /// A knob change reaches the springs already in flight: the knobs are
    /// read on every step, so nothing per-attachment can hold a stale tuning.
    @Test
    func knobChangesReachSpringsInFlight() {
        var stiffened = ListBouncyAnimator()
        _ = stiffened.attach(at: -100, key: 0)
        stiffened.willUpdate(context(delta: 40, dt: 0))
        var untouched = ListBouncyAnimator()
        _ = untouched.attach(at: -100, key: 0)
        untouched.willUpdate(context(delta: 40, dt: 0))
        #expect(stiffened.displacement(forKey: 0) == untouched.displacement(forKey: 0))

        stiffened.frequency = 6
        stiffened.willUpdate(context(dt: Self.frame))
        untouched.willUpdate(context(dt: Self.frame))

        // A stiffer spring pulls the same displacement home harder.
        #expect(stiffened.displacement(forKey: 0) < untouched.displacement(forKey: 0))
    }

    /// Two configurations are the same animator whatever each is showing.
    @Test
    func equalityIsOverTheKnobs() {
        var displaced = ListBouncyAnimator()
        _ = displaced.attach(at: -100, key: 0)
        displaced.willUpdate(context(delta: 40, dt: 0))

        #expect(displaced == ListBouncyAnimator())
        #expect(ListBouncyAnimator(style: .subtle) != ListBouncyAnimator(style: .prominent))
    }
}
