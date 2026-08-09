//
//  ListRowAnimator.swift
//  ListViewKit
//

import Foundation

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#else
    #error("ListViewKit requires UIKit or AppKit")
#endif

/// Displaces rows on top of where the list put them.
///
/// The list places rows; an animator moves them away from there. That split is
/// the whole contract: the engine's geometry is decided before an animator is
/// consulted and is handed over as an argument, so an implementation never
/// takes part in layout and never has to reproduce what the list does when it
/// places a row. ``ListRowView/placedFrame`` stays the truth throughout.
///
/// Every requirement has a default, and the default for `update` does nothing,
/// so an animator that overrides one method is a complete animator.
///
/// Everything a displacement has to be reconciled with is the list's job, not
/// the implementation's: which offset writes count as travel, clamping the
/// frame duration, widening the mounting rectangle, keeping the display link
/// alive, clearing a recycled row, and splitting the frame from the layout
/// passes. What arrives here is a clean scroll delta. An extension point that
/// made every implementation handle deferred-measurement compensation would be
/// a trap rather than an extension point.
@MainActor
public protocol ListRowAnimator {
    /// Called once per frame, before that frame's `update` calls.
    ///
    /// This is the only place time passes. A layout pass is not a frame — a
    /// single frame can run several — so state that advances with time
    /// advances here, and `update` only reads it. An implementation never has
    /// to work out whether it is being asked something new.
    mutating func willUpdate(_ context: ListAnimatorContext)

    /// Displaces one mounted row for this frame.
    ///
    /// Called for every mounted row, including rows whose frames did not
    /// change and rows mounted moments ago. `frame` is where the list placed
    /// the row, which is also ``ListRowView/placedFrame``.
    ///
    /// Not called inside the list's own animations: a displacement is
    /// rewritten every frame and has nothing to interpolate towards.
    func update(row: ListRowView, at index: Int, frame: CGRect, in context: ListAnimatorContext)

    /// Moves stored content-space state along with the content space.
    ///
    /// Deferred measurement shifts the offset so rows above the viewport can
    /// change size without anything appearing to move. Rows do not move, and
    /// the delta is kept out of `scrollDelta`, but the coordinate space they
    /// are addressed in has shifted underneath any position held from an
    /// earlier frame.
    mutating func rebase(byContentOffset delta: CGFloat)

    /// Drops all state. The list calls this before it stops using an animator
    /// and clears every displacement afterwards.
    mutating func reset()

    /// Whether another frame is owed.
    ///
    /// While true the list keeps a display link running. False lets it stop
    /// and cost nothing until the next scroll.
    var wantsNextFrame: Bool { get }

    /// The largest vertical distance `update` will displace a row by.
    ///
    /// The list overscans its mounting rectangle by this much in both
    /// directions, so a row displaced into view has been mounted already. It
    /// is read once per layout pass, so a change takes effect on the next one.
    ///
    /// Deliberately only about vertical translation. An effect that scales,
    /// rotates, or expands rows cannot be bounded by one number, and such an
    /// effect will be clipped at the viewport edges rather than served badly
    /// by a value pretending to describe it.
    var maximumDisplacement: CGFloat { get }
}

public extension ListRowAnimator {
    mutating func willUpdate(_: ListAnimatorContext) {}
    func update(row _: ListRowView, at _: Int, frame _: CGRect, in _: ListAnimatorContext) {}
    mutating func rebase(byContentOffset _: CGFloat) {}
    mutating func reset() {}
    var wantsNextFrame: Bool { false }
    var maximumDisplacement: CGFloat { 0 }
}

/// What the list knows about the frame being drawn.
public struct ListAnimatorContext: Sendable {
    /// The visible rectangle, in the space row frames are measured in.
    ///
    /// The real viewport, not the wider rectangle rows are mounted over.
    public let viewportRect: CGRect

    /// Vertical travel since the last frame, in points.
    ///
    /// Only motion a reader perceives as scrolling: a finger, momentum, a
    /// rubber band, an animated scroll. Compensation, a clamp after a resize,
    /// and an outright jump to an offset are all excluded.
    public let scrollDelta: CGFloat

    /// Seconds since the last frame, clamped to 1/30.
    ///
    /// A stalled frame handed over literally would advance an animation past
    /// motion that was never drawn.
    public let deltaTime: TimeInterval

    /// Whether a finger or a trackpad currently owns the offset.
    public let isUserInteracting: Bool
}

public extension ListRowView {
    /// Shows this row `dy` away from where the list placed it.
    ///
    /// The one supported way for an animator to move a row. Where the
    /// displacement lands differs by platform, and everything that has to hold
    /// for it to compose with the list's own animations is handled inside.
    func setPresentationOffset(_ dy: CGFloat) {
        setRowPresentationOffset(dy, on: self)
    }
}
