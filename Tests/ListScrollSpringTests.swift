//
//  ListScrollSpringTests.swift
//  ListViewKit
//

import Foundation
import Testing
@testable import ListViewKit

/// The model has no views and no clock, so everything it promises can be
/// checked by driving it directly rather than inferred from what a list
/// looked like afterwards.
@Suite
struct ListScrollSpringTests {
    /// A deterministic stand-in for scrolling. Real deltas are not random, but
    /// the invariants have to survive whatever a hand can produce, including
    /// the reversals a flick-and-catch makes.
    private struct Noise {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }

        mutating func next(in range: ClosedRange<CGFloat>) -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = CGFloat(state >> 11) / CGFloat(UInt64(1) << 53)
            return range.lowerBound + unit * (range.upperBound - range.lowerBound)
        }
    }

    private static let frame: TimeInterval = 1.0 / 120.0
    /// The list clamps `deltaTime` before it reaches the model.
    private static let longestFrame: TimeInterval = 1.0 / 30.0

    private static let rowCenters: [CGFloat] = stride(from: -2000, through: 2000, by: 37).map { $0 }

    // MARK: - Convergence

    @Test
    func anyStretchReturnsToRest() {
        for delta in [CGFloat(-200), -24, -3, 3, 24, 200] {
            var spring = ListScrollSpring()
            spring.advance(scrollDelta: delta, deltaTime: Self.frame, anchorY: 0)

            var frames = 0
            while !spring.isAtRest, frames < 2000 {
                spring.advance(scrollDelta: 0, deltaTime: Self.frame, anchorY: 0)
                frames += 1
            }
            #expect(spring.isAtRest, "did not settle from \(delta)")
            #expect(spring.stretch == 0)
        }
    }

    @Test
    func restIsReachedAtTheLongestFrameTheListWillPass() {
        var spring = ListScrollSpring()
        spring.advance(scrollDelta: 200, deltaTime: Self.longestFrame, anchorY: 0)

        var frames = 0
        while !spring.isAtRest, frames < 2000 {
            spring.advance(scrollDelta: 0, deltaTime: Self.longestFrame, anchorY: 0)
            frames += 1
        }
        #expect(spring.isAtRest)
    }

    @Test
    func underdampedOvershootStillSettles() {
        var spring = ListScrollSpring(dampingRatio: 0.2)
        spring.advance(scrollDelta: 24, deltaTime: Self.frame, anchorY: 0)

        var crossedZero = false
        var frames = 0
        while !spring.isAtRest, frames < 4000 {
            let before = spring.stretch
            spring.advance(scrollDelta: 0, deltaTime: Self.frame, anchorY: 0)
            if before > 0, spring.stretch < 0 { crossedZero = true }
            frames += 1
        }
        #expect(crossedZero, "0.2 damping should overshoot")
        #expect(spring.isAtRest)
    }

    /// Rest is a claim about the velocity as much as the value.
    ///
    /// `SpringInterpolation.completed` looks only at the distance to the
    /// target, so an underdamped spring reports it for the frame it spends
    /// passing through zero at full speed. Since reaching rest is what zeroes
    /// the state, believing that reading kills the animation at its first
    /// crossing — with a fine enough sample the spring never oscillates at
    /// all. Counting crossings is what makes that visible; asserting "not at
    /// rest" frame by frame is not, because a 120 Hz sample lands inside the
    /// resting band only by luck.
    @Test
    func aFastZeroCrossingIsNotMistakenForRest() {
        for deltaTime in [Self.frame, 1e-5] {
            var spring = ListScrollSpring(dampingRatio: 0.2)
            spring.advance(scrollDelta: 24, deltaTime: deltaTime, anchorY: 0)

            var crossings = 0
            var peakAfterFirstCrossing: CGFloat = 0
            var previous = spring.stretch
            var steps = 0
            while !spring.isAtRest, steps < 2_000_000 {
                spring.advance(scrollDelta: 0, deltaTime: deltaTime, anchorY: 0)
                if (previous > 0) != (spring.stretch > 0), spring.stretch != 0 { crossings += 1 }
                if crossings >= 1 { peakAfterFirstCrossing = max(peakAfterFirstCrossing, abs(spring.stretch)) }
                previous = spring.stretch
                steps += 1
            }

            #expect(crossings >= 8, "died after \(crossings) crossings at dt \(deltaTime)")
            #expect(peakAfterFirstCrossing > 8, "no swing left after the first crossing")
            #expect(spring.isAtRest)
        }
    }

    /// What a plausible scroll speed actually stretches by.
    ///
    /// This pinned the opposite claim while the frequency was paper-derived:
    /// that ordinary scrolling stays inside the budget and only a fling
    /// saturates. Measuring Messages retired it. At the fitted ω the stretch
    /// reaches the budget from roughly 300pt/s up, and the recording agrees —
    /// through every flick in it the far field moved as one rigid block, with
    /// all of the spread concentrated into the first row or two.
    ///
    /// So the speed the effect reads is a slow one. Below ~250pt/s the stretch
    /// is graded; above it the gesture always looks the same, and what varies
    /// between gestures is how long the budget stays spent, not how big it is.
    @Test
    func slowScrollingIsGradedAndAnythingBriskSaturates() {
        func steadyStretch(scrollingAt velocity: CGFloat, hz: Double) -> CGFloat {
            var spring = ListScrollSpring()
            let deltaTime = 1.0 / hz
            for _ in 0 ..< 3000 {
                spring.advance(
                    scrollDelta: velocity * CGFloat(deltaTime),
                    deltaTime: deltaTime,
                    anchorY: 0
                )
            }
            return spring.stretch
        }

        #expect(steadyStretch(scrollingAt: 100, hz: 120) < 8)
        #expect(steadyStretch(scrollingAt: 200, hz: 120) < 16)
        #expect(steadyStretch(scrollingAt: 600, hz: 120) == 20)
        // Monotone where it is graded, so slow scrolling still reads as speed.
        #expect(steadyStretch(scrollingAt: 100, hz: 120) < steadyStretch(scrollingAt: 200, hz: 120))
    }

    /// Steady stretch depends on the frame rate, and the paper figure is an
    /// upper bound rather than the answer.
    ///
    /// Injecting a per-frame delta into a discrete relaxation under-relaxes,
    /// by more at 60 Hz than at 120 Hz, so the same gesture is slacker on a
    /// 60 Hz display. The gap is small enough to leave alone — fixing it means
    /// making the injection dt-independent, which is the whole integrator —
    /// but not small enough to discover by accident later.
    ///
    /// Measured below the budget, since at the fitted frequency any speed
    /// worth calling scrolling clamps, and a clamped value hides the ratio.
    @Test
    func steadyStretchIsFrameRateDependentByAKnownAmount() {
        func ratioToContinuousLimit(hz: Double) -> CGFloat {
            var spring = ListScrollSpring()
            let deltaTime = 1.0 / hz
            let velocity: CGFloat = 100
            for _ in 0 ..< 3000 {
                spring.advance(
                    scrollDelta: velocity * CGFloat(deltaTime),
                    deltaTime: deltaTime,
                    anchorY: 0
                )
            }
            let continuous = 2 * CGFloat(spring.dampingRatio) * velocity
                / CGFloat(spring.angularFrequency)
            return spring.stretch / continuous
        }

        #expect(abs(ratioToContinuousLimit(hz: 120) - 0.944) < 0.005)
        #expect(abs(ratioToContinuousLimit(hz: 60) - 0.889) < 0.005)
        #expect(ratioToContinuousLimit(hz: 60) < ratioToContinuousLimit(hz: 120))
    }

    /// The relaxation the defaults are fitted to.
    ///
    /// Two gaps were tracked frame by frame through a screen recording of
    /// Messages — one per gesture, in different parts of the conversation —
    /// and each was least-squares fitted to a second-order response. They
    /// landed at ω = 19.0/ζ = 0.74 and ω = 21.0/ζ = 0.60, which is where the
    /// defaults come from.
    ///
    /// Pinned on how long the opening takes to halve rather than on the whole
    /// curve: the two traces agree on that to within 4ms (64 and 68), and
    /// disagree on the tail by a factor the model could not sit inside anyway
    /// (they reach a tenth at 136ms and 100ms). A 60 Hz window capture is
    /// worth the half-life and not much past it.
    @Test
    func theDefaultsRelaxLikeTheRecordingTheyWereFittedTo() {
        let hz = 60.0
        let deltaTime = 1.0 / hz
        var spring = ListScrollSpring()
        // Seed the budget and let it go: the fits put the residual velocity at
        // the peak under 30px/s, which is nothing against a 36px opening.
        spring.advance(scrollDelta: spring.maximumStretch, deltaTime: 1e-6, anchorY: 0)
        let peak = spring.stretch
        #expect(peak > 0)

        var curve: [CGFloat] = [peak]
        for _ in 0 ..< 40 {
            spring.advance(scrollDelta: 0, deltaTime: deltaTime, anchorY: 0)
            curve.append(spring.stretch)
        }

        func milliseconds(toReach fraction: CGFloat) -> TimeInterval {
            guard let frame = curve.firstIndex(where: { $0 / peak <= fraction }) else { return .infinity }
            return Double(frame) / hz * 1000
        }

        // Measured: 64ms and 68ms.
        #expect((50.0 ... 85.0).contains(milliseconds(toReach: 0.5)), "half-life \(milliseconds(toReach: 0.5))ms")
        // Measured: 100ms and 136ms — the traces themselves span that.
        #expect((85.0 ... 160.0).contains(milliseconds(toReach: 0.1)), "tenth at \(milliseconds(toReach: 0.1))ms")
        // Monotone down to the tenth: the recording shows no bounce on the way.
        let toTenth = curve.prefix(while: { $0 / peak > 0.1 })
        #expect(zip(toTenth, toTenth.dropFirst()).allSatisfy { $0 > $1 })

        // And barely any bounce past it. One trace undershot by 3% of its peak
        // and the other not at all, which is what keeps the damping near 0.75:
        // the half-life alone cannot tell ζ from ω, since only their product
        // sets it. A ζ of 0.3 has the same half-life and rebounds by a third.
        let undershoot = -(curve.min() ?? 0) / peak
        #expect(undershoot < 0.08, "rebounds by \\(undershoot * 100)% of the peak")
    }

    // MARK: - Bounds

    @Test
    func displacementNeverExceedsTheStretchBudget() {
        var noise = Noise(seed: 7)
        for stretch in [CGFloat(4), 24, 200] {
            var spring = ListScrollSpring(maximumStretch: stretch)
            for _ in 0 ..< 4000 {
                spring.advance(
                    scrollDelta: noise.next(in: -400 ... 400),
                    deltaTime: Self.frame,
                    anchorY: noise.next(in: -500 ... 500)
                )
                #expect(abs(spring.stretch) <= stretch + 1e-9)
                for center in Self.rowCenters {
                    #expect(abs(spring.displacement(forRowCenteredAt: center)) <= stretch + 1e-9)
                }
            }
        }
    }

    /// The clamp has to land in the spring's own state, not only in what the
    /// rows read, or the spring keeps unwinding a stretch nothing ever showed.
    @Test
    func internalStateIsClampedNotJustTheOutput() {
        var spring = ListScrollSpring(maximumStretch: 10)
        for _ in 0 ..< 50 {
            spring.advance(scrollDelta: 1000, deltaTime: Self.frame, anchorY: 0)
            #expect(abs(spring.stretch) <= 10 + 1e-9)
        }
        // Saturated and then released, it comes back within the time a spring
        // released from the boundary would take, not longer.
        var frames = 0
        while !spring.isAtRest, frames < 600 {
            spring.advance(scrollDelta: 0, deltaTime: Self.frame, anchorY: 0)
            frames += 1
        }
        #expect(spring.isAtRest)
    }

    // MARK: - Ordering

    /// Rows are laid out edge to edge, so displacement may only open gaps.
    @Test
    func displacementIsNonDecreasingAlongTheContent() {
        var noise = Noise(seed: 11)
        var spring = ListScrollSpring()
        for _ in 0 ..< 4000 {
            spring.advance(
                scrollDelta: noise.next(in: -300 ... 300),
                deltaTime: Self.frame,
                anchorY: noise.next(in: -800 ... 800)
            )
            var previous = -CGFloat.greatestFiniteMagnitude
            for center in Self.rowCenters {
                let displaced = spring.displacement(forRowCenteredAt: center)
                #expect(displaced >= previous - 1e-9)
                previous = displaced
            }
        }
    }

    /// Ordering must not depend on how tall the rows happen to be, including
    /// the degenerate heights the engine allows.
    @Test
    func rowsOfAnyHeightKeepTheirOrder() {
        let heights: [CGFloat] = [0, 0, 1, 4000, 1, 0, 12, 800, 0, 3]
        var tops: [CGFloat] = []
        var cursor: CGFloat = 0
        for height in heights {
            tops.append(cursor)
            cursor += height
        }

        var noise = Noise(seed: 13)
        var spring = ListScrollSpring()
        for _ in 0 ..< 2000 {
            spring.advance(
                scrollDelta: noise.next(in: -300 ... 300),
                deltaTime: Self.frame,
                anchorY: noise.next(in: -200 ... 4200)
            )
            var previousBottom = -CGFloat.greatestFiniteMagnitude
            for (top, height) in zip(tops, heights) {
                let displaced = spring.displacement(forRowCenteredAt: top + height / 2)
                #expect(top + displaced >= previousBottom - 1e-9)
                previousBottom = top + height + displaced
            }
        }
    }

    // MARK: - Continuity

    /// Sign reversal is bounded, not continuous. A sample can land either side
    /// of the anchor, and the weight is one-sided, so displacement does jump —
    /// what it may not do is jump further than the budget.
    @Test
    func displacementChangesByAtMostTheBudgetInOneFrame() {
        var noise = Noise(seed: 17)
        var spring = ListScrollSpring(maximumStretch: 24)
        var previous = [CGFloat](repeating: 0, count: Self.rowCenters.count)

        for _ in 0 ..< 6000 {
            // Reversals large enough to flip the sign every few frames.
            spring.advance(
                scrollDelta: noise.next(in: -60 ... 60),
                deltaTime: Self.frame,
                anchorY: 0
            )
            for (offset, center) in Self.rowCenters.enumerated() {
                let displaced = spring.displacement(forRowCenteredAt: center)
                #expect(abs(displaced - previous[offset]) <= 24 + 1e-9)
                previous[offset] = displaced
            }
        }
    }

    // MARK: - Anchor

    @Test
    func rebaseMovesTheAnchorWithTheContentSpace() {
        var spring = ListScrollSpring()
        spring.advance(scrollDelta: 24, deltaTime: Self.frame, anchorY: 100)
        let before = spring.displacement(forRowCenteredAt: 300)

        spring.rebase(byContentOffset: 500)
        #expect(spring.displacement(forRowCenteredAt: 800) == before)
    }

    /// A list, as the animator is handed one: rows from zero to `contentHeight`
    /// in a viewport whose top edge is wherever the reader has dragged it.
    private static func context(
        viewportTop: CGFloat,
        viewportHeight: CGFloat = 900,
        contentHeight: CGFloat,
        scrollDelta: CGFloat
    ) -> ListAnimatorContext {
        .init(
            viewportRect: CGRect(x: 0, y: viewportTop, width: 320, height: viewportHeight),
            contentRect: CGRect(x: 0, y: 0, width: 320, height: contentHeight),
            scrollDelta: scrollDelta,
            deltaTime: frame,
            isUserInteracting: true
        )
    }

    /// Where the first and last rows of a four-row list sit, at 92pt each.
    private static let firstRowCentre: CGFloat = 46
    private static let lastRowCentre: CGFloat = 322
    private static let fourRowsTall: CGFloat = 368

    /// Dragging past the end of the content does not regrade the rows.
    ///
    /// An overscroll is common-mode motion: every row moves by the same amount
    /// and none of them moves relative to another. But a weight is a distance
    /// from the anchor, and the anchor was a viewport edge — so the distance
    /// every weight was measured from grew as the rubber band stretched and
    /// shrank as it returned, turning motion with no differential in it into a
    /// differential.
    ///
    /// Measured on a device: through the return, the top row parted from a
    /// rigid slab of the other three in exact linear proportion to the offset,
    /// slope `−maximumStretch / resistanceFactor`, reproduced across three
    /// separate gestures to under a fifth of a pixel. Nothing about a spring
    /// is a straight line in the offset. It was the anchor sliding back onto
    /// the content.
    @Test
    @MainActor
    func overscrollDoesNotRegradeTheRows() {
        func topRowLag(overscrolledBy overscroll: CGFloat) -> CGFloat {
            var spring = ListScrollSpring()
            for _ in 0 ..< 30 {
                spring.willUpdate(Self.context(
                    viewportTop: -overscroll,
                    contentHeight: 1800,
                    scrollDelta: 10
                ))
            }
            return spring.displacement(forRowCenteredAt: Self.firstRowCentre)
        }

        let unstretched = topRowLag(overscrolledBy: 0)
        #expect(unstretched > 0, "the first row should lag at all")
        for overscroll in [CGFloat(20), 60, 150, 400] {
            let lag = topRowLag(overscrolledBy: overscroll)
            #expect(
                abs(lag - unstretched) < 0.01,
                "\(overscroll)pt of overscroll moved the first row's lag to \(lag) from \(unstretched)"
            )
        }
    }

    /// A list too short to fill its own viewport still spreads.
    ///
    /// The viewport's far edge can sit hundreds of points past the last row,
    /// and every weight measured from out there saturates alike, so the
    /// stretch came out as a rigid translation of the whole list — the effect
    /// switched itself off on exactly the lists it is easiest to see it on.
    @Test
    @MainActor
    func aListShorterThanItsViewportStillSpreads() {
        var spring = ListScrollSpring()
        for _ in 0 ..< 30 {
            spring.willUpdate(Self.context(
                viewportTop: -100,
                contentHeight: Self.fourRowsTall,
                scrollDelta: -10
            ))
        }
        #expect(spring.stretch < 0)

        let first = spring.displacement(forRowCenteredAt: Self.firstRowCentre)
        let last = spring.displacement(forRowCenteredAt: Self.lastRowCentre)
        #expect(
            abs(first - last) > 1,
            "every row read the same weight: the list moved rigidly, by \(first)"
        )
    }

    @Test
    func resetLeavesNothingBehind() {
        var spring = ListScrollSpring()
        spring.advance(scrollDelta: 24, deltaTime: Self.frame, anchorY: 0)
        #expect(spring.stretch != 0)

        spring.reset()
        #expect(spring.stretch == 0)
        #expect(spring.isAtRest)
        #expect(spring.displacement(forRowCenteredAt: 900) == 0)
    }

    // MARK: - Configuration

    /// Every invariant above has to hold for parameters that came from a
    /// caller rather than from the defaults.
    @Test
    func invalidParametersDoNotBreakAnyInvariant() {
        let hostile: [ListScrollSpring] = [
            ListScrollSpring(maximumStretch: 0),
            ListScrollSpring(maximumStretch: -50),
            ListScrollSpring(maximumStretch: .nan),
            ListScrollSpring(maximumStretch: .infinity),
            ListScrollSpring(resistanceFactor: 0),
            ListScrollSpring(resistanceFactor: -1),
            ListScrollSpring(resistanceFactor: .nan),
            ListScrollSpring(angularFrequency: 0),
            ListScrollSpring(angularFrequency: -30),
            ListScrollSpring(angularFrequency: .nan),
            ListScrollSpring(dampingRatio: 0),
            ListScrollSpring(dampingRatio: -1),
            ListScrollSpring(dampingRatio: .nan),
            ListScrollSpring(
                maximumStretch: .nan,
                resistanceFactor: .nan,
                angularFrequency: .nan,
                dampingRatio: .nan
            ),
        ]

        var noise = Noise(seed: 23)
        for var spring in hostile {
            let budget = spring.maximumStretch
            #expect(budget.isFinite)
            #expect(spring.resistanceFactor.isFinite && spring.resistanceFactor > 0)
            #expect(spring.angularFrequency.isFinite && spring.angularFrequency > 0)
            #expect(spring.dampingRatio.isFinite && spring.dampingRatio > 0)

            for _ in 0 ..< 500 {
                spring.advance(
                    scrollDelta: noise.next(in: -400 ... 400),
                    deltaTime: Self.frame,
                    anchorY: noise.next(in: -500 ... 500)
                )
                #expect(spring.stretch.isFinite)
                var previous = -CGFloat.greatestFiniteMagnitude
                for center in Self.rowCenters {
                    let displaced = spring.displacement(forRowCenteredAt: center)
                    #expect(displaced.isFinite)
                    #expect(abs(displaced) <= budget + 1e-9)
                    #expect(displaced >= previous - 1e-9)
                    previous = displaced
                }
            }
        }
    }

    /// Assigning a bad value after construction has to be caught too.
    @Test
    func mutatingParametersIsValidatedAsWell() {
        var spring = ListScrollSpring()
        spring.maximumStretch = .nan
        spring.resistanceFactor = -5
        spring.angularFrequency = 100_000
        spring.dampingRatio = .infinity

        #expect(spring.maximumStretch == 20)
        #expect(spring.resistanceFactor == 1)
        #expect(spring.angularFrequency == 500)
        #expect(spring.dampingRatio == 0.75)
    }

    /// A zero budget is the off switch, and it has to be free of residue.
    @Test
    func aZeroBudgetDisplacesNothing() {
        var spring = ListScrollSpring(maximumStretch: 0)
        for _ in 0 ..< 100 {
            spring.advance(scrollDelta: 300, deltaTime: Self.frame, anchorY: 0)
            #expect(spring.stretch == 0)
            #expect(spring.isAtRest)
            for center in Self.rowCenters {
                #expect(spring.displacement(forRowCenteredAt: center) == 0)
            }
        }
    }

    // MARK: - Shape

    /// The near side of the anchor cannot move: there is no gap there to take.
    @Test
    func onlyTheFarSideOfTheAnchorLags() {
        var spring = ListScrollSpring()
        spring.advance(scrollDelta: 24, deltaTime: Self.frame, anchorY: 0)
        #expect(spring.stretch > 0)
        #expect(spring.displacement(forRowCenteredAt: -500) == 0)
        #expect(spring.displacement(forRowCenteredAt: 500) > 0)

        spring.reset()
        spring.advance(scrollDelta: -24, deltaTime: Self.frame, anchorY: 0)
        #expect(spring.stretch < 0)
        #expect(spring.displacement(forRowCenteredAt: 500) == 0)
        #expect(spring.displacement(forRowCenteredAt: -500) < 0)
    }

    @Test
    func lagGrowsWithDistanceUntilItSaturates() {
        var spring = ListScrollSpring(resistanceFactor: 500)
        spring.advance(scrollDelta: 24, deltaTime: Self.frame, anchorY: 0)
        let full = spring.stretch

        #expect(spring.displacement(forRowCenteredAt: 0) == 0)
        #expect(abs(spring.displacement(forRowCenteredAt: 250) - full / 2) < 1e-9)
        #expect(abs(spring.displacement(forRowCenteredAt: 500) - full) < 1e-9)
        #expect(abs(spring.displacement(forRowCenteredAt: 5000) - full) < 1e-9)
    }
}
