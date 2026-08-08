//
//  ListView+SliceDrain.swift
//  ListViewKit
//

import Foundation
import QuartzCore

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#else
    #error("ListViewKit requires UIKit or AppKit")
#endif

extension ListView {
    /// CPU a single drain pass may spend measuring off-screen rows. Row
    /// measurement is adapter work of arbitrary cost, so the pass is bounded by
    /// time rather than row count: cheap rows drain by the hundreds, expensive
    /// text layout stops after a few and leaves the rest of the frame to
    /// rendering. At 120Hz a frame is 8.3ms, so 5ms leaves room to draw.
    static var sliceBudget: CFTimeInterval { 0.005 }

    /// How long the width must hold still before off-screen measurement
    /// resumes. A churning width — a pane animation, a programmatic resize —
    /// re-estimates every row on each tick, so anything measured mid-churn is
    /// measured at a width about to be replaced. `inLiveResize` only covers
    /// AppKit's own window drag; this covers the rest. Visible rows are
    /// unaffected: layout measures them either way.
    private static var widthChurnHoldOff: CFTimeInterval { 0.15 }

    /// Schedules one drain pass on the main run loop. Reentrant-safe: at most
    /// one pass is pending, and each pass reschedules itself while rows remain.
    func scheduleSliceDrain() {
        guard rowLayout.hasPendingRows, !isSliceDrainScheduled else { return }
        isSliceDrainScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                self?.drainSlice()
            }
        }
    }

    /// Re-arms after `delay` instead of on the next run-loop pass, so a churn
    /// hold-off does not spin an otherwise idle run loop.
    private func scheduleSliceDrain(after delay: CFTimeInterval) {
        guard !isSliceDrainScheduled else { return }
        isSliceDrainScheduled = true
        let timer = Timer(timeInterval: max(delay, 0.01), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.drainSlice()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func drainSlice() {
        isSliceDrainScheduled = false
        guard rowLayout.hasPendingRows else { return }
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            // Live resize already measures the visible rect every layout tick;
            // spending the rest of the frame off-screen would stutter the drag.
            if inLiveResize {
                scheduleSliceDrain()
                return
            }
        #endif
        if isUserInteractingWithScroll {
            scheduleSliceDrain()
            return
        }
        let sinceWidthChange = CACurrentMediaTime() - lastWidthChangeAt
        if sinceWidthChange < Self.widthChurnHoldOff {
            scheduleSliceDrain(after: Self.widthChurnHoldOff - sinceWidthChange)
            return
        }

        let offsetDelta = rowLayout.drainPendingRows(
            intersecting: contentVisibleRect,
            deadline: CACurrentMediaTime() + Self.sliceBudget
        )
        compensateScrollOffset(by: offsetDelta)
        contentSize = supposedContentSize
        requestLayout()
        scheduleSliceDrain()
    }
}
