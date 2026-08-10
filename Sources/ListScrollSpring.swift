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
        didSet { maximumStretch = Self.validate(maximumStretch, in: 0 ... 200, default: 32) }
    }

    /// How unevenly the rows trail, as a fraction of their own lag.
    ///
    /// Zero is a perfectly even ramp — every row at the same distance lags
    /// the same — and it reads mechanical, like the screen shearing as one
    /// sheet. Messages does not look like that: bubbles trail with visible
    /// individuality. This dips each row's lag by up to this fraction along a
    /// slow spatial wave, so neighbours stop moving in lockstep.
    ///
    /// A wave rather than randomness on purpose: it is deterministic in the
    /// row's distance from the grip, so a row's reading is stable from frame
    /// to frame — noise re-rolled per frame would shimmer — and it is smooth,
    /// so its gradient joins the falloff's in the ordering bound instead of
    /// breaking it.
    public var unevenness: CGFloat {
        didSet { unevenness = Self.validate(unevenness, in: 0 ... 0.5, default: 0.2) }
    }

    /// How long a row at the far end of the falloff trails the field, in
    /// seconds. Zero shows every row the field as it is.
    ///
    /// The field itself moves as one quantity, so without this the whole
    /// spread springs home in lockstep the moment the hand lifts. With it,
    /// each row follows the field through a lag that grows with its distance
    /// from the grip: the rows under the hand return first and the wave rolls
    /// outward — the "messages ahead of the finger come back a beat later"
    /// that the reference shows.
    public var returnDelay: TimeInterval {
        didSet { returnDelay = Self.validate(returnDelay, in: 0 ... 0.5, default: 0.12) }
    }

    /// The distance from the anchor, in points, at which a row trails by the
    /// full ``maximumStretch``.
    ///
    /// Larger values spread the falloff over more rows, which reads as a
    /// stiffer sheet; smaller values concentrate it near the grip. The default
    /// concentrates the spread over the four or five rows around the hand,
    /// which is where the eye is; the first cut graded across a whole
    /// viewport and read as nothing happening at all.
    ///
    /// Displacement grades over `max(resistanceFactor, maximumStretch)`, so no
    /// configuration can make the falloff steeper than 1:1 — which is the
    /// slope at which adjacent rows could meet.
    public var resistanceFactor: CGFloat {
        didSet { resistanceFactor = Self.validate(resistanceFactor, in: 1 ... 10000, default: 450) }
    }

    /// How quickly the rows catch the scroll back up, in radians per second.
    ///
    /// Lower is more languid: the lag takes longer to build and longer to pay
    /// back, and the speed at which the stretch saturates falls with it.
    public var angularFrequency: Double {
        didSet {
            angularFrequency = Self.validate(angularFrequency, in: 1 ... 500, default: 14)
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
    var anchorY: CGFloat = 0

    /// The per-row followers behind ``returnDelay``.
    ///
    /// A reference on purpose: the list stores the animator as a value and
    /// mutates it in place, and every copy it takes along the way has to see
    /// the same followers or a row would restart its lag on each frame.
    /// Follower state is display state, not model state — it never feeds back
    /// into the field — so sharing it across copies cannot fork the physics.
    final class Flow {
        struct Follower {
            var displacement: CGFloat
            var velocity: CGFloat
            var seen: TimeInterval
        }

        var followers: [Int: Follower] = [:]
        var clock: TimeInterval = 0
        var lastPrune: TimeInterval = 0
    }

    let flow = Flow()

    /// Equality is over the knobs. The spring's transient and the followers
    /// are display state — two configurations are the same animator whatever
    /// each happens to be showing this frame.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.maximumStretch == rhs.maximumStretch
            && lhs.resistanceFactor == rhs.resistanceFactor
            && lhs.angularFrequency == rhs.angularFrequency
            && lhs.dampingRatio == rhs.dampingRatio
            && lhs.unevenness == rhs.unevenness
            && lhs.returnDelay == rhs.returnDelay
    }

    public init(
        maximumStretch: CGFloat = 32,
        resistanceFactor: CGFloat = 450,
        angularFrequency: Double = 14,
        dampingRatio: Double = 0.75,
        unevenness: CGFloat = 0.2,
        returnDelay: TimeInterval = 0.12
    ) {
        self.maximumStretch = Self.validate(maximumStretch, in: 0 ... 200, default: 32)
        self.resistanceFactor = Self.validate(resistanceFactor, in: 1 ... 10000, default: 450)
        self.angularFrequency = Self.validate(angularFrequency, in: 1 ... 500, default: 14)
        self.dampingRatio = Self.validate(dampingRatio, in: 0.1 ... 5, default: 0.75)
        self.unevenness = Self.validate(unevenness, in: 0 ... 0.5, default: 0.2)
        self.returnDelay = Self.validate(returnDelay, in: 0 ... 0.5, default: 0.12)
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

        // The delta feeds in through a gain that dies as the stretch fills.
        // Injected whole and clamped, the stretch tracked the finger 1:1 —
        // the trailing row sat still while its gap opened — and then hit the
        // cap, where the row's velocity jumped from zero to the finger's in
        // a single frame. That corner is the "two-stage" feel: first pulled
        // out, then snapping into following. The smoothing belongs in the
        // velocity: with the gain `1 − (|S|/max)²` the row starts at rest and
        // *accelerates* into following as the gap fills, and saturation is an
        // asymptote instead of a wall. A delta that opposes the stretch gets
        // full gain — pulling back from saturation is the reversal, and it
        // must bite immediately.
        let occupancy = min(1, abs(spring.value) / Double(maximumStretch))
        let opposes = spring.value != 0 && (Double(scrollDelta) < 0) != (spring.value < 0)
        let gain = opposes ? 1 : 1 - occupancy * occupancy
        spring.setCurrent(spring.value + Double(scrollDelta) * gain, spring.context.currentVel)
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
        flow.followers.removeAll()
    }

    // MARK: - Displacement

    /// The two periods of the unevenness wave, in units of the falloff
    /// distance, and the largest gradient their sum can have. Incommensurate,
    /// so the pattern never visibly repeats across a screen.
    private static var wavePeriods: (CGFloat, CGFloat) { (0.9, 0.55) }
    /// `max |n′(u)|` for `n(u) = (sin(2πu/p₁) + sin(2πu/p₂ + 2)) / 2`:
    /// `π (1/p₁ + 1/p₂)` ≈ 9.21.
    private static var waveGradient: CGFloat { .pi * (1 / wavePeriods.0 + 1 / wavePeriods.1) }

    /// The distance the falloff actually grades over.
    ///
    /// ``resistanceFactor``, floored so that the displaced-position map keeps
    /// slope under 0.95 for *any* configuration: the falloff contributes
    /// `maximumStretch / R` and the unevenness wave `maximumStretch / R`
    /// times half its gradient, so the floor scales with both knobs. At the
    /// defaults the floor is ~48pt against an 800pt setting — it exists for
    /// hostile configurations, not for tuning.
    var effectiveResistance: CGFloat {
        max(resistanceFactor, maximumStretch * (1 + unevenness * Self.waveGradient / 2) / 0.95)
    }

    /// The steepest the falloff can be anywhere, in points of displacement
    /// per point of separation. Adjacent rows approach each other by at most
    /// this fraction of their separation, which is what the ordering tests
    /// assert against.
    var steepestFalloffSlope: CGFloat {
        maximumStretch * (1 + unevenness * Self.waveGradient / 2) / effectiveResistance
    }

    /// How far to displace a row whose centre sits at `center`.
    ///
    /// Zero at the anchor, growing with distance on *both* sides of it,
    /// saturating at ``effectiveResistance``. Both sides trail in the same
    /// direction — behind the motion — so the field flows around the grip:
    /// dragging the content down opens the gaps above the held row while the
    /// rows below bunch toward it, and the reverse direction mirrors it. An
    /// earlier version kept the near side rigid, which amputated half the
    /// effect: with nothing opening on the other side of the grip, one
    /// direction of every drag read as the whole screen shrinking.
    ///
    /// On top of the ramp, ``unevenness`` dips each row's lag along a slow
    /// two-tone wave in the same distance, so neighbours trail with visible
    /// individuality instead of shearing as one sheet. The wave only ever
    /// *dips* — the ramp is the ceiling — so ``maximumStretch`` stays the
    /// bound the mounting overscan relies on.
    ///
    /// The map from placed position to displaced position keeps slope within
    /// `1 ± steepestFalloffSlope`, capped at `1 ± 0.95`, so rows that were
    /// laid out edge to edge keep their order whatever their heights are.
    public func displacement(forRowCenteredAt center: CGFloat) -> CGFloat {
        let stretch = stretch
        guard stretch != 0 else { return 0 }
        let distance = anchorY - center
        let weight = min(1, abs(distance) / effectiveResistance)
        guard weight > 0 else { return 0 }
        guard unevenness > 0 else { return stretch * weight }
        let u = distance / effectiveResistance
        let wave = (sin(u * 2 * .pi / Self.wavePeriods.0)
            + sin(u * 2 * .pi / Self.wavePeriods.1 + 2)) / 2
        return stretch * weight * (1 - unevenness * (0.5 + 0.5 * wave))
    }

    // MARK: - Presets

    /// The iMessage feel, fitted to recordings of Messages rather than derived.
    ///
    /// The relaxation comes from two gaps tracked frame by frame and fitted to
    /// a second-order response — ω ≈ 19–21, ζ ≈ 0.6–0.75 — then slowed on
    /// request to ω = 14, so the rows visibly take their time catching the
    /// scroll back up. The shape comes from
    /// a per-element trace of the same footage — graded by distance from the
    /// pointer, gaps closing as well as opening — plus hands-on tuning: the
    /// stretch sits above the traced 12–16pt peak because on glass the fitted
    /// value read as timid, and the unevenness exists because a perfectly even
    /// ramp reads as the screen shearing, which Messages never looks like.
    /// See §2.5 and §8.4 of the design document.
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

    /// Frames are owed while the field is live *or* any follower is still on
    /// its way home — the field reaches rest first, and the far rows are
    /// still paying their ``returnDelay`` back after it.
    public var wantsNextFrame: Bool {
        !isAtRest || flow.followers.contains { abs($0.value.displacement) > 0.05 || abs($0.value.velocity) > 1 }
    }

    public mutating func willUpdate(_ context: ListAnimatorContext) {
        // The gravity exists only under the hand. The moment it lifts, the
        // spread stops being fed and smooths home — momentum and rebounds
        // scroll the rows rigidly while the spring pays back what it holds.
        // Feeding the deceleration too was tried and read as the whole screen
        // staying smeared for as long as the flick coasted.
        advance(
            scrollDelta: context.isUserInteracting ? context.scrollDelta : 0,
            deltaTime: context.deltaTime,
            anchorY: context.interactionAnchorY
        )
        flow.clock += context.deltaTime
        // Followers whose rows have not been offered for a while belong to
        // rows that are no longer mounted; nothing on screen shows them.
        if flow.clock - flow.lastPrune > 1 {
            flow.lastPrune = flow.clock
            flow.followers = flow.followers.filter { flow.clock - $0.value.seen < 1 }
        }
    }

    @MainActor
    public func update(row: ListRowView, at index: Int, frame: CGRect, in _: ListAnimatorContext) {
        row.setPresentationOffset(followedDisplacement(forRowCenteredAt: frame.midY, key: index))
    }

    /// The field, seen through this row's lag.
    ///
    /// ``displacement(forRowCenteredAt:)`` is the field as it is *now*; a row
    /// shows it through a first-order follower whose time constant grows with
    /// distance from the grip, up to ``returnDelay`` at the far end. The rows
    /// under the hand track the field as it moves; the far ones arrive late —
    /// on the way out and, what the eye actually catches, on the way home.
    ///
    /// A follower for a row it has not seen starts *on* the field, not at
    /// zero: a row scrolling into a live spread is already part of it, and
    /// seeding at zero would let it pop from its placement to its lag.
    /// Critically damped rather than first-order, and that is the point: a
    /// first-order follower changes velocity the instant its target does,
    /// which reads as the row being yanked. Second order carries a velocity
    /// of its own, so however the field jumps, the row's motion stays C¹ —
    /// the smoothing is in the derivative, where the eye lives.
    func followedDisplacement(forRowCenteredAt center: CGFloat, key: Int) -> CGFloat {
        let target = displacement(forRowCenteredAt: center)
        guard returnDelay > 1e-4 else {
            flow.followers[key] = nil
            return target
        }
        let lag = returnDelay * Double(min(1, abs(anchorY - center) / effectiveResistance))
        var follower = flow.followers[key] ?? .init(displacement: target, velocity: 0, seen: flow.clock)
        let elapsed = CGFloat(flow.clock - follower.seen)
        if lag <= 1e-4 {
            follower.displacement = target
            follower.velocity = 0
        } else if elapsed > 0 {
            // Closed form of the critically damped step toward `target`.
            let omega = CGFloat(2 / lag)
            let offset = follower.displacement - target
            let impulse = follower.velocity + omega * offset
            let decay = exp(-omega * elapsed)
            follower.displacement = target + (offset + impulse * elapsed) * decay
            follower.velocity = (follower.velocity - impulse * omega * elapsed) * decay
        }
        // Snap the tail so a settled row reads exactly its placement.
        if abs(follower.displacement - target) < 0.05, abs(follower.velocity) < 1 {
            follower.displacement = target
            follower.velocity = 0
        }
        follower.seen = flow.clock
        flow.followers[key] = follower
        return follower.displacement
    }
}
