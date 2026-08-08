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

/// Bridges the positional ``ListLayoutEngine`` to the data source and adapter.
///
/// Rows enter the layout as estimates. Whatever the viewport needs is measured
/// on the spot; everything else is corrected in slices. Measured heights are
/// kept by item identity so they survive insertion and reordering, and all of
/// them are discarded when the content width changes, because a row height
/// only means anything at the width it was measured at.
@MainActor
final class ListRowLayout {
    /// A single row that takes longer than a whole frame to measure cannot be
    /// sliced around; the list will drop frames until it is done.
    private static let slowRowThreshold: CFTimeInterval = 0.005

    private static let log = Logger(subsystem: "ListViewKit", category: "layout")

    private unowned let listView: ListView
    private var engine = ListLayoutEngine()
    /// Heights already measured at ``contentWidth``, by item identity.
    private var measured: [AnyHashable: CGFloat] = [:]
    private var contentWidth: CGFloat = 0

    init(_ listView: ListView) {
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

    /// Rebuilds row order from the data source, carrying measured heights
    /// across by identity. Unknown rows enter as pending estimates.
    func reload() {
        guard let dataSource = listView.dataSource else {
            engine.reset([])
            return
        }
        let count = dataSource.numberOfItems(in: listView)
        var rows: [ListLayoutEngine.Row] = []
        rows.reserveCapacity(count)
        for index in 0 ..< count {
            rows.append(row(at: index, in: dataSource))
        }
        engine.reset(rows)
    }

    /// Adds `count` rows at the end without touching the existing ones. This
    /// is the path a chat client takes for every new message.
    func appendRows(count: Int) {
        guard let dataSource = listView.dataSource else { return }
        let existing = engine.count
        for index in existing ..< existing + count {
            engine.append(row(at: index, in: dataSource))
        }
    }

    private func row(at index: Int, in dataSource: ListViewDataSource) -> ListLayoutEngine.Row {
        guard let identifier = dataSource.itemIdentifier(at: index, in: listView),
              let height = measured[AnyHashable(identifier)]
        else {
            return .init(height: listView.estimatedRowHeight, isPending: true)
        }
        return .init(height: height, isPending: false)
    }

    /// Marks rows as needing measurement again, keeping the current height as
    /// the estimate so content does not jump before the new one arrives.
    func invalidateHeights(for identifiers: some Sequence<AnyHashable>) {
        guard let dataSource = listView.dataSource else { return }
        for identifier in identifiers {
            measured.removeValue(forKey: identifier)
            guard let index = dataSource.itemIndex(for: identifier, in: listView) else { continue }
            engine.invalidate(at: index)
        }
    }

    /// Drops every measurement, including for rows no longer in the list.
    func invalidateAll() {
        measured.removeAll()
        reload()
    }

    /// Brings the layout in line with the view before a pass.
    ///
    /// The data source is weakly held, so the rows it described must not
    /// outlive it: an animation completion can run a layout after the owner
    /// has let it go, and rows without a data source cannot be configured.
    func prepareForLayout() {
        guard listView.dataSource != nil else {
            guard engine.count > 0 else { return }
            measured.removeAll()
            engine.reset([])
            return
        }
        setContentWidth(listView.bounds.width)
    }

    /// Re-estimates everything when the width changes: a height measured at
    /// another width is not a measurement any more, only a starting guess.
    private func setContentWidth(_ width: CGFloat) {
        guard width != contentWidth else { return }
        contentWidth = width
        guard engine.count > 0, !measured.isEmpty else { return }
        measured.removeAll(keepingCapacity: true)
        engine.reset((0 ..< engine.count).map {
            .init(height: engine.height(at: $0), isPending: true)
        })
        listView.lastWidthChangeAt = CACurrentMediaTime()
    }

    // MARK: - Measurement

    /// Measures every pending row in `indices`, repeating while the resulting
    /// height changes bring new pending rows into view.
    ///
    /// Returns the total height change of rows lying entirely above `anchorY`,
    /// which is what the content offset must move by to keep the rows at and
    /// below the anchor visually stationary.
    func measureRows(intersecting rect: CGRect, anchorY: CGFloat) -> CGFloat {
        var offsetDelta: CGFloat = 0
        // A measured row resizes the viewport's contents, so the visible span
        // has to be re-derived. Rows shorter than their estimate pull more of
        // them into view, and every one of those has to be measured too or the
        // drain would visibly reshuffle the viewport a moment later. Each pass
        // clears every pending row it sees, so this ends.
        while true {
            let indices = indices(intersecting: rect)
            guard engine.pendingCount(in: indices) > 0 else { return offsetDelta }
            for index in indices where engine.isPending(at: index) {
                offsetDelta += measure(at: index, anchorY: anchorY)
            }
        }
    }

    /// Measures pending rows nearest `index`, closest first, until `deadline`.
    /// Returns the same anchor-preserving offset delta as ``measureRows``.
    func drainPendingRows(near index: Int, anchorY: CGFloat, deadline: CFTimeInterval) -> CGFloat {
        var offsetDelta: CGFloat = 0
        var now = CACurrentMediaTime()
        while now < deadline, let next = engine.nextPending(near: index) {
            offsetDelta += measure(at: next, anchorY: anchorY)
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
    /// entirely above `anchorY`.
    private func measure(at index: Int, anchorY: CGFloat) -> CGFloat {
        guard let dataSource = listView.dataSource,
              let adapter = listView.adapter,
              let item = dataSource.item(at: index, in: listView)
        else {
            // Nobody can answer for this row. Settle for the estimate rather
            // than leaving it pending, which would spin every caller that
            // loops until nothing is pending.
            engine.setHeight(engine.height(at: index), at: index)
            return 0
        }

        let previousBottom = engine.offset(at: index) + engine.height(at: index)
        let previousHeight = engine.height(at: index)
        engine.setHeight(adapter.listView(listView, heightFor: item, at: index), at: index)
        let height = engine.height(at: index)
        if let identifier = dataSource.itemIdentifier(at: index, in: listView) {
            measured[AnyHashable(identifier)] = height
        }
        // A row straddling the anchor is partly on screen, so its growth is
        // something the reader should see rather than something to cancel out.
        return previousBottom <= anchorY ? height - previousHeight : 0
    }
}
