#if canImport(UIKit)
// UIKit platforms (including Mac Catalyst) are exercised by the UIKit suites.
#elseif canImport(AppKit)
import AppKit
import Testing
@testable import ListViewKit

private struct ScrollItem: Identifiable, Hashable {
    let id: Int
    var revision = 0
}

/// Row heights the test controls, and a record of who asked for them.
@MainActor
private final class HeightProbe {
    var heights: [Int: CGFloat] = [:]
    var measurementCounts: [Int: Int] = [:]

    func height(of item: ScrollItem) -> CGFloat {
        measurementCounts[item.id, default: 0] += 1
        return heights[item.id, default: 100]
    }
}

@MainActor
private final class LayoutCountingRow: ListRowView {
    var layoutCount = 0
    var removalCount = 0

    override func layout() {
        super.layout()
        layoutCount += 1
    }

    override func removeFromSuperview() {
        removalCount += 1
        super.removeFromSuperview()
    }
}

@Suite(.serialized)
@MainActor
struct ListViewScrollAppKitTests {
    private func makeListView(
        probe: HeightProbe,
        count: Int = 20,
        size: CGSize = CGSize(width: 200, height: 200),
        insets: NSEdgeInsets? = nil
    ) -> ListView<ScrollItem> {
        let listView = ListView<ScrollItem>(frame: CGRect(origin: .zero, size: size))
        listView.rows {
            ListRow(LayoutCountingRow.self)
                .height { item, _ in probe.height(of: item) }
                .configure { _, _, _ in }
        }
        if let insets {
            listView.contentInsets = insets
        }
        listView.apply((0 ..< count).map { ScrollItem(id: $0) })
        // Rows are measured lazily, so scroll geometry only settles once the
        // slice drain has caught up.
        drain(listView)
        return listView
    }

    private func drain(_ listView: ListView<ScrollItem>) {
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        for _ in 0 ..< 200 where listView.rowLayout.hasPendingRows {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
    }

    private func insetListView(_ probe: HeightProbe = .init()) -> ListView<ScrollItem> {
        makeListView(
            probe: probe,
            insets: NSEdgeInsets(top: 20, left: 10, bottom: 30, right: 0)
        )
    }

    @Test
    func verticalScrollerStaysAboveVisibleRows() throws {
        let listView = insetListView()
        let scrollerContainer = try #require(listView.subviews.first { view in
            view.subviews.contains { $0 is NSScroller }
        })

        #expect(listView.subviews.last === scrollerContainer)
    }

    @Test
    func rowPositionsRespectVisibleInsets() {
        let listView = insetListView()
        listView.contentOffset = CGPoint(x: -10, y: 700)

        listView.scrollToRow(at: 5, at: .top, animated: false)
        #expect(listView.contentOffset == CGPoint(x: -10, y: 480))

        listView.contentOffset.y = 700
        listView.scrollToRow(at: 5, at: .middle, animated: false)
        #expect(listView.contentOffset == CGPoint(x: -10, y: 455))

        listView.contentOffset.y = 700
        listView.scrollToRow(at: 5, at: .bottom, animated: false)
        #expect(listView.contentOffset == CGPoint(x: -10, y: 430))

        listView.contentOffset.y = 700
        listView.scrollToRow(at: 0, at: .middle, animated: false)
        #expect(listView.contentOffset == CGPoint(x: -10, y: -20))
    }

    @Test
    func minimalScrollUsesTheUnobscuredVisibleArea() {
        let listView = insetListView()

        listView.contentOffset = CGPoint(x: -10, y: 440)
        listView.scrollToRow(at: 5, at: .nearest, animated: false)
        #expect(listView.contentOffset == CGPoint(x: -10, y: 440))

        listView.contentOffset.y = 0
        listView.scrollToRow(at: 5, at: .nearest, animated: false)
        #expect(listView.contentOffset.y == 430)

        listView.contentOffset.y = 700
        listView.scrollToRow(at: 5, at: .nearest, animated: false)
        #expect(listView.contentOffset.y == 480)
    }

    @Test
    func scrollingToARowByIdentifierMatchesScrollingByIndex() {
        let listView = insetListView()
        listView.scrollToRow(at: 7, at: .top, animated: false)
        let byIndex = listView.contentOffset

        listView.contentOffset.y = 0
        listView.scrollToRow(with: 7, at: .top, animated: false)
        #expect(listView.contentOffset == byIndex)

        // An identifier that is not in the list leaves the offset alone.
        listView.scrollToRow(with: 9_999, at: .top, animated: false)
        #expect(listView.contentOffset == byIndex)
    }

    @Test
    func visibleIndicesExcludeRowsTouchingViewportEdges() {
        let listView = insetListView()

        listView.contentOffset.y = 500
        #expect(listView.indicesForVisibleRows == [5, 6])

        listView.topInset = 40
        listView.contentOffset.y = 540
        #expect(listView.indicesForVisibleRows == [5, 6])
    }

    @Test
    func scrollingDoesNotRelayoutRowsWithUnchangedFrames() throws {
        let listView = makeListView(probe: .init())

        let firstRow = try #require(listView.rowView(for: 0) as? LayoutCountingRow)
        firstRow.layoutSubtreeIfNeeded()
        firstRow.layoutCount = 0
        firstRow.needsLayout = false

        listView.contentOffset.y = 10
        listView.layoutSubtreeIfNeeded()

        #expect(listView.rowView(for: 0) === firstRow)
        #expect(firstRow.layoutCount == 0)
    }

    @Test
    func pooledRowsAreRemovedFromSuperviewOnlyOnce() throws {
        let listView = makeListView(probe: .init())

        listView.contentOffset.y = 50
        listView.layoutSubtreeIfNeeded()
        let initialRows = try listView.visibleRowViews.map {
            try #require($0 as? LayoutCountingRow)
        }
        #expect(initialRows.count == 3)
        initialRows.forEach { $0.removalCount = 0 }

        listView.contentOffset.y = listView.maximumContentOffset.y
        listView.layoutSubtreeIfNeeded()
        let pooledRow = try #require(initialRows.first { $0.superview == nil })
        #expect(pooledRow.removalCount == 1)

        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        #expect(pooledRow.removalCount == 1)
    }

    /// Measurements are kept by identity so they survive reordering. A removed
    /// row's measurement must not survive with them, or an item that comes back
    /// changed is laid out at its old height.
    @Test
    func removingARowForgetsItsMeasurement() {
        let probe = HeightProbe()
        probe.heights[5] = 70
        let listView = makeListView(probe: probe, count: 8)
        #expect(listView.rectForRow(at: 5).height == 70)

        listView.apply((0 ..< 8).filter { $0 != 5 }.map { ScrollItem(id: $0) })
        probe.heights[5] = 130
        listView.apply((0 ..< 8).map { ScrollItem(id: $0) })
        drain(listView)

        #expect(listView.rectForRow(at: 5).height == 130)
    }

    @Test
    func invalidatingHeightsSupportsSinglePassSequences() {
        let listView = makeListView(probe: .init(), count: 8)

        var iterator = [5].makeIterator()
        listView.rowLayout.invalidateHeights(for: AnySequence { AnyIterator { iterator.next() } })

        #expect(listView.rowLayout.pendingRowCount == 1)
    }

    @Test
    func targetedHeightInvalidationRemeasuresOnlyThatRow() {
        let probe = HeightProbe()
        let listView = makeListView(probe: probe, count: 5)
        listView.contentOffset.y = 120
        let initialCounts = probe.measurementCounts

        probe.heights[1] = 180
        // Row 1 spans 100..<200, so the viewport top sits inside it.
        let rowBelowScreenY = listView.rectForRow(at: 2).minY - listView.contentOffset.y
        listView.invalidateLayout(forRowWith: 1)
        drain(listView)

        #expect(listView.rectForRow(at: 1).height == 180)
        #expect(listView.rectForRow(at: 2).minY == 280)
        #expect(listView.contentSize.height == 580)
        // The row grew off the top edge, so the offset absorbs it and the rows
        // below it do not move under the reader.
        #expect(listView.rectForRow(at: 2).minY - listView.contentOffset.y == rowBelowScreenY)
        #expect(listView.contentOffset.y == 200)
        #expect(probe.measurementCounts[1] == initialCounts[1, default: 0] + 1)
        for id in [0, 2, 3, 4] {
            #expect(probe.measurementCounts[id] == initialCounts[id])
        }
    }

    @Test
    func applyingAChangedItemRemeasuresOnlyThatRow() {
        let probe = HeightProbe()
        let listView = makeListView(probe: probe, count: 5)
        let initialCounts = probe.measurementCounts

        probe.heights[3] = 160
        var items = listView.content
        items[3] = ScrollItem(id: 3, revision: 1)
        listView.apply(items)
        drain(listView)

        #expect(listView.rectForRow(at: 3).height == 160)
        #expect(listView.contentSize.height == 560)
        #expect(probe.measurementCounts[3] == initialCounts[3, default: 0] + 1)
        for id in [0, 1, 2, 4] {
            #expect(probe.measurementCounts[id] == initialCounts[id])
        }
    }

    @Test
    func updatingOneItemAvoidsAWholeDiff() {
        let probe = HeightProbe()
        let listView = makeListView(probe: probe, count: 5)
        let initialCounts = probe.measurementCounts

        probe.heights[4] = 220
        #expect(listView.update(ScrollItem(id: 4, revision: 1)))
        #expect(!listView.update(ScrollItem(id: 4, revision: 1)))
        drain(listView)

        #expect(listView.rectForRow(at: 4).height == 220)
        #expect(listView.contentSize.height == 620)
        #expect(probe.measurementCounts[4] == initialCounts[4, default: 0] + 1)
        for id in [0, 1, 2, 3] {
            #expect(probe.measurementCounts[id] == initialCounts[id])
        }
    }

    /// The append fast path must leave the rows already there untouched.
    @Test
    func appendingDoesNotRemeasureExistingRows() {
        let probe = HeightProbe()
        let listView = makeListView(probe: probe, count: 5)
        let initialCounts = probe.measurementCounts
        let heightBefore = listView.contentSize.height

        listView.append(ScrollItem(id: 99))

        #expect(listView.content.count == 6)
        for id in 0 ..< 5 {
            #expect(probe.measurementCounts[id] == initialCounts[id])
        }
        #expect(listView.contentSize.height == heightBefore + listView.estimatedRowHeight)

        drain(listView)
        #expect(listView.rectForRow(at: 5).height == 100)
        #expect(probe.measurementCounts[99] == 1)
    }

    @Test
    func bottomDetectionSupportsToleranceAndOverscroll() {
        let listView = insetListView()
        let bottom = listView.maximumContentOffset.y

        listView.contentOffset.y = bottom - 3
        #expect(listView.isScrolledToBottom(tolerance: 4))
        #expect(!listView.isScrolledToBottom(tolerance: 2))

        listView.contentOffset.y = bottom
        #expect(listView.isScrolledToBottom(tolerance: -.infinity))

        listView.contentOffset.y = bottom + 10
        #expect(listView.isScrolledToBottom())
    }

    @Test
    func insertionAnimationsAreNotDisabledByShiftedIndices() throws {
        let listView = makeListView(
            probe: .init(),
            count: 3,
            size: CGSize(width: 200, height: 400)
        )

        listView.apply([ScrollItem(id: 99)] + listView.content, animated: true)

        let insertedRow = try #require(listView.rowView(for: 99))
        let shiftedRow = try #require(listView.rowView(for: 0))
        #expect(insertedRow.layer?.animationKeys()?.isEmpty == false)
        #expect(shiftedRow.layer?.animationKeys()?.isEmpty == false)
    }

    @Test
    func invalidRowDoesNotChangeTheContentOffset() {
        let listView = insetListView()
        listView.contentOffset = CGPoint(x: -10, y: 321)

        listView.scrollToRow(at: -1, at: .top, animated: false)
        #expect(listView.contentOffset == CGPoint(x: -10, y: 321))

        listView.scrollToRow(at: 20, at: .bottom, animated: false)
        #expect(listView.contentOffset == CGPoint(x: -10, y: 321))
    }
}
#endif
