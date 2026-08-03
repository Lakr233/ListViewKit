#if canImport(AppKit)
import AppKit
import Testing
@testable import ListViewKit

/// Heights scale with the list width, mimicking text reflow: the reference
/// width is 400, and bases are multiples of 3 so every scaled height stays
/// integral and assertions cannot drift on rounding.
@MainActor
private final class ReflowingHeightAdapter: ListViewAdapter {
    enum RowKind: Hashable {
        case row
    }

    var measurementCounts: [Int: Int] = [:]

    func baseHeight(for id: Int) -> CGFloat {
        60 + CGFloat(id % 5) * 30
    }

    func listView(_: ListView, rowKindFor _: ItemType, at _: Int) -> ListViewAdapter.RowKind {
        RowKind.row
    }

    func listViewMakeRow(for _: ListViewAdapter.RowKind) -> ListRowView {
        ListRowView()
    }

    func listView(_ listView: ListView, heightFor item: ItemType, at _: Int) -> CGFloat {
        let item = item as! ReflowItem
        measurementCounts[item.id, default: 0] += 1
        return (baseHeight(for: item.id) * 400 / max(listView.bounds.width, 1)).rounded()
    }

    func listView(_: ListView, configureRowView _: ListRowView, for _: ItemType, at _: Int) {}
}

private struct ReflowItem: Identifiable, Hashable {
    let id: Int
    var revision = 0
}

@Suite(.serialized)
@MainActor
struct ListViewDeferredSizeAppKitTests {
    private static let rowCount = 500

    private func makeListView(
        deferred: Bool,
        width: CGFloat = 400
    ) -> (
        listView: ListView,
        dataSource: ListViewDiffableDataSource<ReflowItem>,
        adapter: ReflowingHeightAdapter
    ) {
        let listView = ListView(frame: CGRect(x: 0, y: 0, width: width, height: 400))
        let adapter = ReflowingHeightAdapter()
        let dataSource = ListViewDiffableDataSource<ReflowItem>(listView: listView)
        listView.adapter = adapter
        listView.deferredSizeCalculation = deferred

        var snapshot = dataSource.snapshot()
        for index in 0 ..< Self.rowCount {
            snapshot.append(ReflowItem(id: index))
        }
        dataSource.applySnapshot(snapshot)
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        return (listView, dataSource, adapter)
    }

    private func resize(_ listView: ListView, toWidth width: CGFloat) {
        listView.frame = CGRect(x: 0, y: 0, width: width, height: listView.frame.height)
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
    }

    private func drainDeferredMeasurements(of listView: ListView) {
        for _ in 0 ..< 200 {
            guard listView.layoutCache.hasEstimatedHeights else { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        Issue.record("deferred measurement drain did not converge")
    }

    @Test
    func widthChangeMeasuresOnlyVisibleRows() {
        let context = makeListView(deferred: true)
        let listView = context.listView
        listView.setContentOffset(listView.maximumContentOffset, animated: false)
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        context.adapter.measurementCounts.removeAll()

        resize(listView, toWidth: 300)

        let remeasured = context.adapter.measurementCounts.keys.sorted()
        #expect(!remeasured.isEmpty)
        #expect(remeasured.count < 12)
        #expect(listView.layoutCache.hasEstimatedHeights)
        #expect(
            listView.layoutCache.estimatedIdentifiers.count
                == Self.rowCount - remeasured.count
        )
        let visible = Set(listView.indicesForVisibleRows)
        #expect(visible.isSuperset(of: remeasured))
    }

    /// While the width keeps changing, the drain must not measure off-screen
    /// rows — every correction would land on a width about to be replaced.
    /// Correction resumes (and converges) once the width holds still.
    @Test
    func widthChurnDefersOffScreenCorrection() {
        let context = makeListView(deferred: true)
        let listView = context.listView
        resize(listView, toWidth: 300)
        context.adapter.measurementCounts.removeAll()
        resize(listView, toWidth: 320)
        let visible = Set(listView.indicesForVisibleRows)

        // Well inside the hold-off window: only visible rows may measure.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(Set(context.adapter.measurementCounts.keys).isSubset(of: visible))
        #expect(listView.layoutCache.hasEstimatedHeights)

        drainDeferredMeasurements(of: listView)
        #expect(!listView.layoutCache.hasEstimatedHeights)
        let control = makeListView(deferred: false, width: 320)
        #expect(listView.layoutCache.contentHeight == control.listView.layoutCache.contentHeight)
    }

    @Test
    func drainConvergesToFullRecomputeResult() {
        let context = makeListView(deferred: true)
        let listView = context.listView
        resize(listView, toWidth: 300)
        drainDeferredMeasurements(of: listView)

        let control = makeListView(deferred: false, width: 300)
        #expect(listView.layoutCache.contentHeight == control.listView.layoutCache.contentHeight)
        for index in 0 ..< Self.rowCount {
            #expect(listView.layoutCache.frame(for: index) == control.listView.layoutCache.frame(for: index))
        }
        #expect(!listView.layoutCache.hasEstimatedHeights)
    }

    @Test
    func backgroundCorrectionKeepsBottomPinnedListStationary() {
        let context = makeListView(deferred: true)
        let listView = context.listView
        listView.setContentOffset(listView.maximumContentOffset, animated: false)
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()

        resize(listView, toWidth: 300)
        // The visible-rect pass reflows on-screen rows below the anchor, so
        // re-pin once, the way a bottom-pinned consumer does every layout.
        listView.setContentOffset(listView.maximumContentOffset, animated: false)
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        let visibleBefore = Set(listView.indicesForVisibleRows)

        for _ in 0 ..< 200 {
            guard listView.layoutCache.hasEstimatedHeights else { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            listView.layoutSubtreeIfNeeded()
            #expect(listView.maximumContentOffset.y - listView.contentOffset.y == 0)
            #expect(Set(listView.indicesForVisibleRows) == visibleBefore)
        }
        #expect(!listView.layoutCache.hasEstimatedHeights)
    }

    @Test
    func backgroundCorrectionKeepsMidListAnchorStationary() {
        let context = makeListView(deferred: true)
        let listView = context.listView
        let anchorIndex = 250
        // Align the viewport top exactly with the anchor row so no straddling
        // row above it reflows visibly.
        let anchorTop = listView.layoutCache.frame(for: anchorIndex)!.minY
        listView.setContentOffset(.init(x: 0, y: anchorTop), animated: false)
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()

        resize(listView, toWidth: 300)
        let screenY = { @MainActor in
            listView.rectForRow(at: anchorIndex).minY - listView.contentOffset.y
        }
        let anchorScreenY = screenY()
        #expect(anchorScreenY == 0)

        for _ in 0 ..< 200 {
            guard listView.layoutCache.hasEstimatedHeights else { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            listView.layoutSubtreeIfNeeded()
            #expect(screenY() == anchorScreenY)
        }
        #expect(!listView.layoutCache.hasEstimatedHeights)
    }

    @Test
    func snapshotMutationDuringDrainStaysConsistent() {
        let context = makeListView(deferred: true)
        let listView = context.listView
        resize(listView, toWidth: 300)
        #expect(listView.layoutCache.hasEstimatedHeights)

        var snapshot = context.dataSource.snapshot()
        _ = snapshot.remove(at: 10)
        snapshot.insert(ReflowItem(id: 1_000), at: 5)
        context.dataSource.applySnapshot(snapshot)
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        drainDeferredMeasurements(of: listView)

        let control = ListView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        let controlAdapter = ReflowingHeightAdapter()
        let controlDataSource = ListViewDiffableDataSource<ReflowItem>(listView: control)
        control.adapter = controlAdapter
        var controlSnapshot = controlDataSource.snapshot()
        for item in snapshot.elements {
            controlSnapshot.append(item)
        }
        controlDataSource.applySnapshot(controlSnapshot)
        control.needsLayout = true
        control.layoutSubtreeIfNeeded()

        #expect(listView.layoutCache.contentHeight == control.layoutCache.contentHeight)
        for index in 0 ..< snapshot.elements.count {
            #expect(listView.layoutCache.frame(for: index) == control.layoutCache.frame(for: index))
        }
    }

    @Test
    func disablingTheFlagFallsBackToFullRecompute() {
        let context = makeListView(deferred: true)
        let listView = context.listView
        resize(listView, toWidth: 300)
        #expect(listView.layoutCache.hasEstimatedHeights)

        listView.deferredSizeCalculation = false
        listView.layoutSubtreeIfNeeded()
        #expect(!listView.layoutCache.hasEstimatedHeights)

        let control = makeListView(deferred: false, width: 300)
        #expect(listView.layoutCache.contentHeight == control.listView.layoutCache.contentHeight)
    }
}
#endif
