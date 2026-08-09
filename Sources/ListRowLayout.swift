//
//  ListRowLayout.swift
//  ListViewKit
//

import Foundation
import os
import QuartzCore

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#else
    #error("ListViewKit requires UIKit or AppKit")
#endif

/// Bridges the positional ``ListLayoutEngine`` to the list's items and row
/// registrations.
///
/// Rows enter the layout as estimates. Whatever the viewport needs is measured
/// on the spot; everything else is corrected in slices. Measured heights are
/// kept by item identity so they survive insertion and reordering, and all of
/// them are discarded when the content width changes, because a row height
/// only means anything at the width it was measured at.
@MainActor
final class ListRowLayout<Item: Identifiable & Hashable & SendableMetatype> {
    /// A single row that takes longer than a whole frame to measure cannot be
    /// sliced around; the list will drop frames until it is done.
    private static var slowRowThreshold: CFTimeInterval { 0.005 }

    private static var log: Logger { Logger(subsystem: "ListViewKit", category: "layout") }

    private unowned let listView: ListView<Item>
    private var engine = ListLayoutEngine()
    /// Heights already measured at ``contentWidth``, by item identity.
    private var measured: [Item.ID: CGFloat] = [:]
    private var contentWidth: CGFloat = 0

    init(_ listView: ListView<Item>) {
        self.listView = listView
    }

    // MARK: - Geometry

    var contentHeight: CGFloat { engine.totalHeight }
    var rowCount: Int { engine.count }
    var hasPendingRows: Bool { engine.hasPendingRows }
    var pendingRowCount: Int { engine.pendingCount }

    func frame(for index: Int) -> CGRect? {
        guard index >= 0, index < engine.count else { return nil }
        return CGRect(
            x: 0,
            y: engine.offset(at: index),
            width: contentWidth,
            height: engine.height(at: index)
        )
    }

    func indices(intersecting rect: CGRect) -> Range<Int> {
        guard !rect.isEmpty else { return 0 ..< 0 }
        return engine.indices(in: rect.minY ..< rect.maxY)
    }

    // MARK: - Structure

    /// Rebuilds row order from the list's items, carrying measured heights
    /// across by identity. Unknown rows enter as pending estimates.
    func reload() {
        engine.reset(listView.items.map(row(for:)))
    }

    /// Adds `count` rows at the end without touching the existing ones. This
    /// is the path a chat client takes for every new message.
    func appendRows(count: Int) {
        let items = listView.items
        for index in items.count - count ..< items.count {
            engine.append(row(for: items[index]))
        }
    }

    private func row(for item: Item) -> ListLayoutEngine.Row {
        if let height = measured[item.id] {
            return .init(height: height, isPending: false)
        }
        return .init(height: listView.estimatedHeight(for: item), isPending: true)
    }

    /// Marks rows as needing measurement again, keeping the current height as
    /// the estimate so content does not jump before the new one arrives.
    /// Identifiers no longer in the list simply have their height forgotten.
    func invalidateHeights(for identifiers: some Sequence<Item.ID>) {
        for identifier in identifiers {
            measured.removeValue(forKey: identifier)
            guard let index = listView.index(of: identifier) else { continue }
            engine.invalidate(at: index)
        }
    }

    /// Drops every measurement, including for rows no longer in the list.
    func invalidateAll() {
        measured.removeAll()
        reestimateRows()
    }

    /// Re-estimates everything when the width changes: a height measured at
    /// another width is not a measurement any more, only a starting guess.
    func prepareForLayout() {
        let width = listView.bounds.width
        guard width != contentWidth else { return }
        contentWidth = width
        guard engine.count > 0, !measured.isEmpty else { return }
        measured.removeAll(keepingCapacity: true)
        reestimateRows()
        listView.lastWidthChangeAt = CACurrentMediaTime()
    }

    /// Turns every row back into a pending estimate at the height it already
    /// has. Falling back to the default estimate instead would collapse the
    /// content the moment anything is invalidated, throwing away the reader's
    /// place before a single new height has been measured.
    private func reestimateRows() {
        engine.reset((0 ..< engine.count).map {
            .init(height: engine.height(at: $0), isPending: true)
        })
    }

    // MARK: - Measurement

    /// The first row layout holds visually still while heights change. Rows
    /// before it are entirely above the fold, so their height changes are
    /// invisible and belong in the scroll offset instead.
    ///
    /// The viewport's own top edge is the wrong boundary. It normally falls
    /// somewhere inside a row, and leaving that row uncompensated slides
    /// everything below it under the reader — the row reflows upwards off the
    /// screen, which is exactly what the offset should absorb.
    private func anchorIndex(in rect: CGRect) -> Int {
        let indices = indices(intersecting: rect)
        guard let first = indices.first else { return indices.lowerBound }
        let top = engine.offset(at: first)
        guard top < rect.minY else { return first }
        // A row that also runs past the bottom edge is the entire viewport:
        // nothing else is on screen to hold still, so its own top is the
        // anchor and its reflow shows below the fold.
        return top + engine.height(at: first) >= rect.maxY ? first : first + 1
    }

    /// Measures every pending row in the rect, repeating while the resulting
    /// height changes bring new pending rows into view.
    ///
    /// Returns the total height change above the anchor, which is what the
    /// content offset must move by to keep the anchor visually stationary.
    func measureRows(intersecting rect: CGRect, anchoredAt viewport: CGRect) -> CGFloat {
        var offsetDelta: CGFloat = 0
        // A measured row resizes the viewport's contents, so the visible span
        // has to be re-derived. Rows shorter than their estimate pull more of
        // them into view, and every one of those has to be measured too or the
        // drain would visibly reshuffle the viewport a moment later. Each pass
        // clears every pending row it sees, so this ends.
        while true {
            let indices = indices(intersecting: rect)
            guard engine.pendingCount(in: indices) > 0 else { return offsetDelta }
            let anchor = anchorIndex(in: viewport)
            for index in indices where engine.isPending(at: index) {
                offsetDelta += measure(at: index, anchorIndex: anchor)
            }
        }
    }

    /// Measures pending rows nearest the anchor, closest first, until
    /// `deadline`. Returns the same offset delta as ``measureRows``.
    func drainPendingRows(
        intersecting rect: CGRect,
        anchoredAt viewport: CGRect,
        deadline: CFTimeInterval
    ) -> CGFloat {
        let anchor = anchorIndex(in: viewport)
        var offsetDelta: CGFloat = 0
        var now = CACurrentMediaTime()
        while now < deadline, let next = engine.nextPending(near: anchor) {
            offsetDelta += measure(at: next, anchorIndex: anchor)
            let finished = CACurrentMediaTime()
            if finished - now > Self.slowRowThreshold {
                Self.log.warning(
                    """
                    Row \(next) took \((finished - now) * 1000, format: .fixed(precision: 1))ms \
                    to measure, over the \(Self.slowRowThreshold * 1000, format: .fixed(precision: 0))ms \
                    frame budget. Cache the expensive part of the height calculation.
                    """
                )
            }
            now = finished
        }
        return offsetDelta
    }

    /// Measures one row and reports how much of its height change happened
    /// above the anchor.
    private func measure(at index: Int, anchorIndex: Int) -> CGFloat {
        let previousHeight = engine.height(at: index)

        guard index < listView.items.count,
              let height = listView.measuredHeight(at: index)
        else {
            // Nobody can answer for this row. Settle for the estimate rather
            // than leaving it pending, which would spin every caller that
            // loops until nothing is pending.
            engine.setHeight(previousHeight, at: index)
            return 0
        }

        engine.setHeight(height, at: index)
        measured[listView.items[index].id] = engine.height(at: index)
        // A row at or below the anchor is on screen, so its growth is
        // something the reader should see rather than something to cancel out.
        return index < anchorIndex ? engine.height(at: index) - previousHeight : 0
    }
}
