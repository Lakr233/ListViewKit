#if canImport(AppKit)
import AppKit
import Testing
@testable import ListViewKit

@MainActor
private final class FixedHeightListAdapter: ListViewAdapter {
    enum RowKind: Hashable {
        case row
    }

    func listView(_: ListView, rowKindFor _: ItemType, at _: Int) -> ListViewAdapter.RowKind {
        RowKind.row
    }

    func listViewMakeRow(for _: ListViewAdapter.RowKind) -> ListRowView {
        ListRowView()
    }

    func listView(_: ListView, heightFor _: ItemType, at _: Int) -> CGFloat {
        100
    }

    func listView(_: ListView, configureRowView _: ListRowView, for _: ItemType, at _: Int) {}
}

@MainActor
private final class VariableHeightListAdapter: ListViewAdapter {
    enum RowKind: Hashable {
        case row
    }

    var heights: [Int: CGFloat] = [:]
    var measurementCounts: [Int: Int] = [:]

    func listView(_: ListView, rowKindFor _: ItemType, at _: Int) -> ListViewAdapter.RowKind {
        RowKind.row
    }

    func listViewMakeRow(for _: ListViewAdapter.RowKind) -> ListRowView {
        ListRowView()
    }

    func listView(_: ListView, heightFor item: ItemType, at _: Int) -> CGFloat {
        let item = item as! ScrollItem
        measurementCounts[item.id, default: 0] += 1
        return heights[item.id, default: 100]
    }

    func listView(_: ListView, configureRowView _: ListRowView, for _: ItemType, at _: Int) {}
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

@MainActor
private final class LayoutCountingAdapter: ListViewAdapter {
    enum RowKind: Hashable {
        case row
    }

    func listView(_: ListView, rowKindFor _: ItemType, at _: Int) -> ListViewAdapter.RowKind {
        RowKind.row
    }

    func listViewMakeRow(for _: ListViewAdapter.RowKind) -> ListRowView {
        LayoutCountingRow()
    }

    func listView(_: ListView, heightFor _: ItemType, at _: Int) -> CGFloat {
        100
    }

    func listView(_: ListView, configureRowView _: ListRowView, for _: ItemType, at _: Int) {}
}

private struct ScrollItem: Identifiable, Hashable {
    let id: Int
    var revision = 0
}

@Suite(.serialized)
@MainActor
struct ListViewScrollAppKitTests {
    private func makeListView() -> (
        listView: ListView,
        dataSource: ListViewDiffableDataSource<ScrollItem>,
        adapter: FixedHeightListAdapter
    ) {
        let listView = ListView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let adapter = FixedHeightListAdapter()
        let dataSource = ListViewDiffableDataSource<ScrollItem>(listView: listView)
        listView.adapter = adapter
        listView.contentInsets = NSEdgeInsets(top: 20, left: 10, bottom: 30, right: 0)

        var snapshot = dataSource.snapshot()
        for index in 0 ..< 20 {
            snapshot.append(ScrollItem(id: index))
        }
        dataSource.applySnapshot(snapshot)
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        return (listView, dataSource, adapter)
    }

    @Test
    func verticalScrollerStaysAboveVisibleRows() throws {
        let context = makeListView()
        let listView = context.listView
        let scrollerContainer = try #require(listView.subviews.first { view in
            view.subviews.contains { $0 is NSScroller }
        })

        #expect(listView.subviews.last === scrollerContainer)
    }

    @Test
    func rowPositionsRespectVisibleInsets() {
        let context = makeListView()
        let listView = context.listView
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
        let context = makeListView()
        let listView = context.listView

        listView.contentOffset = CGPoint(x: -10, y: 440)
        listView.scrollToRow(at: 5, at: .none, animated: false)
        #expect(listView.contentOffset == CGPoint(x: -10, y: 440))

        listView.contentOffset.y = 0
        listView.scrollToRow(at: 5, at: .none, animated: false)
        #expect(listView.contentOffset.y == 430)

        listView.contentOffset.y = 700
        listView.scrollToRow(at: 5, at: .none, animated: false)
        #expect(listView.contentOffset.y == 480)
    }

    @Test
    func visibleIndicesExcludeRowsTouchingViewportEdges() {
        let context = makeListView()
        let listView = context.listView

        listView.contentOffset.y = 500
        #expect(listView.indicesForVisibleRows == [5, 6])

        listView.topInset = 40
        listView.contentOffset.y = 540
        #expect(listView.indicesForVisibleRows == [5, 6])
    }

    @Test
    func scrollingDoesNotRelayoutRowsWithUnchangedFrames() throws {
        let listView = ListView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let adapter = LayoutCountingAdapter()
        let dataSource = ListViewDiffableDataSource<ScrollItem>(listView: listView)
        listView.adapter = adapter

        var snapshot = dataSource.snapshot()
        for index in 0 ..< 20 {
            snapshot.append(ScrollItem(id: index))
        }
        dataSource.applySnapshot(snapshot)
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()

        let firstRow = try #require(listView.rowView(at: 0) as? LayoutCountingRow)
        firstRow.layoutSubtreeIfNeeded()
        firstRow.layoutCount = 0
        firstRow.needsLayout = false

        listView.contentOffset.y = 10
        listView.layoutSubtreeIfNeeded()

        #expect(listView.rowView(at: 0) === firstRow)
        #expect(firstRow.layoutCount == 0)
    }

    @Test
    func pooledRowsAreRemovedFromSuperviewOnlyOnce() throws {
        let listView = ListView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let adapter = LayoutCountingAdapter()
        let dataSource = ListViewDiffableDataSource<ScrollItem>(listView: listView)
        listView.adapter = adapter

        var snapshot = dataSource.snapshot()
        for index in 0 ..< 20 {
            snapshot.append(ScrollItem(id: index))
        }
        dataSource.applySnapshot(snapshot)
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()

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

    @Test
    func rebuildingLayoutCacheRemovesStaleEntries() {
        let context = makeListView()
        let cache = context.listView.layoutCache
        cache.heightCache[AnyHashable(999)] = .init(height: 44, width: 200)
        cache.frameCache[999] = CGRect(x: 0, y: 99_999, width: 200, height: 44)

        cache.rebuild()

        #expect(cache.heightCache[AnyHashable(999)] == nil)
        #expect(cache.frameCache[999] == nil)
        #expect(cache.heightCache.count == 20)
        #expect(cache.frameCache.count == 20)
        #expect(cache.contentHeight == 2_000)
    }

    @Test
    func invalidatingHeightsSupportsSinglePassSequences() {
        let context = makeListView()
        let cache = context.listView.layoutCache
        var iterator = [5].makeIterator()
        let identifiers = AnySequence {
            AnyIterator { iterator.next() }
        }

        cache.requestInvalidateHeights(for: identifiers)

        #expect(cache.heightCache[AnyHashable(5)] == nil)
        #expect(cache.frameCache[5] == nil)
    }

    @Test
    func targetedHeightInvalidationRemeasuresOnlyThatRow() {
        let listView = ListView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let adapter = VariableHeightListAdapter()
        let dataSource = ListViewDiffableDataSource<ScrollItem>(listView: listView)
        listView.adapter = adapter
        dataSource.applySnapshot(using: (0 ..< 5).map { ScrollItem(id: $0) })
        listView.layoutSubtreeIfNeeded()
        listView.contentOffset.y = 120
        let initialMeasurementCounts = adapter.measurementCounts

        adapter.heights[1] = 180
        listView.invalidateLayout(forRowWithID: 1)
        listView.layoutSubtreeIfNeeded()

        #expect(listView.rectForRow(at: 1).height == 180)
        #expect(listView.rectForRow(at: 2).minY == 280)
        #expect(listView.contentSize.height == 580)
        #expect(listView.contentOffset.y == 120)
        #expect(adapter.measurementCounts[1] == initialMeasurementCounts[1, default: 0] + 1)
        #expect(adapter.measurementCounts[0] == initialMeasurementCounts[0])
        #expect(adapter.measurementCounts[2] == initialMeasurementCounts[2])
        #expect(adapter.measurementCounts[3] == initialMeasurementCounts[3])
        #expect(adapter.measurementCounts[4] == initialMeasurementCounts[4])
    }

    @Test
    func snapshotUpdateUsesTargetedHeightInvalidation() {
        let listView = ListView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let adapter = VariableHeightListAdapter()
        let dataSource = ListViewDiffableDataSource<ScrollItem>(listView: listView)
        listView.adapter = adapter
        dataSource.applySnapshot(using: (0 ..< 5).map { ScrollItem(id: $0) })
        listView.layoutSubtreeIfNeeded()
        let initialMeasurementCounts = adapter.measurementCounts

        adapter.heights[3] = 160
        var snapshot = dataSource.snapshot()
        snapshot.updateItem(ScrollItem(id: 3, revision: 1))
        dataSource.applySnapshot(snapshot)
        listView.layoutSubtreeIfNeeded()

        #expect(listView.rectForRow(at: 3).height == 160)
        #expect(listView.contentSize.height == 560)
        #expect(adapter.measurementCounts[3] == initialMeasurementCounts[3, default: 0] + 1)
        #expect(adapter.measurementCounts[0] == initialMeasurementCounts[0])
        #expect(adapter.measurementCounts[1] == initialMeasurementCounts[1])
        #expect(adapter.measurementCounts[2] == initialMeasurementCounts[2])
        #expect(adapter.measurementCounts[4] == initialMeasurementCounts[4])
    }

    @Test
    func directItemUpdateAvoidsAWholeSnapshotDiff() {
        let listView = ListView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let adapter = VariableHeightListAdapter()
        let dataSource = ListViewDiffableDataSource<ScrollItem>(listView: listView)
        listView.adapter = adapter
        dataSource.applySnapshot(using: (0 ..< 5).map { ScrollItem(id: $0) })
        listView.layoutSubtreeIfNeeded()
        let initialMeasurementCounts = adapter.measurementCounts

        adapter.heights[4] = 220
        #expect(dataSource.updateItem(ScrollItem(id: 4, revision: 1)))
        #expect(!dataSource.updateItem(ScrollItem(id: 4, revision: 1)))
        listView.layoutSubtreeIfNeeded()

        #expect(listView.rectForRow(at: 4).height == 220)
        #expect(listView.contentSize.height == 620)
        #expect(adapter.measurementCounts[4] == initialMeasurementCounts[4, default: 0] + 1)
        #expect(adapter.measurementCounts[0] == initialMeasurementCounts[0])
        #expect(adapter.measurementCounts[1] == initialMeasurementCounts[1])
        #expect(adapter.measurementCounts[2] == initialMeasurementCounts[2])
        #expect(adapter.measurementCounts[3] == initialMeasurementCounts[3])
    }

    @Test
    func bottomDetectionSupportsToleranceAndOverscroll() {
        let context = makeListView()
        let listView = context.listView
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
        let listView = ListView(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
        let adapter = FixedHeightListAdapter()
        let dataSource = ListViewDiffableDataSource<ScrollItem>(listView: listView)
        listView.adapter = adapter
        dataSource.applySnapshot(using: (0 ..< 3).map { ScrollItem(id: $0) })
        listView.layoutSubtreeIfNeeded()

        var snapshot = dataSource.snapshot()
        snapshot.insert(ScrollItem(id: 99), at: 0)
        dataSource.applySnapshot(snapshot, animatingDifferences: true)

        let insertedRow = try #require(listView.rowView(at: 0))
        let shiftedRow = try #require(listView.rowView(at: 1))
        #expect(insertedRow.layer?.animationKeys()?.isEmpty == false)
        #expect(shiftedRow.layer?.animationKeys()?.isEmpty == false)
    }

    @Test
    func invalidRowDoesNotChangeTheContentOffset() {
        let context = makeListView()
        let listView = context.listView
        listView.contentOffset = CGPoint(x: -10, y: 321)

        listView.scrollToRow(at: -1, at: .top, animated: false)
        #expect(listView.contentOffset == CGPoint(x: -10, y: 321))

        listView.scrollToRow(at: 20, at: .bottom, animated: false)
        #expect(listView.contentOffset == CGPoint(x: -10, y: 321))
    }
}
#endif
