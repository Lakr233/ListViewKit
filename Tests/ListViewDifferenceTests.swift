#if canImport(UIKit)
// UIKit platforms (including Mac Catalyst) are exercised by the UIKit suites.
#elseif canImport(AppKit)
import Testing
@testable import ListViewKit

private struct DiffItem: Identifiable, Hashable {
    let id: Int
    var revision = 0
}

/// The classification exactly as it was first written: one pass over each
/// side, looking every item up. The fast paths have to agree with it.
private struct SinglePassDifference {
    var indexByID: [Int: Int] = [:]
    var removed: [Int] = []
    var added: [Int] = []
    var changed: [Int] = []
    var moved: [Int] = []

    init(from old: [DiffItem], to new: [DiffItem], indexByID oldIndexByID: [Int: Int]) {
        for (index, item) in new.enumerated() {
            indexByID[item.id] = index
            guard let previousIndex = oldIndexByID[item.id] else {
                added.append(item.id)
                continue
            }
            if old[previousIndex] != item {
                changed.append(item.id)
            } else if previousIndex != index {
                moved.append(item.id)
            }
        }
        for item in old where indexByID[item.id] == nil {
            removed.append(item.id)
        }
    }
}

/// Deterministic so a failure reproduces exactly.
private struct DiffRandom {
    var state: UInt64

    mutating func int(below bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return bound <= 0 ? 0 : Int((z ^ (z >> 31)) % UInt64(bound))
    }
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
        // Only a new value needs measuring again. A row that only moved still
        // has the height it was measured at.
        #expect(result.changed == [3])
        #expect(result.moved == [4])
        #expect(result.indexByID == [1: 0, 4: 1, 3: 2, 5: 3])
    }

    /// An item that both moved and changed value is a change: its height has
    /// to be measured again whatever its registration says about the index.
    @Test
    func aMoveWithANewValueIsAChange() {
        let result = difference([1, 2, 3], [
            DiffItem(id: 3, revision: 1),
            DiffItem(id: 1),
            DiffItem(id: 2),
        ])

        #expect(result.changed == [3])
        #expect(result.moved == [1, 2])
    }

    /// Prepending a page of history moves every row already there, and none
    /// of them changed.
    @Test
    func aPrependOnlyMovesTheRowsAlreadyThere() {
        let result = difference(Array(0 ..< 100), (100 ..< 105).map { DiffItem(id: $0) }
            + (0 ..< 100).map { DiffItem(id: $0) })

        #expect(result.added == Array(100 ..< 105))
        #expect(result.changed.isEmpty)
        #expect(result.moved == Array(0 ..< 100))
        #expect(!result.isEmpty)
        #expect(!result.isTailAppend(previousCount: 100))
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

        let appendedAndMoved = difference([1, 2], [2, 1, 3].map { DiffItem(id: $0) })
        #expect(!appendedAndMoved.isTailAppend(previousCount: 2))

        let unchanged = difference([1, 2], [1, 2].map { DiffItem(id: $0) })
        #expect(!unchanged.isTailAppend(previousCount: 2))
    }

    /// A first load skips the lookups entirely, and has to come out exactly
    /// as an append onto nothing.
    @Test
    func everythingIsAddedIntoAnEmptyList() {
        let result = difference([], [3, 1, 2].map { DiffItem(id: $0) })
        #expect(result.added == [3, 1, 2])
        #expect(result.removed.isEmpty)
        #expect(result.changed.isEmpty)
        #expect(result.moved.isEmpty)
        #expect(result.indexByID == [3: 0, 1: 1, 2: 2])
        #expect(result.isTailAppend(previousCount: 0))

        #expect(difference([], []).isEmpty)
    }

    /// Rows matched at either end skip their lookups, but not their
    /// classification: a run that shifted still moved, and a value that
    /// changed inside a run still changed.
    @Test
    func rowsMatchedAtEitherEndAreClassifiedAsBefore() {
        // A page of history above: everything below it moved.
        let prepended = difference([1, 2, 3], [10, 11, 1, 2, 3].map { DiffItem(id: $0) })
        #expect(prepended.added == [10, 11])
        #expect(prepended.changed.isEmpty)
        #expect(prepended.moved == [1, 2, 3])
        #expect(prepended.removed.isEmpty)

        // Rows dropped off the top: everything left moved up.
        let trimmed = difference([1, 2, 3, 4], [3, 4].map { DiffItem(id: $0) })
        #expect(trimmed.removed == [1, 2])
        #expect(trimmed.changed.isEmpty)
        #expect(trimmed.moved == [3, 4])
        #expect(trimmed.added.isEmpty)

        // One row in the middle replaced: both ends stayed put.
        let replaced = difference([1, 2, 3, 4], [1, 5, 3, 4].map { DiffItem(id: $0) })
        #expect(replaced.removed == [2])
        #expect(replaced.added == [5])
        #expect(replaced.changed.isEmpty)
        #expect(replaced.moved.isEmpty)

        // Value changes at the very first and very last row.
        let edited = difference([1, 2, 3], [
            DiffItem(id: 1, revision: 1),
            DiffItem(id: 2),
            DiffItem(id: 3, revision: 1),
        ])
        #expect(edited.changed == [1, 3])
        #expect(edited.moved.isEmpty)
        #expect(edited.added.isEmpty)
        #expect(edited.removed.isEmpty)

        // A value change inside a shifted run is a change, not also a move.
        let shiftedAndEdited = difference([1, 2], [
            DiffItem(id: 9),
            DiffItem(id: 1),
            DiffItem(id: 2, revision: 1),
        ])
        #expect(shiftedAndEdited.added == [9])
        #expect(shiftedAndEdited.moved == [1])
        #expect(shiftedAndEdited.changed == [2])
        #expect(shiftedAndEdited.indexByID == [9: 0, 1: 1, 2: 2])
    }

    /// The classification is defined by the single pass the fast paths
    /// replaced. Random edits of every kind, at random places, have to come
    /// out identical to it, order included.
    @Test
    func matchesTheSinglePassClassificationUnderRandomEdits() {
        var random = DiffRandom(state: 0xD1FF)
        var nextID = 1_000
        for _ in 0 ..< 2_000 {
            let old = (0 ..< random.int(below: 24)).map { DiffItem(id: $0, revision: random.int(below: 2)) }
            var new = old
            for _ in 0 ..< random.int(below: 4) {
                switch random.int(below: 5) {
                case 0:
                    new.insert(DiffItem(id: nextID), at: random.int(below: new.count + 1))
                    nextID += 1
                case 1 where !new.isEmpty:
                    new.remove(at: random.int(below: new.count))
                case 2 where !new.isEmpty:
                    let moved = new.remove(at: random.int(below: new.count))
                    new.insert(moved, at: random.int(below: new.count + 1))
                case 3 where !new.isEmpty:
                    new[random.int(below: new.count)].revision += 1
                case 4:
                    // A page at either end, the shape the fast paths target.
                    let page = (0 ..< random.int(below: 6)).map { _ in
                        defer { nextID += 1 }
                        return DiffItem(id: nextID)
                    }
                    new = random.int(below: 2) == 0 ? page + new : new + page
                default:
                    continue
                }
            }

            var indexByID: [Int: Int] = [:]
            for (index, item) in old.enumerated() {
                indexByID[item.id] = index
            }
            let result = ListDifference(from: old, to: new, indexByID: indexByID)
            let expected = SinglePassDifference(from: old, to: new, indexByID: indexByID)
            #expect(result.indexByID == expected.indexByID)
            #expect(result.removed == expected.removed)
            #expect(result.added == expected.added)
            #expect(result.changed == expected.changed)
            #expect(result.moved == expected.moved)
        }
    }

    /// A duplicate has to be caught wherever it sits: in a run matched at
    /// either end, in the middle, or on a first load.
    @Test(arguments: [
        ([1, 2], [1, 1, 2]),
        ([1, 2], [1, 2, 2]),
        ([1, 2, 3], [1, 3, 3]),
        ([1, 2, 3], [1, 4, 4, 3]),
        ([], [5, 5]),
    ])
    func aDuplicateIdentifierStopsTheApply(old: [Int], new: [Int]) async {
        await #expect(processExitsWith: .failure) { [old, new] in
            let oldItems = old.map { DiffItem(id: $0) }
            var indexByID: [Int: Int] = [:]
            for (index, item) in oldItems.enumerated() {
                indexByID[item.id] = index
            }
            _ = ListDifference(from: oldItems, to: new.map { DiffItem(id: $0) }, indexByID: indexByID)
        }
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
