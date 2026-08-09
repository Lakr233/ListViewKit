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
        guard rowAnimator != nil else { return }
        applyRowDisplacements()
        updateRowAnimatorLink()
    }

    /// The context handed to the animator for this pass.
    private func animatorContext(scrollDelta: CGFloat, deltaTime: TimeInterval) -> ListAnimatorContext {
        .init(
            viewportRect: contentVisibleRect,
            scrollDelta: scrollDelta,
            deltaTime: deltaTime,
            isUserInteracting: isUserInteractingWithScroll
        )
    }

    private func applyRowDisplacements() {
        guard let animator = rowAnimator else { return }
        // Snapshot before iterating. `update` is other people's code on the
        // hottest path there is, and it can reach back into the list; the
        // mounted set must not change under the loop.
        let rows: [(index: Int, view: ListRowView)] = visibleRows.compactMap { identifier, entry in
            guard let index = indexByID[identifier] else { return nil }
            return (index, entry.view)
        }
        guard !rows.isEmpty else { return }
        let context = animatorContext(scrollDelta: 0, deltaTime: 0)
        // Suppressed once for the whole pass rather than per row. A layout
        // pass routinely runs inside a caller's animation — the keyboard
        // pattern puts one around the whole thing — and a displacement is
        // never that caller's to animate.
        let wasRunning = isRunningRowAnimator
        isRunningRowAnimator = true
        defer { isRunningRowAnimator = wasRunning }
        withoutListAnimation {
            for row in rows {
                animator.update(
                    row: row.view,
                    at: row.index,
                    frame: row.view.placedFrame,
                    in: context
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
        guard rowAnimator != nil, !isRunningRowAnimator else { return }
        animatorTickCount &+= 1

        scrollLedger.accrue(offsetY: contentOffset.y)
        let context = animatorContext(
            scrollDelta: scrollLedger.consume(),
            deltaTime: min(duration, Self.longestAnimatorFrame)
        )
        do {
            isRunningRowAnimator = true
            defer { isRunningRowAnimator = false }
            rowAnimator?.willUpdate(context)
        }

        applyRowDisplacements()
        updateRowAnimatorLink()
    }


    /// Keeps a link alive exactly as long as something is owed a frame.
    ///
    /// Two reasons to keep going, and both are needed: the spring is still
    /// unwinding, or travel has been accrued that nothing has consumed. Only
    /// the second can start the loop — at rest with an empty ledger nothing
    /// would ever light the first frame.
    private func updateRowAnimatorLink() {
        guard let animator = rowAnimator, window != nil else {
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
        rowAnimator?.reset()
        scrollLedger.reset(offsetY: contentOffset.y)
        for row in visibleRows.values.map(\.view) {
            clearRowDisplacement(on: row)
        }
    }
}
