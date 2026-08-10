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
            spring.advance(scrollDelta: spring.maximumStretch, deltaTime: deltaTime, anchorY: 0)

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
            // At ζ = 0.2 the first rebound carries just over half the peak.
            #expect(peakAfterFirstCrossing > spring.maximumStretch * 0.4, "no swing left after the first crossing")
            #expect(spring.isAtRest)
        }
    }

    /// What a plausible scroll speed actually stretches by.
    ///
    /// This pinned the opposite claim while the frequency was paper-derived:
    /// that ordinary scrolling stays inside the budget and only a fling
    /// saturates. Measuring Messages retired it. At the fitted ω the stretch
    /// reaches the budget from roughly 235pt/s up, and the recordings agree —
    /// through every flick the far field's spread held its ceiling, and what
    /// varied between gestures was how long it stayed there, not how big it
    /// got.
    ///
    /// Since the pump's gain dies quadratically as the stretch fills, the
    /// budget is an asymptote rather than a wall: every speed reads a little
    /// differently, and nothing ever parks exactly on the cap. The corner
    /// that a hard cap put in the row's *velocity* — still, still, still,
    /// then moving at the finger's speed in one frame — was the measured
    /// "two-stage" complaint, and the asymptote is what removed it.
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

        #expect(steadyStretch(scrollingAt: 100, hz: 120) < 12)
        #expect(steadyStretch(scrollingAt: 150, hz: 120) < 17)
        // Measured: 24.8 / 28.1 / 30.0 — climbing the asymptote, never on it.
        #expect((20.0 ... 31.9).contains(steadyStretch(scrollingAt: 600, hz: 120)))
        #expect(steadyStretch(scrollingAt: 2400, hz: 120) < 32)
        // Monotone everywhere now, so every speed still reads as speed.
        #expect(steadyStretch(scrollingAt: 100, hz: 120) < steadyStretch(scrollingAt: 150, hz: 120))
        #expect(steadyStretch(scrollingAt: 150, hz: 120) < steadyStretch(scrollingAt: 600, hz: 120))
        #expect(steadyStretch(scrollingAt: 600, hz: 120) < steadyStretch(scrollingAt: 2400, hz: 120))
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

        #expect(abs(ratioToContinuousLimit(hz: 120) - 0.879) < 0.01)
        #expect(abs(ratioToContinuousLimit(hz: 60) - 0.848) < 0.01)
        #expect(ratioToContinuousLimit(hz: 60) < ratioToContinuousLimit(hz: 120))
    }

    /// The relaxation the defaults are tuned to.
    ///
    /// The Messages fits (two gestures, least-squares against a second-order
    /// response) landed at ω ≈ 19–21 with half-lives of 64–68ms; the default
    /// is deliberately slower — ω = 14, asked for by feel: the rows should
    /// take their time catching the scroll back up. Everything scales by the
    /// ratio, so the pins are the fitted curve stretched by 20/14: half-life
    /// ~117ms, a tenth by ~200ms, and the same barely-there undershoot that
    /// keeps ζ at 0.75.
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

        #expect((100.0 ... 135.0).contains(milliseconds(toReach: 0.5)), "half-life \(milliseconds(toReach: 0.5))ms")
        #expect((170.0 ... 240.0).contains(milliseconds(toReach: 0.1)), "tenth at \(milliseconds(toReach: 0.1))ms")
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

    /// Rows are translated rigidly, so they can approach each other — the
    /// Messages trace closes gaps below rest all the time — but only by the
    /// falloff's slope, which the defaults keep under 2% of the rows'
    /// separation. What must never happen is the order changing.
    @Test
    func rowsApproachEachOtherByAtMostTheFalloffSlope() {
        var noise = Noise(seed: 11)
        var spring = ListScrollSpring()
        let slope = spring.steepestFalloffSlope
        for _ in 0 ..< 4000 {
            spring.advance(
                scrollDelta: noise.next(in: -300 ... 300),
                deltaTime: Self.frame,
                anchorY: noise.next(in: -800 ... 800)
            )
            var previousCenter = Self.rowCenters[0]
            var previousDisplaced = spring.displacement(forRowCenteredAt: previousCenter)
            for center in Self.rowCenters.dropFirst() {
                let displaced = spring.displacement(forRowCenteredAt: center)
                let separation = center - previousCenter
                // Interpenetration bounded by the slope…
                #expect(previousDisplaced - displaced <= separation * slope + 1e-9)
                // …and the centres keep their order outright.
                #expect(center + displaced > previousCenter + previousDisplaced)
                previousCenter = center
                previousDisplaced = displaced
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
        let slope = spring.steepestFalloffSlope
        for _ in 0 ..< 2000 {
            spring.advance(
                scrollDelta: noise.next(in: -300 ... 300),
                deltaTime: Self.frame,
                anchorY: noise.next(in: -200 ... 4200)
            )
            var previousCenter = -CGFloat.greatestFiniteMagnitude
            var previousDisplacedCenter = -CGFloat.greatestFiniteMagnitude
            for (top, height) in zip(tops, heights) {
                let center = top + height / 2
                let displacedCenter = center + spring.displacement(forRowCenteredAt: center)
                // Centres in order, and rows into each other by no more than
                // the slope of the falloff.
                #expect(displacedCenter >= previousDisplacedCenter - 1e-9)
                #expect(
                    previousDisplacedCenter - displacedCenter
                        <= (center - previousCenter) * slope + 1e-9
                )
                previousCenter = center
                previousDisplacedCenter = displacedCenter
            }
        }
    }

    // MARK: - Continuity

    /// A reversal rides the spring through zero instead of collapsing it.
    ///
    /// The first version gated displacement on the sign of the stretch, so the
    /// frame a direction changed zeroed every row at once — measured on a
    /// device as a 12px gap snapping shut between two frames. Catching a
    /// moving list is input like any other: the stretch shrinks by what the
    /// finger feeds in, and everything the rows do stays continuous in it.
    @Test
    func aReversalRidesThroughZeroInsteadOfSnapping() {
        // The wave is a spatial shape and this is a temporal claim: pinning
        // the saturated value needs the plain ramp.
        var spring = ListScrollSpring(unevenness: 0)
        // A firm scroll, saturated.
        for _ in 0 ..< 30 {
            spring.advance(scrollDelta: 8, deltaTime: Self.frame, anchorY: 1000)
        }
        let farRow: CGFloat = 0 // 1000pt above the grip: reads the whole stretch
        let saturated = spring.displacement(forRowCenteredAt: farRow)
        // The soft pump approaches the budget instead of parking on it.
        #expect(saturated > spring.maximumStretch * 0.8)

        // Caught and dragged the other way at the same speed.
        var previous = saturated
        var signChangeFrame: Int?
        for frame in 0 ..< 30 {
            spring.advance(scrollDelta: -8, deltaTime: Self.frame, anchorY: 1000)
            let displaced = spring.displacement(forRowCenteredAt: farRow)
            // Each frame moves the row by what the finger fed in plus what the
            // spring relaxed — bounded, not a collapse.
            #expect(abs(displaced - previous) < 12, "jumped \(previous) → \(displaced) in one frame")
            if signChangeFrame == nil, displaced < 0 { signChangeFrame = frame }
            previous = displaced
        }
        // It did cross — the other side is reachable — and not on the first
        // frame of the catch: the finger's own feed is smaller than the
        // saturated stretch, so an immediate flip could only be a collapse.
        let crossed = try! #require(signChangeFrame)
        #expect(crossed >= 1)
    }

    /// The most a row can move between two frames is out to the budget and
    /// back through it — a full-budget reversal — and that needs the whole
    /// reversal fed in within one frame.
    @Test
    func displacementChangesByAtMostTwiceTheBudgetInOneFrame() {
        var noise = Noise(seed: 17)
        var spring = ListScrollSpring(maximumStretch: 24)
        var previous = [CGFloat](repeating: 0, count: Self.rowCenters.count)

        for _ in 0 ..< 6000 {
            // Deltas big enough to slam between the clamps in one frame.
            spring.advance(
                scrollDelta: noise.next(in: -80 ... 80),
                deltaTime: Self.frame,
                anchorY: 0
            )
            for (offset, center) in Self.rowCenters.enumerated() {
                let displaced = spring.displacement(forRowCenteredAt: center)
                #expect(abs(displaced - previous[offset]) <= 48 + 1e-9)
                previous[offset] = displaced
            }
        }
    }

    // MARK: - Anchor

    @Test
    func rebaseMovesTheAnchorWithTheContentSpace() {
        var spring = ListScrollSpring()
        spring.advance(scrollDelta: 24, deltaTime: Self.frame, anchorY: 500)
        let before = spring.displacement(forRowCenteredAt: 300)
        #expect(before != 0, "the probe row has to be one the anchor grades")

        spring.rebase(byContentOffset: 500)
        #expect(spring.displacement(forRowCenteredAt: 800) == before)
    }

    /// A list, as the animator is handed one: rows from zero to `contentHeight`
    /// in a viewport whose top edge is wherever the reader has dragged it,
    /// held at `gripY`.
    private static func context(
        viewportTop: CGFloat,
        viewportHeight: CGFloat = 900,
        contentHeight: CGFloat,
        gripY: CGFloat,
        scrollDelta: CGFloat
    ) -> ListAnimatorContext {
        .init(
            viewportRect: CGRect(x: 0, y: viewportTop, width: 320, height: viewportHeight),
            contentRect: CGRect(x: 0, y: 0, width: 320, height: contentHeight),
            interactionAnchorY: gripY,
            scrollDelta: scrollDelta,
            deltaTime: frame,
            isUserInteracting: true
        )
    }

    /// The weights are distances from the reader's grip, and from nothing
    /// else. The first version anchored at a content edge clamped to the
    /// viewport, and both halves of that were measured failing on devices: the
    /// viewport edge regrades every weight as a rubber band unwinds — the top
    /// row parted from the others in exact linear proportion to the offset,
    /// slope `−maximumStretch / resistanceFactor`, across three gestures —
    /// and the content edge is so far from a mid-list viewport that every
    /// visible row saturated alike, which is a rigid translation and no
    /// effect at all.
    @Test
    @MainActor
    func theAnchorIsTheReadersGripNotAContentEdge() {
        func lag(viewportTop: CGFloat, contentHeight: CGFloat) -> CGFloat {
            var spring = ListScrollSpring()
            for _ in 0 ..< 30 {
                spring.willUpdate(Self.context(
                    viewportTop: viewportTop,
                    contentHeight: contentHeight,
                    gripY: viewportTop + 800,
                    scrollDelta: 10
                ))
            }
            // 500pt above the grip, mid-falloff.
            return spring.displacement(forRowCenteredAt: viewportTop + 300)
        }

        let midList = lag(viewportTop: 5000, contentHeight: 20000)
        #expect(midList != 0, "the effect exists in the middle of a long list")
        // The same reading whether the viewport is at the top, the bottom,
        // overscrolled past either end, or the list is shorter than the
        // viewport — geometry the grip does not care about.
        #expect(lag(viewportTop: 0, contentHeight: 20000) == midList)
        #expect(lag(viewportTop: -150, contentHeight: 20000) == midList)
        #expect(lag(viewportTop: 19100, contentHeight: 20000) == midList)
        #expect(lag(viewportTop: -100, contentHeight: 368) == midList)
    }

    @Test
    func resetLeavesNothingBehind() {
        var spring = ListScrollSpring()
        spring.advance(scrollDelta: 24, deltaTime: Self.frame, anchorY: 1000)
        #expect(spring.stretch != 0)

        spring.reset()
        #expect(spring.stretch == 0)
        #expect(spring.isAtRest)
        #expect(spring.displacement(forRowCenteredAt: 0) == 0)
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
            ListScrollSpring(unevenness: .nan),
            ListScrollSpring(unevenness: -1),
            ListScrollSpring(unevenness: 100),
            // Legal one at a time and hostile together: a budget bigger than
            // the falloff distance would let rows swap outright if the slope
            // were not bounded at use.
            ListScrollSpring(maximumStretch: 200, resistanceFactor: 1),
            ListScrollSpring(maximumStretch: 200, resistanceFactor: 1, unevenness: 0.5),
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
                var previousCenter = Self.rowCenters[0]
                var previousDisplaced = Self.rowCenters[0]
                    + spring.displacement(forRowCenteredAt: Self.rowCenters[0])
                for center in Self.rowCenters.dropFirst() {
                    let displaced = spring.displacement(forRowCenteredAt: center)
                    #expect(displaced.isFinite)
                    #expect(abs(displaced) <= budget + 1e-9)
                    // Order survives any configuration: the falloff can never
                    // be steeper than 1:1.
                    #expect(center + displaced >= previousDisplaced - 1e-9)
                    previousCenter = center
                    previousDisplaced = center + displaced
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
        spring.unevenness = -3
        spring.returnDelay = .nan

        #expect(spring.maximumStretch == 32)
        #expect(spring.resistanceFactor == 1)
        #expect(spring.angularFrequency == 500)
        #expect(spring.dampingRatio == 0.75)
        #expect(spring.unevenness == 0)
        #expect(spring.returnDelay == 0.12)
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

    /// The held row is in the reader's hand and moves with it; everything
    /// else, on both sides, trails behind by distance. An earlier shape kept
    /// the near side rigid, and the complaint that retired it is exact: with
    /// nothing opening on the other side of the grip, one direction of every
    /// drag read as the whole screen shrinking, only recovering on release.
    @Test
    func theRowAtTheGripStaysPutAndBothSidesTrail() {
        var spring = ListScrollSpring()
        spring.advance(scrollDelta: 24, deltaTime: Self.frame, anchorY: 0)
        #expect(spring.stretch > 0)
        #expect(spring.displacement(forRowCenteredAt: 0) == 0)
        // Both sides hang behind the same way. Not asserted equal: the
        // unevenness wave is deliberately asymmetric about the grip.
        let above = spring.displacement(forRowCenteredAt: -500)
        let below = spring.displacement(forRowCenteredAt: 500)
        #expect(above > 0 && below > 0)
        #expect(max(above, below) <= spring.stretch + 1e-9)
        #expect(min(above, below) >= spring.stretch * (1 - spring.unevenness) * min(1, 500 / spring.effectiveResistance) - 1e-9)
    }

    /// The spec, verbatim: rows 1–6, the finger dragging row 4. Sliding down,
    /// the gaps among 1-2-3 widen while 5-6 bunch toward the hand; sliding up
    /// mirrors it; rest restores the spacing. The signs are the whole test —
    /// which side opens is what an implementation gets wrong by symmetry.
    @Test
    func gapsOpenBehindTheMotionAndCloseAheadOfIt() {
        // Six rows, 100pt apart, the grip on the fourth.
        let centers: [CGFloat] = [0, 100, 200, 300, 400, 500]
        let grip = centers[3]

        func gaps(after delta: CGFloat, unevenness: CGFloat) -> [CGFloat] {
            var spring = ListScrollSpring(unevenness: unevenness)
            for _ in 0 ..< 10 {
                spring.advance(scrollDelta: delta, deltaTime: Self.frame, anchorY: grip)
            }
            let displaced = centers.map { $0 + spring.displacement(forRowCenteredAt: $0) }
            return zip(displaced, displaced.dropFirst()).map { $1 - $0 - 100 }
        }

        // Content dragged down (offset falling): 1-2, 2-3, 3-4 open; 4-5, 5-6
        // close — with the unevenness wave on and off alike: the wave may
        // redistribute the spread, never flip its direction.
        for unevenness in [CGFloat(0), 0.2, 0.5] {
            let down = gaps(after: -10, unevenness: unevenness)
            #expect(down[0] > 0 && down[1] > 0 && down[2] > 0, "gaps above the grip should widen: \(down)")
            #expect(down[3] < 0 && down[4] < 0, "gaps below the grip should bunch: \(down)")

            // The other way around, the mirror image.
            let up = gaps(after: 10, unevenness: unevenness)
            #expect(up[0] < 0 && up[1] < 0 && up[2] < 0, "gaps above the grip should bunch: \(up)")
            #expect(up[3] > 0 && up[4] > 0, "gaps below the grip should widen: \(up)")
        }

        // On the plain ramp, the furthest from the hand moves most.
        let down = gaps(after: -10, unevenness: 0)
        #expect(down[0] >= down[1] - 1e-6, "the spread grows with distance: \(down)")
        #expect(abs(down[4]) >= abs(down[3]) - 1e-6)

        // And rest restores the spacing.
        var spring = ListScrollSpring()
        for _ in 0 ..< 10 {
            spring.advance(scrollDelta: -10, deltaTime: Self.frame, anchorY: grip)
        }
        var frames = 0
        while !spring.isAtRest, frames < 2000 {
            spring.advance(scrollDelta: 0, deltaTime: Self.frame, anchorY: grip)
            frames += 1
        }
        for center in centers {
            #expect(spring.displacement(forRowCenteredAt: center) == 0)
        }
    }

    /// The gravity exists only under the hand.
    ///
    /// While the finger drags, travel feeds the spread; the moment it lifts,
    /// the spread smooths home even though momentum keeps delivering travel.
    /// Feeding the deceleration too was the first behaviour, and it read as
    /// the screen staying smeared for as long as the flick coasted.
    @Test
    @MainActor
    func liftingTheFingerSmoothsHomeThroughMomentum() {
        var spring = ListScrollSpring()
        func advance(delta: CGFloat, holding: Bool) {
            spring.willUpdate(.init(
                viewportRect: CGRect(x: 0, y: 0, width: 320, height: 900),
                contentRect: CGRect(x: 0, y: 0, width: 320, height: 5000),
                interactionAnchorY: 700,
                scrollDelta: delta,
                deltaTime: Self.frame,
                isUserInteracting: holding
            ))
        }

        for _ in 0 ..< 20 { advance(delta: 8, holding: true) }
        let held = spring.stretch
        #expect(held > 0, "a drag should build the spread")

        // The lift: momentum still delivers travel, and the spread pays
        // itself back — it may cross zero on the way (ζ = 0.75 undershoots by
        // a few percent) but it never exceeds what the hand left behind, and
        // it reaches rest while the travel is still flowing.
        //
        // The payback is an animation, not a snap: one frame after the lift
        // nearly all of the spread is still there. Zeroing it on release is
        // the pop this whole design exists to avoid.
        advance(delta: 8, holding: false)
        #expect(spring.stretch > held * 0.8, "the release snapped: \(held) -> \(spring.stretch) in one frame")
        var frames = 0
        while !spring.isAtRest, frames < 2000 {
            advance(delta: 8, holding: false)
            #expect(abs(spring.stretch) <= held + 1e-9, "the spread grew after the lift")
            frames += 1
        }
        #expect(spring.isAtRest)
        #expect(spring.stretch == 0)

        // Catching it again resumes from wherever the payback had reached.
        advance(delta: 8, holding: true)
        #expect(spring.stretch > 0)
    }

    /// The spec, verbatim again: after sliding and letting go, the messages
    /// ahead of the finger come back a beat later than the ones under it.
    ///
    /// The field is one scalar and springs home as one; the delay lives in
    /// per-row followers whose time constant grows with distance from the
    /// grip. So mid-payback the far row must be holding visibly more of its
    /// spread than the near row — and with ``ListScrollSpring/returnDelay``
    /// zeroed, the cascade is off and every row shows the field as it is.
    @Test
    @MainActor
    func theReturnRollsOutwardFromTheHand() {
        var spring = ListScrollSpring(unevenness: 0)
        func advance(delta: CGFloat, holding: Bool) {
            spring.willUpdate(.init(
                viewportRect: CGRect(x: 0, y: 0, width: 320, height: 900),
                contentRect: CGRect(x: 0, y: 0, width: 320, height: 5000),
                interactionAnchorY: 800,
                scrollDelta: delta,
                deltaTime: Self.frame,
                isUserInteracting: holding
            ))
        }
        let near: CGFloat = 650   // 150pt from the hand
        let far: CGFloat = 350    // 450pt: the full falloff away

        // A firm drag, long enough for every follower to reach its target.
        for _ in 0 ..< 120 {
            _ = advance(delta: 8, holding: true)
            _ = spring.followedDisplacement(forRowCenteredAt: near, key: 1)
            _ = spring.followedDisplacement(forRowCenteredAt: far, key: 2)
        }
        let nearHeld = spring.followedDisplacement(forRowCenteredAt: near, key: 1)
        let farHeld = spring.followedDisplacement(forRowCenteredAt: far, key: 2)
        #expect(farHeld > nearHeld, "the far row should carry more spread")

        // The lift. A beat later the near row has paid most of its spread
        // back while the far row still holds most of its own.
        var nearNow = nearHeld, farNow = farHeld
        for _ in 0 ..< 14 { // ~117ms at 120Hz
            advance(delta: 0, holding: false)
            nearNow = spring.followedDisplacement(forRowCenteredAt: near, key: 1)
            farNow = spring.followedDisplacement(forRowCenteredAt: far, key: 2)
        }
        // Measured: near ~0.36 of held, far ~0.72 — the beat between them.
        #expect(nearNow < nearHeld * 0.5, "the near row should be mostly home: \(nearNow) of \(nearHeld)")
        #expect(farNow > farHeld * 0.6, "the far row should still be on its way: \(farNow) of \(farHeld)")

        // And everyone gets home.
        for _ in 0 ..< 400 {
            advance(delta: 0, holding: false)
            nearNow = spring.followedDisplacement(forRowCenteredAt: near, key: 1)
            farNow = spring.followedDisplacement(forRowCenteredAt: far, key: 2)
        }
        #expect(nearNow == 0 && farNow == 0)
        #expect(spring.wantsNextFrame == false, "settled followers must let the link die")
    }

    /// The spec, verbatim: the row does not sit still and then snap into
    /// following — it accelerates into following. The smoothing lives in the
    /// velocity.
    ///
    /// Under a constant-speed drag the trailing row's per-frame step climbs
    /// from zero toward the finger's speed. What retired the hard cap is the
    /// corner it put here: the step ramped up and then dropped to zero in a
    /// single frame when the stretch hit the wall. The largest change of the
    /// step between consecutive frames is the size of that corner, and with
    /// the soft gain it stays under an eighth of the finger's own step.
    @Test
    func theRowAcceleratesIntoFollowingInsteadOfSnapping() {
        var spring = ListScrollSpring(unevenness: 0)
        let delta: CGFloat = 8
        var previous = spring.displacement(forRowCenteredAt: 0)
        var previousStep: CGFloat = 0
        var worstCorner: CGFloat = 0
        for frame in 0 ..< 120 {
            spring.advance(scrollDelta: delta, deltaTime: Self.frame, anchorY: 1000)
            let displaced = spring.displacement(forRowCenteredAt: 0)
            let step = displaced - previous
            if frame > 0 { worstCorner = max(worstCorner, abs(step - previousStep)) }
            previous = displaced
            previousStep = step
        }
        #expect(spring.stretch > spring.maximumStretch * 0.8, "premise: the drive reaches saturation territory")
        // The gentle early acceleration itself moves the step by ~1.2/frame;
        // the hard cap's corner measured ~3-5. The bound sits between them.
        #expect(worstCorner < delta / 4, "the row's velocity jumped by \(worstCorner) in one frame")
    }

    /// The spec, verbatim: momentum is continuous in direction. A follower
    /// whose target is yanked the other way keeps moving its own way for at
    /// least a frame — it carries velocity, it does not teleport its
    /// derivative.
    @Test
    @MainActor
    func aFollowerKeepsItsMomentumThroughAYank() {
        var spring = ListScrollSpring(unevenness: 0)
        func advance(delta: CGFloat) {
            spring.willUpdate(.init(
                viewportRect: CGRect(x: 0, y: 0, width: 320, height: 900),
                contentRect: CGRect(x: 0, y: 0, width: 320, height: 5000),
                interactionAnchorY: 800,
                scrollDelta: delta,
                deltaTime: Self.frame,
                isUserInteracting: true
            ))
        }
        let row: CGFloat = 350
        // Build motion: the follower is travelling outward.
        var displaced: CGFloat = 0
        for _ in 0 ..< 8 {
            advance(delta: 8)
            displaced = spring.followedDisplacement(forRowCenteredAt: row, key: 1)
        }
        var before = displaced
        advance(delta: 8)
        displaced = spring.followedDisplacement(forRowCenteredAt: row, key: 1)
        let outwardStep = displaced - before
        #expect(outwardStep > 0.1, "premise: the follower is moving outward")

        // The yank: a hard catch throws the field the other way.
        before = displaced
        advance(delta: -60)
        displaced = spring.followedDisplacement(forRowCenteredAt: row, key: 1)
        let firstStep = displaced - before
        #expect(firstStep > -0.05, "the follower reversed in the same frame as the yank: \(firstStep)")
    }

    /// A slow cascade outlives the field, and the link must outlive both.
    ///
    /// At the default delay the followers are sub-pixel by the time the field
    /// rests, so nothing shows if the link dies with it. At the knob's far
    /// end they are not: half a second of lag leaves points of visible spread
    /// still travelling when the field settles, and a link keyed to the field
    /// alone freezes them mid-air.
    @Test
    @MainActor
    func aSlowCascadeKeepsFramesComingAfterTheFieldRests() {
        var spring = ListScrollSpring(unevenness: 0, returnDelay: 0.5)
        func advance(delta: CGFloat, holding: Bool) {
            spring.willUpdate(.init(
                viewportRect: CGRect(x: 0, y: 0, width: 320, height: 900),
                contentRect: CGRect(x: 0, y: 0, width: 320, height: 5000),
                interactionAnchorY: 800,
                scrollDelta: delta,
                deltaTime: Self.frame,
                isUserInteracting: holding
            ))
        }
        for _ in 0 ..< 60 {
            advance(delta: 8, holding: true)
            _ = spring.followedDisplacement(forRowCenteredAt: 350, key: 2)
        }
        var frames = 0
        while !spring.isAtRest, frames < 2000 {
            advance(delta: 0, holding: false)
            _ = spring.followedDisplacement(forRowCenteredAt: 350, key: 2)
            frames += 1
        }
        let far = spring.followedDisplacement(forRowCenteredAt: 350, key: 2)
        #expect(abs(far) > 0.05, "premise: the slow follower outlives the field, held \(far)")
        #expect(spring.wantsNextFrame, "the far row is still travelling; frames are owed")
    }

    /// A row scrolling into a live spread is already part of it.
    @Test
    @MainActor
    func aRowTheFlowHasNeverSeenStartsOnTheFieldNotAtZero() {
        var spring = ListScrollSpring(unevenness: 0)
        for _ in 0 ..< 30 {
            spring.willUpdate(.init(
                viewportRect: CGRect(x: 0, y: 0, width: 320, height: 900),
                contentRect: CGRect(x: 0, y: 0, width: 320, height: 5000),
                interactionAnchorY: 800,
                scrollDelta: 8,
                deltaTime: Self.frame,
                isUserInteracting: true
            ))
        }
        let fresh = spring.followedDisplacement(forRowCenteredAt: 350, key: 99)
        #expect(fresh == spring.displacement(forRowCenteredAt: 350), "a fresh follower must seed on the field")
        #expect(fresh != 0)
    }

    /// The unevenness is real, bounded, and off when asked to be off.
    @Test
    func theWaveMakesNeighboursTrailUnevenly() {
        var wavy = ListScrollSpring()
        var even = ListScrollSpring(unevenness: 0)
        wavy.advance(scrollDelta: 100, deltaTime: Self.frame, anchorY: 0)
        even.advance(scrollDelta: 100, deltaTime: Self.frame, anchorY: 0)

        // Sampled beyond the falloff, where the ramp is flat: any variation
        // left is the wave's.
        let far = stride(from: -1000, through: -3000, by: -250).map { CGFloat($0) }
        let wavyReads = far.map { wavy.displacement(forRowCenteredAt: $0) }
        let evenReads = far.map { even.displacement(forRowCenteredAt: $0) }

        #expect(Set(evenReads).count == 1, "with the wave off the far field is one rigid sheet")
        #expect(Set(wavyReads).count > 3, "the far field should trail unevenly: \(wavyReads)")
        // The wave dips and never exceeds: the ramp is the ceiling.
        for (w, e) in zip(wavyReads, evenReads) {
            #expect(w <= e + 1e-9)
            #expect(w >= e * (1 - wavy.unevenness) - 1e-9)
        }
    }

    @Test
    func lagGrowsWithDistanceFromTheGripUntilItSaturates() {
        var spring = ListScrollSpring(resistanceFactor: 500, unevenness: 0)
        spring.advance(scrollDelta: 24, deltaTime: Self.frame, anchorY: 0)
        let full = spring.stretch

        #expect(spring.displacement(forRowCenteredAt: 0) == 0)
        for side in [CGFloat(-1), 1] {
            #expect(abs(spring.displacement(forRowCenteredAt: side * 250) - full / 2) < 1e-9)
            #expect(abs(spring.displacement(forRowCenteredAt: side * 500) - full) < 1e-9)
            #expect(abs(spring.displacement(forRowCenteredAt: side * 5000) - full) < 1e-9)
        }
    }
}
