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
/// scroll has run ahead of the content, in points — and every row reads the
/// same one through a weight that grows with its distance above the anchor.
/// Rows therefore cannot argue with each other about how far the list has
/// moved, and a row that scrolls in already knows where it belongs; there is
/// no per-row state to seed, migrate on reuse, or tear down.
///
/// The anchor is the reader's grip — the touch or pointer — not a content
/// edge. The held row moves rigidly with the scroll; everything else trails
/// behind it, by more the further from the grip it sits, the way a sheet
/// dragged from a point hangs from where it is held. Dragging down opens the
/// gaps above the grip while the rows below bunch toward it; the other
/// direction mirrors it; rest restores the spacing. The grip itself is
/// measured behaviour — a frame-by-frame trace of Messages grades the spread
/// by distance from the pointer, over hundreds of points, opening some gaps
/// and closing others as the direction changes.
///
/// The weight is deliberately not one-sided in the stretch: a reversal drives
/// the scalar smoothly through zero and every row follows it, which is what
/// catching a moving list looks like. An earlier version gated displacement on
/// the sign of the stretch so rows could never close a gap; the gate collapsed
/// the whole field to zero on the frame a direction changed, which read as a
/// pop, and the trace shows Messages closing gaps below rest all the time.
/// Compression is bounded instead, by the slope: adjacent rows approach each
/// other by at most `maximumStretch / resistanceFactor` of their separation,
/// which the defaults put under 2%.
///
/// Nothing here knows about views, frames, or time sources. It takes a scroll
/// delta and a duration and answers, for a row centred anywhere, how far that
/// row should be displaced.
///
/// Not `Sendable`: the `SpringInterpolation` it stores does not conform.
public struct ListScrollSpring: Equatable {
    /// How far a row may trail the scroll, in points.
    ///
    /// This bounds the displacement of every row, so it is also what the list
    /// has to overscan its mounting rectangle by.
    public var maximumStretch: CGFloat {
        didSet { maximumStretch = Self.validate(maximumStretch, in: 0 ... 200, default: 15) }
    }

    /// The distance from the anchor, in points, at which a row trails by the
    /// full ``maximumStretch``.
    ///
    /// Larger values spread the falloff over more rows, which reads as a
    /// stiffer sheet; smaller values concentrate it near the grip. The default
    /// grades across a whole viewport, so every visible gap takes a share of
    /// the spread rather than the nearest one taking all of it.
    ///
    /// Displacement grades over `max(resistanceFactor, maximumStretch)`, so no
    /// configuration can make the falloff steeper than 1:1 — which is the
    /// slope at which adjacent rows could meet.
    public var resistanceFactor: CGFloat {
        didSet { resistanceFactor = Self.validate(resistanceFactor, in: 1 ... 10000, default: 800) }
    }

    /// How quickly the stretch returns to zero, in radians per second.
    public var angularFrequency: Double {
        didSet {
            angularFrequency = Self.validate(angularFrequency, in: 1 ... 500, default: 20)
            spring.config.angularFrequency = angularFrequency
        }
    }

    /// Below 1 the stretch overshoots zero and comes back; at 1 it settles
    /// without crossing.
    public var dampingRatio: Double {
        didSet {
            dampingRatio = Self.validate(dampingRatio, in: 0.1 ... 5, default: 0.75)
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

    public init(
        maximumStretch: CGFloat = 15,
        resistanceFactor: CGFloat = 800,
        angularFrequency: Double = 20,
        dampingRatio: Double = 0.75
    ) {
        self.maximumStretch = Self.validate(maximumStretch, in: 0 ... 200, default: 15)
        self.resistanceFactor = Self.validate(resistanceFactor, in: 1 ... 10000, default: 800)
        self.angularFrequency = Self.validate(angularFrequency, in: 1 ... 500, default: 20)
        self.dampingRatio = Self.validate(dampingRatio, in: 0.1 ... 5, default: 0.75)
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

    /// How far the scroll has run ahead of the far field right now, in points.
    /// Signed: positive means the content moved up and the rows above the
    /// anchor are hanging behind, below their placement.
    public var stretch: CGFloat { CGFloat(spring.value) }

    /// Whether the spring has nothing left to do.
    ///
    /// `SpringInterpolation.completed` compares the value against the target
    /// and ignores the velocity, so it reads as true for the one frame a fast
    /// spring spends crossing zero. Sampling that to decide whether to keep a
    /// display link alive would cut the animation off mid-flight.
    public var isAtRest: Bool {
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
    ///   - anchorY: The reader's grip, in the space the row frames are stated
    ///     in. Weights are distances from this point.
    public mutating func advance(scrollDelta: CGFloat, deltaTime: TimeInterval, anchorY: CGFloat) {
        self.anchorY = anchorY
        guard maximumStretch > 0 else {
            spring.setCurrent(0, 0)
            return
        }

        // The delta goes in whole. An earlier draft also capped it at
        // `maximumStretch` per frame, on the theory that a fling would
        // otherwise land as a jump. It would not: the clamp below bounds the
        // state, and a weight is a fraction of the scalar, so a row's
        // displacement already cannot move further than twice the budget in
        // one frame — and only a full-budget reversal inside a single frame
        // reaches that. Injecting a huge delta and injecting a capped one
        // both saturate. The cap was defending an invariant that holds
        // without it.
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
    public mutating func rebase(byContentOffset delta: CGFloat) {
        anchorY += delta
    }

    public mutating func reset() {
        spring.setCurrent(0, 0)
        spring.setTarget(0)
        anchorY = 0
    }

    // MARK: - Displacement

    /// How far to displace a row whose centre sits at `center`.
    ///
    /// Zero at the anchor, growing linearly with distance on *both* sides of
    /// it, saturating at ``resistanceFactor``. Both sides trail in the same
    /// direction — behind the motion — so the field flows around the grip:
    /// dragging the content down opens the gaps above the held row while the
    /// rows below bunch toward it, and the reverse direction mirrors it. An
    /// earlier version kept the near side rigid, which amputated half the
    /// effect: with nothing opening on the other side of the grip, one
    /// direction of every drag read as the whole screen shrinking.
    ///
    /// The map from placed position to displaced position has slope within
    /// `1 ± maximumStretch / resistanceFactor`, so rows that were laid out
    /// edge to edge keep their order whatever their heights are.
    public func displacement(forRowCenteredAt center: CGFloat) -> CGFloat {
        let stretch = stretch
        guard stretch != 0 else { return 0 }
        let weight = min(1, abs(anchorY - center) / max(resistanceFactor, maximumStretch))
        return stretch * weight
    }

    // MARK: - Presets

    /// The iMessage feel, fitted to recordings of Messages rather than derived.
    ///
    /// The relaxation comes from two gaps tracked frame by frame and fitted to
    /// a second-order response — ω ≈ 19–21, ζ ≈ 0.6–0.75, peak spread 12–16pt.
    /// The shape comes from a per-element trace of the same footage: rigid at
    /// and below the pointer, graded above it over the height of the viewport,
    /// with gaps closing as well as opening. See §2.5 and §9 of the design
    /// document for the measurements.
    public static var messages: Self { .init() }

    /// The same idea at half the volume, for lists where the effect should be
    /// felt rather than seen.
    public static var subtle: Self {
        .init(maximumStretch: 8, resistanceFactor: 1200, angularFrequency: 26, dampingRatio: 0.9)
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
    public var maximumDisplacement: CGFloat { maximumStretch }
    public var wantsNextFrame: Bool { !isAtRest }

    public mutating func willUpdate(_ context: ListAnimatorContext) {
        advance(
            scrollDelta: context.scrollDelta,
            deltaTime: context.deltaTime,
            anchorY: context.interactionAnchorY
        )
    }

    @MainActor
    public func update(row: ListRowView, at _: Int, frame: CGRect, in _: ListAnimatorContext) {
        row.setPresentationOffset(displacement(forRowCenteredAt: frame.midY))
    }
}
