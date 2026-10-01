#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import Testing
@testable import ListViewKit

private struct RebuildItem: Identifiable, Hashable {
    let id: Int
    var revision = 0
    var isWide = false

    /// Distinct per item and per revision, so a height carried to the wrong
    /// row, or kept past a change, shows up as a wrong number.
    var height: CGFloat { CGFloat(20 + id % 7 + revision * 100) }
}

@MainActor private final class RebuildRow: ListRowView {}

@MainActor private final class WideRebuildRow: ListRowView {}

/// An apply rebuilds the layout's rows from the items: every row starts as
/// an estimate and the ones measured before are settled on top, found by
/// identity. These pin what that rebuild produces, whichever way it finds
/// the measurements.
@Suite(.serialized)
@MainActor
struct ListRowLayoutRebuildTests {
    private static let estimate: CGFloat = 333

    private func makeList(height: CGFloat, heightDependsOnIndex: Bool = false) -> ListView<RebuildItem> {
        let list = ListView<RebuildItem>(frame: CGRect(x: 0, y: 0, width: 320, height: height))
        let row = ListRow<RebuildItem, RebuildRow>(RebuildRow.self)
            .estimatedHeight(Self.estimate)
            .height { item, _ in item.height }
            .configure { _, _, _ in }
        list.rows {
            heightDependsOnIndex ? row.heightDependsOnIndex() : row
        }
        return list
    }

    private func heights(of list: ListView<RebuildItem>) -> [CGFloat] {
        (0 ..< list.rowLayout.rowCount).map { list.rowLayout.frame(for: $0)!.height }
    }

    private func layOut(_ list: ListView<RebuildItem>) {
        #if canImport(UIKit)
            list.layoutIfNeeded()
        #elseif canImport(AppKit)
            list.layoutSubtreeIfNeeded()
        #endif
    }

    /// Few rows measured in a long list: the measurements are looked up from
    /// their side, and each has to land on its own item's new position,
    /// settled. They are off screen by the time of the rebuild, so nothing
    /// measures them again behind the rebuild's back.
    @Test
    func measuredHeightsFollowTheirItemsThroughARebuild() {
        let list = makeList(height: 100)
        var items = (0 ..< 200).map { RebuildItem(id: $0) }
        list.apply(items)
        let measuredAtTop = 200 - list.rowLayout.pendingRowCount
        #expect(measuredAtTop > 0 && measuredAtTop < 20)
        list.contentOffset.y = 3000
        layOut(list)
        let pendingBefore = list.rowLayout.pendingRowCount
        #expect(list.rowLayout.indices(intersecting: list.viewportRect).lowerBound > measuredAtTop)

        // The last value changed is not a tail append, so the whole layout
        // is rebuilt while the measured rows keep their places.
        items[199].revision = 1
        list.apply(items)
        #expect(list.rowLayout.pendingRowCount == pendingBefore)
        let rebuilt = heights(of: list)
        for index in 0 ..< measuredAtTop {
            #expect(rebuilt[index] == items[index].height)
        }
        #expect(rebuilt[199] == Self.estimate)
    }

    /// Every row measured: the items are looked up instead, and each keeps
    /// its own height, still settled, including the ones off screen.
    @Test
    func aFullyMeasuredListKeepsEveryHeightThroughARebuild() {
        let list = makeList(height: 100)
        let items = (0 ..< 60).map { RebuildItem(id: $0) }
        list.apply(items)
        _ = list.rowLayout.drainPendingRows(
            intersecting: list.mountRect,
            anchoredAt: list.viewportRect,
            deadline: .infinity
        )
        #expect(list.rowLayout.pendingRowCount == 0)

        // Dropping the last row leaves everything else where it was.
        let remaining = Array(items.dropLast())
        list.apply(remaining)
        #expect(heights(of: list) == remaining.map(\.height))
        #expect(list.rowLayout.pendingRowCount == 0)
    }

    /// A measured row whose value changed is measured again rather than
    /// keeping its old height, and a removed row's measurement is forgotten:
    /// brought back later, it starts from the estimate.
    @Test
    func aRebuildRemeasuresChangedRowsAndForgetsRemovedOnes() {
        let list = makeList(height: 100)
        var items = (0 ..< 200).map { RebuildItem(id: $0) }
        list.apply(items)
        #expect(list.rowLayout.frame(for: 0)?.height == items[0].height)

        items[0].revision = 1
        list.apply(items)
        #expect(list.rowLayout.frame(for: 0)?.height == items[0].height)

        let first = items.removeFirst()
        list.apply(items)
        items.append(first)
        list.apply(items)
        #expect(list.rowLayout.frame(for: 199)?.height == Self.estimate)
    }

    /// A page loaded above moves every row, so when the height reads the
    /// index every measurement stops holding. Each measured row comes back
    /// pending at the height it had, not at the estimate, so the content
    /// keeps its shape until the row is measured again.
    @Test
    func shiftedRowsStayPendingAtTheirMeasuredHeight() {
        let list = makeList(height: 100, heightDependsOnIndex: true)
        var items = (0 ..< 200).map { RebuildItem(id: $0) }
        list.apply(items)
        let measuredAtTop = 200 - list.rowLayout.pendingRowCount
        #expect(measuredAtTop > 0 && measuredAtTop < 20)
        list.contentOffset.y = 6000
        layOut(list)

        let page = (1000 ..< 1003).map { RebuildItem(id: $0) }
        items.insert(contentsOf: page, at: 0)
        list.apply(items)
        for index in page.count ..< page.count + measuredAtTop {
            let frame = list.rowLayout.frame(for: index)!
            #expect(frame.height == items[index].height)
            #expect(list.rowLayout.hasPendingRows(intersecting: frame))
        }
        #expect(list.rowLayout.frame(for: page.count + measuredAtTop)?.height == Self.estimate)
    }

    /// With a conditional row in front, the estimate depends on the item, so
    /// it cannot be shared across the rows.
    @Test
    func eachRowTakesItsOwnRegistrationsEstimate() {
        let list = ListView<RebuildItem>(frame: CGRect(x: 0, y: 0, width: 320, height: 10))
        list.rows {
            ListRow(WideRebuildRow.self)
                .when(\.isWide)
                .estimatedHeight(300)
                .height { _, _ in 50 }
                .configure { _, _, _ in }
            ListRow(RebuildRow.self)
                .estimatedHeight(30)
                .height { _, _ in 10 }
                .configure { _, _, _ in }
        }
        list.apply((0 ..< 40).map { RebuildItem(id: $0, isWide: $0.isMultiple(of: 4)) })

        // Row 0 is the one the viewport measured.
        let rows = heights(of: list)
        #expect(rows[0] == 50)
        for index in 1 ..< 40 {
            #expect(rows[index] == (index.isMultiple(of: 4) ? 300 : 30))
        }
    }
}
