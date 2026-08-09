#if canImport(UIKit)
// UIKit platforms (including Mac Catalyst) are exercised by the UIKit suites.
#elseif canImport(AppKit)
import AppKit
import Testing
@testable import ListViewKit

/// Heights scale with the list width, mimicking text reflow: the reference
/// width is 400, and bases are multiples of 3 so every scaled height stays
/// integral and assertions cannot drift on rounding.
@MainActor
private final class ReflowProbe {
    var measurementCounts: [Int: Int] = [:]

    func baseHeight(for id: Int) -> CGFloat {
        60 + CGFloat(id % 5) * 30
    }

    func height(of item: ReflowItem, width: CGFloat) -> CGFloat {
        measurementCounts[item.id, default: 0] += 1
        return (baseHeight(for: item.id) * 400 / max(width, 1)).rounded()
    }
}

private struct ReflowItem: Identifiable, Hashable {
    let id: Int
    var revision = 0
}

@Suite(.serialized)
@MainActor
struct ListViewSlicedLayoutAppKitTests {
    private static let rowCount = 500

    private typealias Context = (listView: ListView<ReflowItem>, adapter: ReflowProbe)

    private func makeListView(width: CGFloat = 400, count: Int = rowCount) -> Context {
        let probe = ReflowProbe()
        let listView = ListView<ReflowItem>(frame: CGRect(x: 0, y: 0, width: width, height: 400))
        listView.rows {
            ListRow(ListRowView.self)
                .height { item, ctx in probe.height(of: item, width: ctx.width) }
                .configure { _, _, _ in }
        }
        listView.apply((0 ..< count).map { ReflowItem(id: $0) })
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        return (listView, probe)
    }

    /// A fully measured list, for comparing a drained result against.
    private func makeMeasuredListView(width: CGFloat = 400) -> Context {
        let context = makeListView(width: width)
        drain(context.listView)
        return context
    }

    private func resize(_ listView: ListView<ReflowItem>, toWidth width: CGFloat) {
        listView.frame = CGRect(x: 0, y: 0, width: width, height: listView.frame.height)
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
    }

    private func drain(_ listView: ListView<ReflowItem>, sourceLocation: SourceLocation = #_sourceLocation) {
        for _ in 0 ..< 400 {
            guard listView.rowLayout.hasPendingRows else { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        Issue.record("slice drain did not converge", sourceLocation: sourceLocation)
    }

    /// The point of the model: opening a list never measures rows nobody can
    /// see, no matter how long the list is.
    @Test
    func initialLayoutMeasuresOnlyTheViewport() {
        let context = makeListView()
        let measured = context.adapter.measurementCounts.keys.sorted()

        // Rows start at the 44pt estimate, so the first pass reaches further
        // down than the measured heights end up covering.
        #expect(!measured.isEmpty)
        #expect(measured.count < 12)
        #expect(measured == Array(0 ..< measured.count))
        #expect(Set(measured).isSuperset(of: context.listView.indicesForVisibleRows))
        #expect(context.listView.rowLayout.pendingRowCount == Self.rowCount - measured.count)
    }

    /// Rows far shorter than the estimate pull more of themselves into view
    /// with every measurement. Layout has to keep going until nothing visible
    /// is still a guess, or the drain reshuffles the viewport a moment later.
    @Test
    func layoutConvergesWhenRowsAreMuchShorterThanTheEstimate() {
        let listView = ListView<ReflowItem>(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        listView.rows {
            ListRow(ListRowView.self)
                .height { _, _ in 1 }
                .configure { _, _, _ in }
        }
        listView.apply((0 ..< 2_000).map { ReflowItem(id: $0) })
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()

        // A 400pt viewport over 1pt rows shows 400 of them; none may be a guess.
        let visible = listView.indicesForVisibleRows
        #expect(visible.count == 400)
        #expect(listView.rowLayout.pendingRowCount == 2_000 - 400)
    }

    /// Redeclaring the row types discards every view and measurement: a
    /// height belongs to the registration that produced it.
    @Test
    func redeclaringRowsDiscardsTheOldLayout() {
        let context = makeListView(count: 50)
        let listView = context.listView
        drain(listView)
        #expect(listView.rowLayout.rowCount == 50)

        listView.rows {
            ListRow(ListRowView.self)
                .height { _, _ in 25 }
                .configure { _, _, _ in }
        }
        #expect(listView.visibleRowViews.isEmpty)

        listView.apply((0 ..< 3).map { ReflowItem(id: $0) })
        drain(listView)
        listView.layoutSubtreeIfNeeded()

        #expect(listView.rowLayout.rowCount == 3)
        #expect(listView.indicesForVisibleRows == [0, 1, 2])
        #expect(listView.rowLayout.contentHeight == 75)
        // Views left over from the previous declaration would resolve to a
        // zero frame here and overlap the real rows.
        #expect(listView.visibleRowViews.count == 3)
        let tops = listView.visibleRowViews.map(\.frame.minY).sorted()
        #expect(tops == (0 ..< 3).map { listView.rectForRow(at: $0).minY }.sorted())
    }

    /// A row nobody can measure has to settle for its estimate. Measurement
    /// runs until nothing visible is pending, so a row that stays pending for
    /// ever never lets that loop finish — this test hangs if that regresses.
    @Test
    func aRowThatCannotBeMeasuredSettlesAtTheEstimate() {
        let listView = ListView<ReflowItem>(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        listView.rows {
            ListRow(ListRowView.self)
                .when { $0.id < 0 }
                .height { _, _ in 999 }
                .configure { _, _, _ in }
        }
        // No registration claims these items, so nothing can measure them.
        // The layout that `apply` runs has to settle them anyway.
        listView.apply((0 ..< 3).map { ReflowItem(id: $0) })

        #expect(!listView.rowLayout.hasPendingRows)
        #expect(listView.rowLayout.contentHeight == 3 * listView.estimatedRowHeight)
        // And nothing is left for the drain to spin on.
        #expect(listView.rowLayout.measureRows(intersecting: listView.mountRect, anchoredAt: listView.viewportRect) == 0)
    }

    @Test
    func widthChangeMeasuresOnlyVisibleRows() {
        let context = makeMeasuredListView()
        let listView = context.listView
        listView.setContentOffset(listView.maximumContentOffset, animated: false)
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        context.adapter.measurementCounts.removeAll()

        resize(listView, toWidth: 300)

        let remeasured = context.adapter.measurementCounts.keys.sorted()
        #expect(!remeasured.isEmpty)
        #expect(remeasured.count < 12)
        #expect(listView.rowLayout.hasPendingRows)
        #expect(listView.rowLayout.pendingRowCount == Self.rowCount - remeasured.count)
        #expect(Set(listView.indicesForVisibleRows).isSuperset(of: remeasured))
    }

    /// While the width keeps changing, the drain must not measure off-screen
    /// rows — every measurement would land on a width about to be replaced.
    /// It resumes, and converges, once the width holds still.
    @Test
    func widthChurnDefersOffScreenMeasurement() {
        let context = makeMeasuredListView()
        let listView = context.listView
        resize(listView, toWidth: 300)
        context.adapter.measurementCounts.removeAll()
        resize(listView, toWidth: 320)
        let visible = Set(listView.indicesForVisibleRows)

        // Well inside the hold-off window: only visible rows may measure.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(Set(context.adapter.measurementCounts.keys).isSubset(of: visible))
        #expect(listView.rowLayout.hasPendingRows)

        drain(listView)
        let control = makeMeasuredListView(width: 320)
        #expect(listView.rowLayout.contentHeight == control.listView.rowLayout.contentHeight)
    }

    @Test
    func drainConvergesToTheFullyMeasuredResult() {
        let context = makeMeasuredListView()
        let listView = context.listView
        resize(listView, toWidth: 300)
        drain(listView)

        let control = makeMeasuredListView(width: 300)
        #expect(listView.rowLayout.contentHeight == control.listView.rowLayout.contentHeight)
        for index in 0 ..< Self.rowCount {
            #expect(listView.rowLayout.frame(for: index) == control.listView.rowLayout.frame(for: index))
        }
        #expect(!listView.rowLayout.hasPendingRows)
    }

    @Test
    func backgroundMeasurementKeepsBottomPinnedListStationary() {
        let context = makeMeasuredListView()
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

        for _ in 0 ..< 400 {
            guard listView.rowLayout.hasPendingRows else { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            listView.layoutSubtreeIfNeeded()
            #expect(listView.maximumContentOffset.y - listView.contentOffset.y == 0)
            #expect(Set(listView.indicesForVisibleRows) == visibleBefore)
        }
        #expect(!listView.rowLayout.hasPendingRows)
    }

    @Test
    func backgroundMeasurementKeepsMidListAnchorStationary() {
        let context = makeMeasuredListView()
        let listView = context.listView
        let anchorIndex = 250
        // Align the viewport top exactly with the anchor row so no straddling
        // row above it reflows visibly.
        let anchorTop = listView.rowLayout.frame(for: anchorIndex)!.minY
        listView.setContentOffset(.init(x: 0, y: anchorTop), animated: false)
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()

        resize(listView, toWidth: 300)
        let screenY = { @MainActor in
            listView.rectForRow(at: anchorIndex).minY - listView.contentOffset.y
        }
        let anchorScreenY = screenY()
        #expect(anchorScreenY == 0)

        for _ in 0 ..< 400 {
            guard listView.rowLayout.hasPendingRows else { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            listView.layoutSubtreeIfNeeded()
            #expect(screenY() == anchorScreenY)
        }
        #expect(!listView.rowLayout.hasPendingRows)
    }

    @Test
    func snapshotMutationDuringDrainStaysConsistent() {
        let context = makeMeasuredListView()
        let listView = context.listView
        resize(listView, toWidth: 300)
        #expect(listView.rowLayout.hasPendingRows)

        var items = listView.content
        items.remove(at: 10)
        items.insert(ReflowItem(id: 1_000), at: 5)
        listView.apply(items)
        drain(listView)

        let control = makeListView(width: 300, count: 0).listView
        control.apply(items)
        drain(control)

        #expect(listView.rowLayout.contentHeight == control.rowLayout.contentHeight)
        for index in 0 ..< items.count {
            #expect(listView.rowLayout.frame(for: index) == control.rowLayout.frame(for: index))
        }
    }

    /// Appending must not disturb rows that are already measured, otherwise a
    /// chat client pays for its whole history on every message.
    @Test
    func appendingKeepsExistingMeasurements() {
        let context = makeMeasuredListView()
        let listView = context.listView
        let heightBefore = listView.rowLayout.contentHeight
        context.adapter.measurementCounts.removeAll()

        listView.append(ReflowItem(id: 9_000))

        #expect(context.adapter.measurementCounts.isEmpty)
        #expect(listView.rowLayout.pendingRowCount == 1)
        #expect(listView.rowLayout.contentHeight == heightBefore + listView.estimatedRowHeight)

        drain(listView)
        #expect(context.adapter.measurementCounts.keys.sorted() == [9_000])
        #expect(
            listView.rowLayout.contentHeight
                == heightBefore + context.adapter.baseHeight(for: 9_000)
        )
    }
}
#endif
