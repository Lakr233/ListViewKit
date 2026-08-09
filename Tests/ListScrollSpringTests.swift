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
    /// The point of the frequency is that ordinary scrolling lands inside the
    /// budget, where rows fall behind by graded amounts, and only a fling
    /// saturates, where they all lag by the same 24pt and the effect flattens
    /// out. A frequency low enough to saturate at reading speed would throw
    /// the whole gradient away.
    @Test
    func ordinaryScrollingStaysInsideTheBudgetAndFlingsSaturate() {
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

        #expect(steadyStretch(scrollingAt: 300, hz: 120) < 12)
        #expect(steadyStretch(scrollingAt: 600, hz: 120) < 20)
        #expect(steadyStretch(scrollingAt: 2400, hz: 120) == 24)
        // Monotone in speed, so the effect reads as speed.
        #expect(steadyStretch(scrollingAt: 300, hz: 120) < steadyStretch(scrollingAt: 600, hz: 120))
    }

    /// Steady stretch depends on the frame rate, and the paper figure is an
    /// upper bound rather than the answer.
    ///
    /// Injecting a per-frame delta into a discrete relaxation under-relaxes,
    /// by more at 60 Hz than at 120 Hz: `2ζv/ω` predicts 20pt for 600pt/s at
    /// the defaults, and the model gives 17.5pt at 120 Hz and 15.0pt at 60 Hz.
    /// The gap is small enough to leave alone — the same gesture is ~14%
    /// slacker on a 60 Hz display — but not small enough to discover by
    /// accident later.
    @Test
    func steadyStretchIsFrameRateDependentByAKnownAmount() {
        func ratioToContinuousLimit(hz: Double) -> CGFloat {
            var spring = ListScrollSpring()
            let deltaTime = 1.0 / hz
            let velocity: CGFloat = 600
            for _ in 0 ..< 3000 {
                spring.advance(
                    scrollDelta: velocity * CGFloat(deltaTime),
                    deltaTime: deltaTime,
                    anchorY: 0
                )
            }
            return spring.stretch / (2 * velocity / CGFloat(spring.angularFrequency))
        }

        #expect(abs(ratioToContinuousLimit(hz: 120) - 0.875) < 0.01)
        #expect(abs(ratioToContinuousLimit(hz: 60) - 0.751) < 0.01)
        #expect(ratioToContinuousLimit(hz: 60) < ratioToContinuousLimit(hz: 120))
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

        #expect(spring.maximumStretch == 24)
        #expect(spring.resistanceFactor == 1)
        #expect(spring.angularFrequency == 500)
        #expect(spring.dampingRatio == 1)
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
