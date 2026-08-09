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
        guard rowAnimator != nil, !isDrivingRowAnimator, !prefersReducedMotion else { return }
        catchUpOnTheFrameNoLinkWillDeliver()
        applyRowDisplacements()
        updateRowAnimatorLink()
    }

    /// What the first frame of a gesture is integrated by.
    ///
    /// No link has run, so no frame has been measured. The shorter of the two
    /// rates a display runs at under-relaxes rather than over-relaxes, and
    /// either way the next frame — which does have a duration — corrects it.
    private static var firstFrameOfAGesture: TimeInterval { 1.0 / 120.0 }

    /// Integrates the travel this pass is about to land on screen, on the one
    /// frame where nothing else will.
    ///
    /// The link is created at the end of this pass, and a display link does not
    /// call back on the frame it is built. So the first frame of every gesture
    /// used to place the rows at the new offset and displace them by the
    /// stretch from before the gesture began, which is zero — and the step to
    /// the real value landed on the next frame, on top of that frame's own
    /// travel. That is the whole of the two-clock problem: `contentOffset` and
    /// `presentationOffset` are written by different clocks, and this is the
    /// one frame in a gesture where they are a frame apart. Once the link is
    /// running, its callback and the layout pass are in the same run-loop turn
    /// and reach the render server in one transaction, in either order.
    ///
    /// Rows placed at a new offset with a stale displacement were tolerable
    /// while the anchor kept every row saturated and the difference was a
    /// common-mode shift. With the anchor on the content it is a dozen points
    /// of differential appearing a frame late, which is exactly the onset
    /// wobble the simulator recording measured at ~30pt.
    private func catchUpOnTheFrameNoLinkWillDeliver() {
        // `window` is the same condition `updateRowAnimatorLink` creates on: no
        // window, no link, and then this is not catching up on anything — it is
        // the whole clock, which is not this function's job to be.
        guard rowAnimatorLink == nil, window != nil, scrollLedger.pending != 0 else { return }
        advanceRowAnimator(duration: Self.firstFrameOfAGesture)
    }

    /// Re-reads how far the animator may displace a row.
    ///
    /// Reduced motion is honoured by pretending there is no animator, which
    /// takes the overscan with it — a widened mounting rectangle would be pure
    /// cost for an effect that is not being drawn.
    func refreshMountOverscan() {
        guard let animator = rowAnimator, !prefersReducedMotion else {
            mountOverscan = 0
            return
        }
        let requested = animator.maximumDisplacement
        mountOverscan = requested.isFinite ? min(max(0, requested), Self.largestOverscan) : 0
    }

    /// A ceiling on the overscan, since it is a number from someone else's
    /// type and mounting the rows it asks for is the list's bill to pay.
    private static var largestOverscan: CGFloat { 1000 }

    /// Whether the system has asked for less movement.
    var prefersReducedMotion: Bool {
        #if canImport(UIKit)
            UIAccessibility.isReduceMotionEnabled
        #elseif canImport(AppKit)
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #endif
    }

    /// Hands the list back to itself after the animator is replaced.
    ///
    /// The old animator is told first and the rows are cleared afterwards, so
    /// an implementation cannot leave a displacement behind by declining to
    /// clear one itself. The new one starts against rows that are where the
    /// layout put them.
    func rowAnimatorDidChange(from previous: (any ListRowAnimator)?) {
        if var previous {
            // Pointless for a struct, whose copy is about to be discarded, and
            // the whole point for a class, which the protocol also allows.
            previous.reset()
        }
        rowAnimatorLink = nil
        scrollLedger.reset(offsetY: contentOffset.y)
        for row in visibleRows.values.map(\.view) {
            clearRowDisplacement(on: row)
        }
        refreshMountOverscan()
        requestLayout()
    }

    /// The context handed to the animator for this pass.
    private func animatorContext(scrollDelta: CGFloat, deltaTime: TimeInterval) -> ListAnimatorContext {
        .init(
            viewportRect: viewportRect,
            contentRect: contentRect,
            scrollDelta: scrollDelta,
            deltaTime: deltaTime,
            isUserInteracting: isUserInteractingWithScroll
        )
    }

    private func applyRowDisplacements() {
        guard let animator = rowAnimator else { return }
        // `update` is other people's code on the hottest path there is, and it
        // can reach back into the list. Iterating the dictionary directly is
        // safe anyway: it is a value, so the loop holds its own copy and a
        // mutation from inside `update` lands on a new one. An earlier version
        // copied the rows into an array first, which bought nothing and cost
        // an allocation every frame.
        guard !visibleRows.isEmpty else { return }
        let context = animatorContext(scrollDelta: 0, deltaTime: 0)
        // Suppressed once for the whole pass rather than per row. A layout
        // pass routinely runs inside a caller's animation — the keyboard
        // pattern puts one around the whole thing — and a displacement is
        // never that caller's to animate.
        let wasRunning = isDrivingRowAnimator
        isDrivingRowAnimator = true
        defer { isDrivingRowAnimator = wasRunning }
        withoutListAnimation {
            for (identifier, entry) in visibleRows {
                guard let index = indexByID[identifier] else { continue }
                animator.update(
                    row: entry.view,
                    at: index,
                    frame: entry.view.placedFrame,
                    in: context
                )
            }
        }
    }

    /// Returns a row to its placement, for when it stops being displaced by
    /// anything: recycled, or handed to an animator that no longer exists.
    ///
    /// The early return is not a micro-optimisation. Recycling calls this for
    /// every row it reclaims, and suppression on AppKit means opening an
    /// `NSAnimationContext` group — so without the check, a list with no
    /// animator at all paid for one per recycled row, which measured as a 5%
    /// regression on the scrolling benchmark. `setRowPresentationOffset`
    /// returns early too, but by then the context has been paid for.
    func clearRowDisplacement(on row: ListRowView) {
        guard row.presentationOffset != 0 else { return }
        withoutListAnimation { setRowPresentationOffset(0, on: row) }
    }

    // MARK: - Frames

    /// Advances the animator by one frame and lands the result.
    ///
    /// Travel is accrued here as well as in the layout pass, so a tick that
    /// beats layout to the offset still sees this frame's motion rather than
    /// last frame's.
    func tickRowAnimator(duration: TimeInterval) {
        guard rowAnimator != nil, !isDrivingRowAnimator, !prefersReducedMotion else { return }
        advanceRowAnimator(duration: duration)
        applyRowDisplacements()
        updateRowAnimatorLink()
    }

    /// Hands the animator one frame's travel and one frame's worth of time.
    private func advanceRowAnimator(duration: TimeInterval) {
        animatorTickCount &+= 1
        scrollLedger.accrue(offsetY: contentOffset.y)
        let context = animatorContext(
            scrollDelta: scrollLedger.consume(),
            deltaTime: min(duration, Self.longestAnimatorFrame)
        )
        isDrivingRowAnimator = true
        defer { isDrivingRowAnimator = false }
        rowAnimator?.willUpdate(context)
    }

    /// Keeps a link alive exactly as long as something is owed a frame.
    ///
    /// Two reasons to keep going, and both are needed: the spring is still
    /// unwinding, or travel has been accrued that nothing has consumed. Only
    /// the second can start the loop — at rest with an empty ledger nothing
    /// would ever light the first frame.
    private func updateRowAnimatorLink() {
        guard let animator = rowAnimator, window != nil, !prefersReducedMotion else {
            rowAnimatorLink = nil
            return
        }
        guard animator.wantsNextFrame || scrollLedger.pending != 0 else {
            rowAnimatorLink = nil
            return
        }
        guard rowAnimatorLink == nil else { return }
        rowAnimatorLink = RowAnimatorDisplayLink { [weak self] context in
            self?.tickRowAnimator(duration: context.duration)
        }
    }

    /// Drops the animator's state and everything it put on screen.
    ///
    /// The order matters: the animator is told first, and the list clears the
    /// rows afterwards, so an implementation cannot leave a displacement
    /// behind by declining to clear one itself.
    func resetRowAnimator() {
        rowAnimatorLink = nil
        do {
            isDrivingRowAnimator = true
            defer { isDrivingRowAnimator = false }
            rowAnimator?.reset()
        }
        scrollLedger.reset(offsetY: contentOffset.y)
        for row in visibleRows.values.map(\.view) {
            clearRowDisplacement(on: row)
        }
    }
}
