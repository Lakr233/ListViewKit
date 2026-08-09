//
//  ListScrollSpring.swift
//  ListViewKit
//

import Foundation
import SpringInterpolation

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#else
    #error("ListViewKit requires UIKit or AppKit")
#endif

/// The elastic lag rows show while the list scrolls, as a pure model.
///
/// One spring, not one per row. Its value is a single scalar — how far the
/// content is currently stretched, in points — and every row reads the same
/// one through a weight that grows with its distance from the anchor. Rows
/// therefore cannot argue with each other about how far the list has moved,
/// and a row that scrolls in already knows where it belongs; there is no
/// per-row state to seed, migrate on reuse, or tear down.
///
/// The weight is one-sided. Rows on the anchor's far side lag; rows on the
/// near side sit still. That is not a stylistic choice — rows are laid out
/// edge to edge, so there is no gap between them to close. Displacement can
/// only ever open one, and letting both sides move would mean pushing rows
/// into each other.
///
/// Nothing here knows about views, frames, or time sources. It takes a scroll
/// delta and a duration and answers, for a row centred anywhere, how far that
/// row should be displaced.
///
/// Not `Sendable`: the `SpringInterpolation` it stores does not conform.
struct ListScrollSpring: Equatable {
    /// How far the content may stretch, in points.
    ///
    /// This bounds the displacement of every row, so it is also what the list
    /// has to overscan its mounting rectangle by.
    var maximumStretch: CGFloat {
        didSet { maximumStretch = Self.validate(maximumStretch, in: 0 ... 200, default: 24) }
    }

    /// The distance from the anchor, in points, at which a row lags by the
    /// full ``maximumStretch``.
    ///
    /// Larger values spread the falloff over more rows, which reads as a
    /// stiffer sheet; smaller values concentrate it near the anchor.
    var resistanceFactor: CGFloat {
        didSet { resistanceFactor = Self.validate(resistanceFactor, in: 1 ... 10000, default: 500) }
    }

    /// How quickly the stretch returns to zero, in radians per second.
    var angularFrequency: Double {
        didSet {
            angularFrequency = Self.validate(angularFrequency, in: 1 ... 500, default: 60)
            spring.config.angularFrequency = angularFrequency
        }
    }

    /// Below 1 the stretch overshoots zero and comes back; at 1 it settles
    /// without crossing.
    var dampingRatio: Double {
        didSet {
            dampingRatio = Self.validate(dampingRatio, in: 0.1 ... 5, default: 1)
            spring.config.dampingRatio = dampingRatio
        }
    }

    /// Stretch below this, with velocity below ``restingVelocity``, is
    /// indistinguishable from rest at any scale factor a display has.
    private static var restingStretch: CGFloat { 0.05 }
    /// Points per second.
    private static var restingVelocity: Double { 0.5 }

    private var spring: SpringInterpolation
    private var anchorY: CGFloat = 0

    init(
        maximumStretch: CGFloat = 24,
        resistanceFactor: CGFloat = 500,
        angularFrequency: Double = 60,
        dampingRatio: Double = 1
    ) {
        self.maximumStretch = Self.validate(maximumStretch, in: 0 ... 200, default: 24)
        self.resistanceFactor = Self.validate(resistanceFactor, in: 1 ... 10000, default: 500)
        self.angularFrequency = Self.validate(angularFrequency, in: 1 ... 500, default: 60)
        self.dampingRatio = Self.validate(dampingRatio, in: 0.1 ... 5, default: 1)
        // The library's own threshold snaps the value to the target, which at
        // a fast zero crossing would be a dead stop. Rest is decided here
        // instead, on the velocity as well as the value.
        spring = SpringInterpolation(
            config: .init(
                angularFrequency: self.angularFrequency,
                dampingRatio: self.dampingRatio,
                threshold: 0,
                stopWhenHitTarget: false
            )
        )
    }

    // MARK: - State

    /// How far the content is stretched right now, in points. Signed: positive
    /// means rows below the anchor have fallen behind.
    var stretch: CGFloat { CGFloat(spring.value) }

    /// Whether the spring has nothing left to do.
    ///
    /// `SpringInterpolation.completed` compares the value against the target
    /// and ignores the velocity, so it reads as true for the one frame a fast
    /// spring spends crossing zero. Sampling that to decide whether to keep a
    /// display link alive would cut the animation off mid-flight.
    var isAtRest: Bool {
        abs(spring.value) <= Double(Self.restingStretch)
            && abs(spring.context.currentVel) <= Self.restingVelocity
    }

    // MARK: - Integration

    /// Feeds one frame of scrolling in and advances the spring by `deltaTime`.
    ///
    /// - Parameters:
    ///   - scrollDelta: Visible scroll travel this frame, in points, with
    ///     compensation already subtracted. The list owes the model a delta
    ///     that corresponds to something the reader saw move.
    ///   - deltaTime: Already clamped by the caller. A long frame integrated
    ///     literally would overshoot.
    ///   - anchorY: Where the stretch is zero, in content coordinates.
    mutating func advance(scrollDelta: CGFloat, deltaTime: TimeInterval, anchorY: CGFloat) {
        self.anchorY = anchorY
        guard maximumStretch > 0 else {
            spring.setCurrent(0, 0)
            return
        }

        // The delta goes in whole. An earlier draft also capped it at
        // `maximumStretch` per frame, on the theory that a fling would
        // otherwise land as a jump. It would not: the clamp below bounds the
        // state, and a one-sided weight means no row ever reads a value of
        // both signs, so a row's displacement already cannot move further
        // than the budget in one frame. Injecting a huge delta and injecting
        // a capped one both saturate. The cap was defending an invariant that
        // holds without it.
        spring.setCurrent(spring.value + Double(scrollDelta), spring.context.currentVel)
        spring.setTarget(0)
        spring.update(withDeltaTime: deltaTime)

        // Clamping only what the rows read would leave the spring holding a
        // value it never has to pay back, and it would keep unwinding long
        // after the rows stopped moving. The clamp belongs in the state.
        if abs(spring.value) > Double(maximumStretch) {
            spring.setCurrent(Double(maximumStretch) * (spring.value < 0 ? -1 : 1), 0)
        }
        if isAtRest { spring.setCurrent(0, 0) }
    }

    /// Moves the stored anchor with the content coordinate space.
    ///
    /// Compensation shifts the offset so rows above it can resize without
    /// visible motion. The rows do not move, but the space they are addressed
    /// in does, and the anchor is a coordinate in it.
    mutating func rebase(byContentOffset delta: CGFloat) {
        anchorY += delta
    }

    mutating func reset() {
        spring.setCurrent(0, 0)
        spring.setTarget(0)
        anchorY = 0
    }

    // MARK: - Displacement

    /// How far to displace a row whose centre sits at `center`.
    ///
    /// The map from a row's position to its displaced position is
    /// non-decreasing — slope `1` on the near side of the anchor and
    /// `1 + |stretch| / resistanceFactor` on the far side — so rows that were
    /// laid out edge to edge stay in order and never overlap, whatever their
    /// heights are.
    func displacement(forRowCenteredAt center: CGFloat) -> CGFloat {
        let stretch = stretch
        guard stretch != 0 else { return 0 }
        let offsetFromAnchor = center - anchorY
        // Rows on the near side have nowhere to go: there is no gap between
        // them to take up.
        guard offsetFromAnchor.sign == stretch.sign else { return 0 }
        let weight = min(1, abs(offsetFromAnchor) / resistanceFactor)
        return stretch * weight
    }

    // MARK: - Validation

    /// Keeps a value inside the range the model is defined on.
    ///
    /// These are public knobs in the end, and a spring configured with a
    /// negative frequency or a `NaN` factor does not misbehave gracefully: it
    /// propagates the `NaN` into every row frame on the next pass.
    private static func validate<T: BinaryFloatingPoint>(
        _ value: T,
        in range: ClosedRange<T>,
        default fallback: T
    ) -> T {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Stated in an extension rather than on the type: conforming to a
/// main-actor protocol at the declaration would infer that isolation for the
/// whole type, and the model is meant to be usable — and testable — without
/// one.
extension ListScrollSpring: ListRowAnimator {
    var maximumDisplacement: CGFloat { maximumStretch }
    var wantsNextFrame: Bool { !isAtRest }

    mutating func willUpdate(_ context: ListAnimatorContext) {
        advance(
            scrollDelta: context.scrollDelta,
            deltaTime: context.deltaTime,
            anchorY: restingEdge(of: context.viewportRect, delta: context.scrollDelta)
        )
    }

    @MainActor
    func update(row: ListRowView, at _: Int, frame: CGRect, in _: ListAnimatorContext) {
        row.setPresentationOffset(displacement(forRowCenteredAt: frame.midY))
    }

    /// Where the stretch is zero.
    ///
    /// Displacement is one-sided, so only rows on the far side of this move.
    /// Anchoring at the edge the content is receding from puts every visible
    /// row on that side, which is what makes the whole viewport spread rather
    /// than half of it. The stretch in hand decides which edge that is; the
    /// incoming travel only matters on the frame the motion starts.
    private func restingEdge(of viewport: CGRect, delta: CGFloat) -> CGFloat {
        let direction = stretch != 0 ? stretch : delta
        return direction >= 0 ? viewport.minY : viewport.maxY
    }
}
