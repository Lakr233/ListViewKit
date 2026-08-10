//
//  ListBouncyAnimatorTests.swift
//  ListViewKit
//

import CoreGraphics
import Foundation
import Testing
@testable import ListViewKit

/// The model's physics, pinned to exact numbers.
///
/// Every test here drives the model the way the list does — `willUpdate` once
/// per frame, `attach` once per mounted row — and asserts the exact values
/// the formulas produce: BouncyLayout's `/1000` resistance and full-delta
/// cap, the spread pointed away from the hand rather than along the scroll,
/// and springs that anchor where a cell was when it was first seen. Where
/// the model deliberately keeps an original behaviour that the retired model
/// rejected — pumping through momentum — the test says so, so a future gate
/// cannot sneak back in as a cleanup.
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

    /// The spread grades linearly with distance and caps at the full delta —
    /// `min(|delta|, |delta| · resistance)` — so a row 1000pt out takes the
    /// frame's whole travel and no row takes more. Rows above the hand move
    /// up, rows below move down.
    @Test
    func theSpreadGradesWithDistanceAndCapsAtTheFullDelta() {
        var animator = ListBouncyAnimator()
        _ = animator.attach(at: 150, key: 0) // 250 above: resistance 0.25
        _ = animator.attach(at: -100, key: 1) // 500 above: resistance 0.5
        _ = animator.attach(at: -600, key: 2) // 1000 above: resistance 1
        _ = animator.attach(at: -1600, key: 3) // 2000 above: capped at the delta
        _ = animator.attach(at: 650, key: 4) // 250 below: resistance 0.25
        animator.willUpdate(context(delta: 40, dt: 0, touchY: 400))

        #expect(animator.displacement(forKey: 0) == -10)
        #expect(animator.displacement(forKey: 1) == -20)
        #expect(animator.displacement(forKey: 2) == -40)
        #expect(animator.displacement(forKey: 3) == -40)
        #expect(animator.displacement(forKey: 4) == 10)
    }

    /// Either direction of travel spreads the same way: the hand is the
    /// centre the rows move away from, not the scroll's own direction.
    @Test
    func bothTravelDirectionsSpreadAlike() {
        var animator = ListBouncyAnimator()
        _ = animator.attach(at: -100, key: 0) // 500 above
        animator.willUpdate(context(delta: -40, dt: 0, touchY: 400))
        #expect(animator.displacement(forKey: 0) == -20)
    }

    /// The displacement is monotone along the row order — around the hand,
    /// rows 1…5 read 1 < 2 < 3 and 5 > 4 > 3 — so every gap opens past its
    /// placement and no pair of rows can trade places while travel arrives.
    @Test
    func theSpreadIsMonotoneAlongTheRowOrder() {
        let anchors: [CGFloat] = [200, 300, 400, 500, 600]
        for delta in [CGFloat(40), -40] {
            var animator = ListBouncyAnimator()
            for (key, anchor) in anchors.enumerated() {
                _ = animator.attach(at: anchor, key: key)
            }
            animator.willUpdate(context(delta: delta, dt: 0, touchY: 400))

            let d = anchors.indices.map { animator.displacement(forKey: $0) }
            #expect(d[0] < d[1])
            #expect(d[1] < d[2])
            #expect(d[2] < d[3])
            #expect(d[3] < d[4])
            #expect(d[2] == 0, "the row under the hand rides rigidly")
        }
    }

    /// And it stays monotone through a whole flick relaxing home — pump,
    /// spring, and the pooling that repairs what velocity coupling would
    /// drift across — so no frame of the ride shows a gap below its
    /// placement, rebound included.
    @Test
    func theChainHoldsThroughAFlickComingHome() {
        let anchors: [CGFloat] = [100, 250, 400, 550, 700]
        var animator = ListBouncyAnimator(style: .prominent)
        for (key, anchor) in anchors.enumerated() {
            _ = animator.attach(at: anchor, key: key)
        }

        let deltas: [CGFloat] = [60, 60, 40, -30, 20] + Array(repeating: 0, count: 600)
        for delta in deltas {
            animator.willUpdate(context(delta: delta, dt: Self.frame, touchY: 400))
            for (key, anchor) in anchors.enumerated() {
                _ = animator.attach(at: anchor, key: key)
            }
            let d = anchors.indices.map { animator.displacement(forKey: $0) }
            for i in 0 ..< d.count - 1 {
                #expect(d[i] <= d[i + 1] + 1e-9, "a gap closed below its placement")
            }
        }
        #expect(!animator.wantsNextFrame, "the flick should have settled")
    }

    /// The pump keeps sub-pixel precision — the one deliberate departure from
    /// the original, whose `floor(item.center)` pixel-aligns collection view
    /// cell frames. On a transform channel the floor quantised every row to
    /// 1pt stairs: a slow scroll pumped fractions the floor swallowed whole,
    /// then popped.
    @Test
    func thePumpKeepsSubpixelPrecision() {
        var animator = ListBouncyAnimator()
        _ = animator.attach(at: -100, key: 0) // 500 above
        animator.willUpdate(context(delta: 41, dt: 0, touchY: 400))
        #expect(animator.displacement(forKey: 0) == -20.5)

        var below = ListBouncyAnimator()
        _ = below.attach(at: 900, key: 0) // 500 below
        below.willUpdate(context(delta: -41, dt: 0, touchY: 400))
        #expect(below.displacement(forKey: 0) == 20.5)
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
        #expect(animator.displacement(forKey: 0) == -20)
    }

    /// A frame can hand over travel with no time attached — the layout pass
    /// owns the travel, the link owns the clock — and such a frame pumps
    /// without relaxing anything.
    @Test
    func travelWithNoTimeAttachedPumpsWithoutRelaxing() {
        var animator = ListBouncyAnimator()
        _ = animator.attach(at: -600, key: 0)
        animator.willUpdate(context(delta: 40, dt: 0))
        #expect(animator.displacement(forKey: 0) == -40)

        // And the tick that follows relaxes without pumping.
        animator.willUpdate(context(delta: 0, dt: Self.frame))
        let relaxed = animator.displacement(forKey: 0)
        #expect(relaxed > -40)
        #expect(relaxed < 0)
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

        // Spread upward, so the overshoot swings past the slot downward.
        var highest: CGFloat = -.greatestFiniteMagnitude
        for _ in 0 ..< 600 {
            animator.willUpdate(context(dt: Self.frame))
            _ = animator.attach(at: -600, key: 0)
            highest = max(highest, animator.displacement(forKey: 0))
        }
        #expect(highest > 1, "damping 0.5 should visibly overshoot the slot")
        #expect(animator.displacement(forKey: 0) == 0)
        #expect(!animator.wantsNextFrame)
    }

    /// A row first seen mid-spread attaches on the chain: undisplaced where
    /// zero keeps the neighbours' order, and carrying its neighbour's
    /// displacement where zero would bunch against it.
    @Test
    func aNewRowAttachesOnTheChain() {
        var animator = ListBouncyAnimator()
        _ = animator.attach(at: -100, key: 0)
        animator.willUpdate(context(delta: 40, dt: 0, touchY: 400))
        let displaced = animator.displacement(forKey: 0)
        #expect(displaced == -20)

        // Below the displaced row, zero sits inside the order — the
        // original's anchoring at the cell's current centre.
        #expect(animator.attach(at: 200, key: 1) == 0)
        // Above it, zero would sit below a row already carried past this
        // slot's rest order, so the newcomer enters holding the chain.
        #expect(animator.attach(at: -300, key: 2) == displaced)
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
        #expect(abs(stiffened.displacement(forKey: 0)) < abs(untouched.displacement(forKey: 0)))
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
