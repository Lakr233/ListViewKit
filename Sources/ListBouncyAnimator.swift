//
//  ListBouncyAnimator.swift
//  ListViewKit
//
//  A 1:1 port of BouncyLayout by Robert-Hein Hooijmans, MIT licensed.
//  https://github.com/roberthein/BouncyLayout
//

import Foundation

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#else
    #error("ListViewKit requires UIKit or AppKit")
#endif

/// The elastic lag rows show while the list scrolls — BouncyLayout's physics,
/// carried over verbatim onto ``ListRowAnimator``.
///
/// One spring **per row**, attached to the slot the list placed it at, exactly
/// as the original attaches a `UIAttachmentBehavior` to every visible cell.
/// A frame of scrolling displaces each row by the scroll delta scaled by its
/// distance from the touch — `|touch − anchor| / 1000`, the original's
/// resistance, capped at the full delta — and the spring then pulls the row
/// back to its slot. Rows near the hand move rigidly with the scroll; far
/// ones trail and catch up.
///
/// The pump is deliberately **not** gated on the hand. The original feeds
/// every bounds change through the same formula — a drag, momentum, a
/// rubber-band — using the pan gesture's last known location as the touch,
/// which is precisely what ``ListAnimatorContext/interactionAnchorY`` holds
/// while momentum carries on. Gating on `isUserInteracting` was the previous
/// model's choice, and it is one of the visible differences between the two.
///
/// What maps where:
/// - `UIAttachmentBehavior` (damping, frequency) → the solver the behaviour
///   runs on. UIKit Dynamics is Box2D underneath, and an attachment with a
///   damping and a frequency is its soft constraint: ω = 2πf, ζ = damping,
///   integrated semi-implicitly one step per frame — ``step(_:by:)`` is that
///   arithmetic, not a stand-in for it.
/// - `prepare()` adding behaviours for cells entering the buffered viewport →
///   a row unseen by `update` attaches on first sight, at its slot, holding no
///   displacement — the original anchors at the cell's current centre.
/// - behaviours removed once a cell leaves → followers unseen for a while are
///   pruned; the list stops offering a row the moment it unmounts.
/// - `shouldInvalidateLayout(forBoundsChange:)` → ``willUpdate(_:)``, whose
///   `scrollDelta` is the same bounds travel with compensation already
///   subtracted.
/// - `floor(item.center)` after each pump → the pumped displacement is
///   floored. The original re-floors the cell's absolute centre on every
///   bounds change; anchors there are floored at attach, so the arithmetic
///   comes to the same thing.
/// - `VIEWPORT_BUFFER` (200pt) → ``maximumDisplacement``, which is what the
///   list overscans its mounting rectangle by.
/// - the original tears down and re-adds every behaviour when a visible cell
///   changes size → a row whose slot moved is re-anchored in place, keeping
///   its displacement, which is the same repair without the one-frame pop.
///
/// Nothing here knows about views or time sources beyond the context handed
/// in. Not `Sendable`: the board it stores is shared mutable state.
public struct ListBouncyAnimator: Equatable {
    /// The original's three presets, numbers untouched.
    public enum BounceStyle: Sendable, Hashable {
        case subtle
        case regular
        case prominent

        public var damping: CGFloat {
            switch self {
            case .subtle: 0.8
            case .regular: 0.7
            case .prominent: 0.5
            }
        }

        public var frequency: CGFloat {
            switch self {
            case .subtle: 2
            case .regular: 1.5
            case .prominent: 1
            }
        }
    }

    /// The attachment's damping ratio. Below 1 a row overshoots its slot and
    /// comes back; the presets all sit below 1 on purpose.
    public var damping: CGFloat {
        didSet { damping = Self.validate(damping, in: 0.01 ... 10, default: BounceStyle.regular.damping) }
    }

    /// The attachment's oscillation frequency, in hertz.
    ///
    /// Both knobs are read on every step, so a change reaches the springs
    /// already in flight — there is no per-attachment tuning to go stale.
    public var frequency: CGFloat {
        didSet { frequency = Self.validate(frequency, in: 0.1 ... 50, default: BounceStyle.regular.frequency) }
    }

    /// The original divides the distance from the touch by this to grade the
    /// pump: a row 1000pt away absorbs the full scroll delta, a row under the
    /// finger none of it.
    static var resistanceDistance: CGFloat { 1000 }

    /// The original insets its viewport by this much when deciding which
    /// cells deserve a behaviour, so fast scrolling does not outrun the
    /// springs. Here it is what the list widens its mounting rectangle by.
    static var viewportBuffer: CGFloat { 200 }

    /// Displacement below this, with velocity below ``restingVelocity``, is
    /// indistinguishable from rest at any scale factor a display has.
    private static var restingDisplacement: CGFloat { 0.05 }
    /// Points per second.
    private static var restingVelocity: Double { 0.5 }

    /// The per-row attachments.
    ///
    /// A reference on purpose: the list stores the animator as a value and
    /// mutates it in place, and every copy it takes along the way has to see
    /// the same attachments or a row would restart its spring on each frame.
    /// Attachment state is display state, not configuration — it never feeds
    /// back into the knobs — so sharing it across copies cannot fork anything
    /// observable.
    final class Board {
        struct Attachment {
            /// How far the row sits from its slot right now, in points.
            var displacement: CGFloat = 0
            /// Points per second, carried between steps the way a body's
            /// velocity persists between physics ticks.
            var velocity: CGFloat = 0
            /// The slot the spring is attached to, in content space.
            var anchorY: CGFloat
            var seen: TimeInterval
        }

        var attachments: [Int: Attachment] = [:]
        var clock: TimeInterval = 0
        var lastPrune: TimeInterval = 0
    }

    let board = Board()

    /// Equality is over the knobs. The attachments are display state — two
    /// configurations are the same animator whatever each happens to be
    /// showing this frame.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.damping == rhs.damping && lhs.frequency == rhs.frequency
    }

    public init(damping: CGFloat = BounceStyle.regular.damping, frequency: CGFloat = BounceStyle.regular.frequency) {
        self.damping = Self.validate(damping, in: 0.01 ... 10, default: BounceStyle.regular.damping)
        self.frequency = Self.validate(frequency, in: 0.1 ... 50, default: BounceStyle.regular.frequency)
    }

    public init(style: BounceStyle) {
        self.init(damping: style.damping, frequency: style.frequency)
    }

    // MARK: - Attachments

    /// How far the attachment for `key` is currently displacing its row.
    func displacement(forKey key: Int) -> CGFloat {
        board.attachments[key]?.displacement ?? 0
    }

    /// The original's `update(behavior:and:in:for:)`, for one attachment.
    ///
    /// `delta < 0 ? max(delta, delta · resistance) : min(delta, delta ·
    /// resistance)` — the resistance grades the pump by distance from the
    /// touch and the min/max caps it at the full delta, both branches picking
    /// the smaller magnitude. The floor afterwards is the original's
    /// `item.center = floor(item.center)`. The velocity is untouched, exactly
    /// as moving a dynamic item's centre does not touch the body's velocity.
    private func pump(_ attachment: inout Board.Attachment, delta: CGFloat, touchY: CGFloat) {
        guard delta != 0 else { return }
        let resistance = abs(touchY - attachment.anchorY) / Self.resistanceDistance
        let bite = delta < 0 ? max(delta, delta * resistance) : min(delta, delta * resistance)
        attachment.displacement = floor(attachment.displacement + bite)
    }

    /// One physics step of the behaviour's spring: Box2D's soft constraint,
    /// which is what `UIDynamicAnimator` — a Box2D wrapper — runs for a
    /// `UIAttachmentBehavior` with a damping and a frequency. The behaviour's
    /// frequency is in hertz, so ω = 2πf, and its damping is the ratio ζ;
    /// ``SoftConstraint`` is the arithmetic itself. Afterwards the tail is
    /// snapped, so a settled row reads exactly its placement.
    private func step(_ attachment: inout Board.Attachment, by deltaTime: TimeInterval) {
        SoftConstraint.step(
            position: &attachment.displacement,
            velocity: &attachment.velocity,
            towards: 0,
            angularFrequency: 2 * CGFloat.pi * frequency,
            dampingRatio: damping,
            deltaTime: deltaTime
        )
        if abs(attachment.displacement) <= Self.restingDisplacement,
           abs(attachment.velocity) <= CGFloat(Self.restingVelocity) {
            attachment.displacement = 0
            attachment.velocity = 0
        }
    }

    // MARK: - Validation

    /// Keeps a value inside the range the model is defined on.
    ///
    /// These are public knobs in the end, and a spring configured with a
    /// negative frequency or a `NaN` damping does not misbehave gracefully:
    /// it propagates the `NaN` into every row frame on the next pass.
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
extension ListBouncyAnimator: ListRowAnimator {
    public var maximumDisplacement: CGFloat { Self.viewportBuffer }

    /// Frames are owed while any attachment is still on its way home.
    public var wantsNextFrame: Bool {
        board.attachments.contains {
            abs($0.value.displacement) > Self.restingDisplacement
                || abs($0.value.velocity) > CGFloat(Self.restingVelocity)
        }
    }

    /// The original's `shouldInvalidateLayout(forBoundsChange:)` and the
    /// dynamic animator's tick, in that order: the bounds travel lands on
    /// every attachment first, then time passes and the springs pull back.
    ///
    /// Every scroll pumps — momentum and rebounds included. The touch the
    /// resistance is measured from is wherever the hand was last seen, which
    /// is also what `panGestureRecognizer.location(in:)` answers after the
    /// lift.
    public mutating func willUpdate(_ context: ListAnimatorContext) {
        board.clock += context.deltaTime
        for key in board.attachments.keys {
            guard var attachment = board.attachments[key] else { continue }
            pump(&attachment, delta: context.scrollDelta, touchY: context.interactionAnchorY)
            step(&attachment, by: context.deltaTime)
            board.attachments[key] = attachment
        }
        // Attachments whose rows have not been offered for a while belong to
        // rows that are no longer mounted; nothing on screen shows them.
        if board.clock - board.lastPrune > 1 {
            board.lastPrune = board.clock
            board.attachments = board.attachments.filter { board.clock - $0.value.seen < 1 }
        }
    }

    @MainActor
    public func update(row: ListRowView, at index: Int, frame: CGRect, in _: ListAnimatorContext) {
        row.setPresentationOffset(attach(at: frame.midY, key: index))
    }

    /// Looks an attachment up, making one the first time a row is seen.
    ///
    /// A new attachment anchors at the slot the list just placed the row at
    /// and holds no displacement — the original attaches at the cell's
    /// current centre, and a cell entering the buffered viewport is at its
    /// layout position. A row whose slot has moved since is re-anchored in
    /// place with its displacement kept: the original handles a resize by
    /// tearing every behaviour down and re-adding it, which zeroes the whole
    /// screen's springs for a frame, and keeping the displacement is that
    /// repair without the pop.
    func attach(at slotY: CGFloat, key: Int) -> CGFloat {
        var attachment = board.attachments[key] ?? .init(anchorY: slotY, seen: board.clock)
        attachment.anchorY = slotY
        attachment.seen = board.clock
        board.attachments[key] = attachment
        return attachment.displacement
    }

    /// Moves the stored anchors with the content coordinate space.
    ///
    /// Compensation shifts the offset so rows above it can resize without
    /// visible motion. The rows do not move, but the space they are addressed
    /// in does, and every anchor is a coordinate in it.
    public mutating func rebase(byContentOffset delta: CGFloat) {
        for key in board.attachments.keys {
            board.attachments[key]?.anchorY += delta
        }
    }

    public mutating func reset() {
        board.attachments.removeAll()
    }
}
