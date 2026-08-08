#if canImport(UIKit)
// UIKit platforms (including Mac Catalyst) are exercised by the UIKit suites.
#elseif canImport(AppKit)
import AppKit
import Testing
@testable import ListViewKit

private struct DiffItem: Identifiable, Hashable {
    let id: Int
    var revision = 0
}

@Suite(.serialized)
@MainActor
struct ListViewDifferenceTests {
    private func makeDataSource(
        _ ids: [Int]
    ) -> ListViewDiffableDataSource<DiffItem> {
        let listView = ListView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        let dataSource = ListViewDiffableDataSource<DiffItem>(listView: listView)
        dataSource.elements = .init(uniqueKeysWithValues: ids.map { ($0, DiffItem(id: $0)) })
        return dataSource
    }

    @Test
    func classifiesEachKindOfChangeWithItsIndex() {
        let dataSource = makeDataSource([1, 2, 3, 4])
        // 2 is dropped, 5 is new, 3 changes value, and 4 moves ahead of 3.
        let result = dataSource.difference(with: [
            DiffItem(id: 1),
            DiffItem(id: 4),
            DiffItem(id: 3, revision: 1),
            DiffItem(id: 5),
        ])

        #expect(result.removed.map(\.identifier) == [2])
        #expect(result.removed.map(\.index) == [1])
        #expect(result.added.map(\.identifier) == [5])
        #expect(result.added.map(\.index) == [3])
        #expect(result.updated.map(\.identifier) == [3])
        #expect(result.updated.map(\.index) == [2])
        #expect(result.reordered.map(\.identifier) == [4])
        #expect(result.reordered.map { [$0.oldIndex, $0.newIndex] } == [[3, 1]])
        #expect(Array(result.elements.keys) == [1, 4, 3, 5])
    }

    /// A value change and a position change are not the same event: an item
    /// that moved without changing still holds its measured height.
    @Test
    func anUpdatedItemIsNotAlsoReportedAsReordered() {
        let dataSource = makeDataSource([1, 2])
        let result = dataSource.difference(with: [
            DiffItem(id: 2, revision: 1),
            DiffItem(id: 1),
        ])

        #expect(result.updated.map(\.identifier) == [2])
        #expect(result.reordered.map(\.identifier) == [1])
    }

    @Test
    func anUnchangedCollectionProducesNoWork() {
        let dataSource = makeDataSource([1, 2, 3])
        let result = dataSource.difference(with: [
            DiffItem(id: 1),
            DiffItem(id: 2),
            DiffItem(id: 3),
        ])
        #expect(result.isEmpty)
    }

    /// Classification used to iterate `Set`s, so the order of `removed` and
    /// `added` varied between runs and made batch updates unreproducible.
    @Test
    func outputIsOrderedByPositionAndStableAcrossRuns() {
        let ids = Array(0 ..< 64)
        let survivors = ids.filter { !$0.isMultiple(of: 3) }
        let newcomers = (100 ..< 120).map { DiffItem(id: $0) }

        let expectedRemoved = ids.filter { $0.isMultiple(of: 3) }
        var previous: ([Int], [Int])?
        for _ in 0 ..< 8 {
            let dataSource = makeDataSource(ids)
            let result = dataSource.difference(
                with: survivors.map { DiffItem(id: $0) } + newcomers
            )
            #expect(result.removed.map(\.identifier) == expectedRemoved)
            #expect(result.removed.map(\.index) == expectedRemoved)
            #expect(result.added.map(\.identifier) == newcomers.map(\.id))
            #expect(result.added.map(\.index).sorted() == result.added.map(\.index))

            let observed = (result.removed.map(\.identifier), result.added.map(\.identifier))
            if let previous {
                #expect(previous.0 == observed.0)
                #expect(previous.1 == observed.1)
            }
            previous = observed
        }
    }
}
#endif
