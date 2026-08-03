//
//  ListView+DeferredMeasurement.swift
//  ListViewKit
//
//  Created by 秋星桥 on 8/3/26.
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
    /// CPU budget one drain pass may spend correcting off-screen rows. Row
    /// measurement is adapter work of arbitrary cost, so the pass is bounded
    /// by time rather than row count: cheap rows drain by the dozens, while
    /// expensive text layout stops after a few and leaves the rest of the
    /// frame budget to rendering. Rows are corrected one at a time, so the
    /// worst overshoot past the deadline is a single measurement.
    private static let deferredMeasurementTimeBudget: CFTimeInterval = 0.004

    /// How long the width must hold still before off-screen correction
    /// resumes. A churning width — a pane animation, a programmatic resize —
    /// re-estimates every row on each tick, so anything corrected mid-churn
    /// is measured at a width that is about to be replaced. `inLiveResize`
    /// only covers AppKit's own window drag; this covers the rest. Visible
    /// rows are unaffected: layout corrects them synchronously either way.
    private static let deferredMeasurementChurnHoldOff: CFTimeInterval = 0.15

    /// Schedules one background correction pass on the main run loop.
    /// Reentrant-safe: at most one pass is pending at a time, and each pass
    /// reschedules itself while estimated heights remain.
    func scheduleDeferredMeasurement() {
        guard deferredSizeCalculation,
              layoutCache.hasEstimatedHeights,
              !isDeferredMeasurementScheduled
        else { return }
        isDeferredMeasurementScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                self?.drainDeferredMeasurementChunk()
            }
        }
    }

    /// Re-arms the drain after `delay` instead of on the next run-loop pass,
    /// so a churn hold-off does not spin an otherwise idle run loop.
    private func scheduleDeferredMeasurement(after delay: CFTimeInterval) {
        guard !isDeferredMeasurementScheduled else { return }
        isDeferredMeasurementScheduled = true
        let timer = Timer(timeInterval: max(delay, 0.01), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.drainDeferredMeasurementChunk()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func drainDeferredMeasurementChunk() {
        isDeferredMeasurementScheduled = false
        guard deferredSizeCalculation, layoutCache.hasEstimatedHeights else { return }
        #if canImport(AppKit)
            // Live resize already corrects the visible rect every layout tick;
            // spending the remaining frame budget on off-screen rows would
            // stutter the drag.
            if inLiveResize {
                scheduleDeferredMeasurement()
                return
            }
        #endif
        if isUserInteractingWithScroll {
            scheduleDeferredMeasurement()
            return
        }
        let sinceReflow = CACurrentMediaTime() - lastWidthReflowAt
        if sinceReflow < Self.deferredMeasurementChurnHoldOff {
            scheduleDeferredMeasurement(after: Self.deferredMeasurementChurnHoldOff - sinceReflow)
            return
        }

        let deadline = CACurrentMediaTime() + Self.deferredMeasurementTimeBudget
        var didCorrect = false
        repeat {
            // Offsets move as corrections compensate, so the anchor is
            // re-derived from the live contentOffset each iteration.
            let visibleRect = CGRect(
                origin: .init(x: contentOffset.x, y: contentOffset.y - topInset),
                size: bounds.size
            )
            let batch = layoutCache.nextEstimatedIndices(near: visibleRect, limit: 1)
            guard !batch.isEmpty else { break }
            let offsetDelta = layoutCache.correctEstimatedHeights(
                at: batch,
                anchorY: visibleRect.minY
            )
            compensateScrollOffset(by: offsetDelta)
            contentSize = supposedContentSize
            didCorrect = true
        } while layoutCache.hasEstimatedHeights && CACurrentMediaTime() < deadline
        guard didCorrect else { return }
        scheduleDeferredMeasurement()
    }
}
