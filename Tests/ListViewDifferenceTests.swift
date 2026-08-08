#if canImport(UIKit)
// UIKit platforms (including Mac Catalyst) are exercised by the UIKit suites.
#elseif canImport(AppKit)
import Testing
@testable import ListViewKit

private struct DiffItem: Identifiable, Hashable {
    let id: Int
    var revision = 0
}

@Suite
struct ListViewDifferenceTests {
    private func difference(_ old: [Int], _ new: [DiffItem]) -> ListDifference<DiffItem> {
        let oldItems = old.map { DiffItem(id: $0) }
        var indexByID: [Int: Int] = [:]
        for (index, item) in oldItems.enumerated() {
            indexByID[item.id] = index
        }
        return ListDifference(from: oldItems, to: new, indexByID: indexByID)
    }

    @Test
    func classifiesEachKindOfChange() {
        // 2 is dropped, 5 is new, 3 changes value, and 4 moves ahead of 3.
        let result = difference([1, 2, 3, 4], [
            DiffItem(id: 1),
            DiffItem(id: 4),
            DiffItem(id: 3, revision: 1),
            DiffItem(id: 5),
        ])

        #expect(result.removed == [2])
        #expect(result.added == [5])
        // A move and a value change are the same event: both need the row
        // filled in and measured again.
        #expect(result.remeasured == [4, 3])
        #expect(result.indexByID == [1: 0, 4: 1, 3: 2, 5: 3])
    }

    @Test
    func anUnchangedCollectionProducesNoWork() {
        let result = difference([1, 2, 3], [1, 2, 3].map { DiffItem(id: $0) })
        #expect(result.isEmpty)
    }

    /// The fast path must only trigger when nothing before the new rows moved.
    @Test
    func onlyPureTailGrowthCountsAsAnAppend() {
        let appended = difference([1, 2], [1, 2, 3].map { DiffItem(id: $0) })
        #expect(appended.isTailAppend(previousCount: 2))

        let prepended = difference([1, 2], [3, 1, 2].map { DiffItem(id: $0) })
        #expect(!prepended.isTailAppend(previousCount: 2))

        let appendedAndChanged = difference([1, 2], [
            DiffItem(id: 1),
            DiffItem(id: 2, revision: 1),
            DiffItem(id: 3),
        ])
        #expect(!appendedAndChanged.isTailAppend(previousCount: 2))

        let appendedAndRemoved = difference([1, 2], [DiffItem(id: 1), DiffItem(id: 3)])
        #expect(!appendedAndRemoved.isTailAppend(previousCount: 2))

        let unchanged = difference([1, 2], [1, 2].map { DiffItem(id: $0) })
        #expect(!unchanged.isTailAppend(previousCount: 2))
    }

    /// Classification used to iterate Sets, so the order of removed and added
    /// varied between runs and made a batch update unreproducible.
    @Test
    func outputIsOrderedByPositionAndStableAcrossRuns() {
        let ids = Array(0 ..< 64)
        let survivors = ids.filter { !$0.isMultiple(of: 3) }
        let newcomers = (100 ..< 120).map { DiffItem(id: $0) }
        let expectedRemoved = ids.filter { $0.isMultiple(of: 3) }

        for _ in 0 ..< 8 {
            let result = difference(ids, survivors.map { DiffItem(id: $0) } + newcomers)
            #expect(result.removed == expectedRemoved)
            #expect(result.added == newcomers.map(\.id))
        }
    }
}
#endif
