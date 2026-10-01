//
//  ListViewMoveTests.swift
//  ListViewKit
//

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import Testing
@testable import ListViewKit

private struct MoveItem: Identifiable, Hashable {
    let id: Int
}

/// Who was measured and configured, and with which index.
@MainActor
private final class MoveProbe {
    var measurementCounts: [Int: Int] = [:]
    var configurationCounts: [Int: Int] = [:]
    var configuredIndex: [Int: Int] = [:]

    /// Distinct per item, and never the list's estimate, so a row that lost
    /// its measurement shows up as a different height.
    static func height(of item: MoveItem) -> CGFloat {
        60 + CGFloat(item.id % 3) * 20
    }

    func measure(_ item: MoveItem, height: CGFloat) -> CGFloat {
        measurementCounts[item.id, default: 0] += 1
        return height
    }

    func configure(_ item: MoveItem, _ context: ListRowContext) {
        configurationCounts[item.id, default: 0] += 1
        configuredIndex[item.id] = context.index
    }
}

/// A row that keeps its value keeps its measured height wherever it moves to,
/// unless its registration says the height reads the index.
@Suite(.serialized)
@MainActor
struct ListViewMoveTests {
    private func makeListView(
        rows: (ListView<MoveItem>) -> Void,
        count: Int
    ) -> ListView<MoveItem> {
        let listView = ListView<MoveItem>(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        rows(listView)
        listView.apply((0 ..< count).map { MoveItem(id: $0) })
        drain(listView)
        return listView
    }

    private func layout(_ listView: ListView<MoveItem>) {
        #if canImport(UIKit)
            listView.setNeedsLayout()
            listView.layoutIfNeeded()
        #elseif canImport(AppKit)
            listView.needsLayout = true
            listView.layoutSubtreeIfNeeded()
        #endif
    }

    private func drain(_ listView: ListView<MoveItem>) {
        layout(listView)
        for _ in 0 ..< 200 where listView.rowLayout.hasPendingRows {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        layout(listView)
    }

    private func mountedIDs(_ listView: ListView<MoveItem>) -> Set<Int> {
        Set(listView.content.map(\.id).filter { listView.rowView(for: $0) != nil })
    }

    /// Loading a page of history above the rows already there moves every one
    /// of them. Measuring them all again is the cost this avoids.
    @Test
    func aPrependMeasuresOnlyTheNewRows() {
        let probe = MoveProbe()
        let listView = makeListView(rows: { list in
            list.rows {
                ListRow(ListRowView.self)
                    .height { item, _ in probe.measure(item, height: MoveProbe.height(of: item)) }
                    .configure { _, item, context in probe.configure(item, context) }
            }
        }, count: 60)
        listView.scrollToBottom(animated: false)
        drain(listView)
        let measuredBefore = probe.measurementCounts
        let configuredBefore = probe.configurationCounts
        let mountedBefore = mountedIDs(listView)

        let page = (1000 ..< 1005).map { MoveItem(id: $0) }
        listView.apply(page + listView.content)
        // The page goes in at its estimate, above the fold.
        #expect(listView.rowLayout.pendingRowCount == page.count)
        let lastRowScreenY = listView.rectForRow(at: 64).minY - listView.contentOffset.y
        drain(listView)

        for id in 0 ..< 60 {
            #expect(probe.measurementCounts[id] == measuredBefore[id])
            #expect(listView.rectForRow(with: id).height == MoveProbe.height(of: MoveItem(id: id)))
        }
        for item in page {
            #expect(probe.measurementCounts[item.id] == 1)
        }
        let expectedHeight = listView.content.reduce(0) { $0 + MoveProbe.height(of: $1) }
        #expect(listView.contentSize.height == expectedHeight)
        // Measuring the page changed heights above the fold, which the offset
        // absorbs: the reader stays where they were.
        #expect(listView.rectForRow(at: 64).minY - listView.contentOffset.y == lastRowScreenY)

        // A mounted row shows its index, so it is filled in again with the new
        // one. A row nobody can see is left alone until it is mounted.
        let mountedAfter = mountedIDs(listView)
        for id in mountedAfter {
            #expect(probe.configuredIndex[id] == listView.index(of: id))
        }
        for id in 0 ..< 60 where !mountedBefore.contains(id) && !mountedAfter.contains(id) {
            #expect(probe.configurationCounts[id] == configuredBefore[id])
        }
    }

    /// A shuffle moves every row without changing one: the rows on screen are
    /// filled in again with their new index, and nothing is measured.
    @Test
    func aShuffleRefillsTheMountedRowsWithoutMeasuring() {
        let probe = MoveProbe()
        let listView = makeListView(rows: { list in
            list.rows {
                ListRow(ListRowView.self)
                    .height { item, _ in probe.measure(item, height: MoveProbe.height(of: item)) }
                    .configure { _, item, context in probe.configure(item, context) }
            }
        }, count: 30)
        let measuredBefore = probe.measurementCounts

        listView.apply(listView.content.reversed(), animated: true)
        drain(listView)

        #expect(probe.measurementCounts == measuredBefore)
        let mounted = mountedIDs(listView)
        #expect(!mounted.isEmpty)
        for id in mounted {
            #expect(probe.configuredIndex[id] == listView.index(of: id))
        }
        for (index, item) in listView.content.enumerated() {
            #expect(listView.rectForRow(at: index).height == MoveProbe.height(of: item))
        }
    }

    /// Only the registration that declared it pays for it: its rows are
    /// measured again when they move, and the others' are not.
    @Test
    func aHeightThatReadsTheIndexIsMeasuredAgainWhenItMoves() {
        let probe = MoveProbe()
        func indexedHeight(_ index: Int) -> CGFloat {
            index.isMultiple(of: 2) ? 50 : 90
        }
        let listView = makeListView(rows: { list in
            list.rows {
                ListRow(ListRowView.self)
                    .when { $0.id.isMultiple(of: 2) }
                    .height { item, context in probe.measure(item, height: indexedHeight(context.index)) }
                    .heightDependsOnIndex()
                    .configure { _, item, context in probe.configure(item, context) }
                ListRow(ListRowView.self)
                    .height { item, _ in probe.measure(item, height: 70) }
                    .configure { _, item, context in probe.configure(item, context) }
            }
        }, count: 30)
        let measuredBefore = probe.measurementCounts

        // One row in front shifts every index by one, flipping the parity.
        listView.apply([MoveItem(id: 1001)] + listView.content)
        drain(listView)

        for (index, item) in listView.content.enumerated() {
            let expected = item.id.isMultiple(of: 2) ? indexedHeight(index) : 70
            #expect(listView.rectForRow(at: index).height == expected)
        }
        for id in 0 ..< 30 {
            let extra = id.isMultiple(of: 2) ? 1 : 0
            #expect(probe.measurementCounts[id] == measuredBefore[id, default: 0] + extra)
        }
    }
}
