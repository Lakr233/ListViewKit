//
//  ListView+RowAnimator.swift
//  ListViewKit
//

import Foundation
import MSDisplayLink

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#else
    #error("ListViewKit requires UIKit or AppKit")
#endif

/// A display link that calls back without owning the thing it calls.
///
/// `DisplayLink` holds a single delegate, weakly, and `ListScrollView` has
/// already claimed that slot for its own physics — a second link pointed at
/// the same object could not say which of the two had fired. The proxy gives
/// this link its own delegate, and it is retained here rather than by the
/// link, which holds it weakly.
@MainActor
final class RowAnimatorDisplayLink {
    private let link = DisplayLink()
    private let proxy: Proxy

    init(onTick: @escaping (DisplayLinkCallbackContext) -> Void) {
        proxy = Proxy(onTick: onTick)
        link.delegatingObject(proxy)
    }

    @MainActor
    fileprivate final class Proxy {
        let onTick: (DisplayLinkCallbackContext) -> Void
        init(onTick: @escaping (DisplayLinkCallbackContext) -> Void) {
            self.onTick = onTick
        }
    }
}

extension RowAnimatorDisplayLink.Proxy: @MainActor DisplayLinkDelegate {
    func synchronization(context: DisplayLinkCallbackContext) {
        onTick(context)
    }
}

extension ListView {
    /// The longest frame the spring is integrated over.
    ///
    /// A stalled frame handed over literally would advance the spring by more
    /// than any real motion covered, and the rows would jump to catch up with
    /// a moment that was never drawn.
    private static var longestAnimatorFrame: TimeInterval { 1.0 / 30.0 }

    // MARK: - Landing

    /// Displaces the mounted rows and decides whether another frame is owed.
    ///
    /// Deliberately outside `updateVisibleRowFrames`, which skips rows whose
    /// frames did not change and never sees a row placed by `ensureRowView`.
    /// A displacement changes every frame for rows that did not move at all,
    /// so it needs a pass that visits every mounted row unconditionally.
    func applyRowAnimator() {
        guard scrollSpring != nil else { return }
        applyRowDisplacements()
        updateRowAnimatorLink()
    }

    private func applyRowDisplacements() {
        guard let spring = scrollSpring else { return }
        // Snapshot before iterating: a row's own layout can reach back into
        // the list, and the mounted set must not change under the loop.
        let rows = visibleRows.values.map(\.view)
        guard !rows.isEmpty else { return }
        // Suppressed once for the whole pass rather than per row. A layout
        // pass routinely runs inside a caller's animation — the keyboard
        // pattern puts one around the whole thing — and a displacement is
        // never that caller's to animate.
        withoutListAnimation {
            for row in rows {
                setRowPresentationOffset(
                    spring.displacement(forRowCenteredAt: row.placedFrame.midY),
                    on: row
                )
            }
        }
    }

    /// Returns a row to its placement, for when it stops being displaced by
    /// anything: recycled, or handed to an animator that no longer exists.
    func clearRowDisplacement(on row: ListRowView) {
        withoutListAnimation { setRowPresentationOffset(0, on: row) }
    }

    // MARK: - Frames

    /// Advances the animator by one frame and lands the result.
    ///
    /// Travel is accrued here as well as in the layout pass, so a tick that
    /// beats layout to the offset still sees this frame's motion rather than
    /// last frame's.
    func tickRowAnimator(duration: TimeInterval) {
        guard var spring = scrollSpring, !isRunningRowAnimator else { return }
        isRunningRowAnimator = true
        defer { isRunningRowAnimator = false }
        animatorTickCount &+= 1

        scrollLedger.accrue(offsetY: contentOffset.y)
        let delta = scrollLedger.consume()
        spring.advance(
            scrollDelta: delta,
            deltaTime: min(duration, Self.longestAnimatorFrame),
            anchorY: restingEdge(ofViewport: contentVisibleRect, stretch: spring.stretch, delta: delta)
        )
        scrollSpring = spring

        applyRowDisplacements()
        updateRowAnimatorLink()
    }

    /// Where the stretch is zero, until a pointer position replaces it.
    ///
    /// Displacement is one-sided, so only rows on the far side of this move.
    /// Anchoring at the edge the content is receding from puts every visible
    /// row on that side, which is what makes the whole viewport spread rather
    /// than half of it.
    private func restingEdge(ofViewport viewport: CGRect, stretch: CGFloat, delta: CGFloat) -> CGFloat {
        // The stretch already in hand decides it; the incoming travel only
        // matters when there is none, which is the frame the motion starts on.
        let direction = stretch != 0 ? stretch : delta
        return direction >= 0 ? viewport.minY : viewport.maxY
    }

    /// Keeps a link alive exactly as long as something is owed a frame.
    ///
    /// Two reasons to keep going, and both are needed: the spring is still
    /// unwinding, or travel has been accrued that nothing has consumed. Only
    /// the second can start the loop — at rest with an empty ledger nothing
    /// would ever light the first frame.
    private func updateRowAnimatorLink() {
        guard let spring = scrollSpring, window != nil else {
            rowAnimatorLink = nil
            return
        }
        guard !spring.isAtRest || scrollLedger.pending != 0 else {
            rowAnimatorLink = nil
            return
        }
        guard rowAnimatorLink == nil else { return }
        rowAnimatorLink = RowAnimatorDisplayLink { [weak self] context in
            self?.tickRowAnimator(duration: context.duration)
        }
    }

    /// Drops the animator's state and everything it put on screen.
    func resetRowAnimator() {
        rowAnimatorLink = nil
        scrollSpring?.reset()
        scrollLedger.reset(offsetY: contentOffset.y)
        for row in visibleRows.values.map(\.view) {
            clearRowDisplacement(on: row)
        }
    }
}
