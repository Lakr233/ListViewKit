//
//  ListView+DeferredMeasurement.swift
//  ListViewKit
//
//  Created by 秋星桥 on 8/3/26.
//

import Foundation

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#else
    #error("ListViewKit requires UIKit or AppKit")
#endif

extension ListView {
    /// Rows corrected per run-loop pass. Row measurement is adapter work of
    /// arbitrary cost, so the chunk is kept small enough that even expensive
    /// text layout stays within roughly one frame.
    private static let deferredMeasurementChunkSize = 8

    /// Schedules one background correction chunk on the main run loop.
    /// Reentrant-safe: at most one chunk is pending at a time, and each chunk
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

        let visibleRect = CGRect(
            origin: .init(x: contentOffset.x, y: contentOffset.y - topInset),
            size: bounds.size
        )
        let batch = layoutCache.nextEstimatedIndices(
            near: visibleRect,
            limit: Self.deferredMeasurementChunkSize
        )
        guard !batch.isEmpty else { return }
        let offsetDelta = layoutCache.correctEstimatedHeights(
            at: batch,
            anchorY: visibleRect.minY
        )
        compensateScrollOffset(by: offsetDelta)
        contentSize = supposedContentSize
        scheduleDeferredMeasurement()
    }
}
