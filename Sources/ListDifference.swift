//
//  ListDifference.swift
//  ListViewKit
//

/// What changed between two orderings of the same item type.
///
/// Classified in one pass over each side. A value change and a position change
/// are kept apart because they cost different things: a new value has to be
/// filled in and measured again, while a row that only moved still has the
/// height it was measured at. Prepending a page of history moves every row
/// already in the list, and treating that as a change would throw away every
/// measurement the list holds.
struct ListDifference<Item: Identifiable & Hashable & SendableMetatype> {
    /// Position of every identifier in the new ordering, which the list keeps
    /// as its index.
    let indexByID: [Item.ID: Int]
    let removed: [Item.ID]
    let added: [Item.ID]
    /// Items that survived with a different value, whether or not they also
    /// moved.
    let changed: [Item.ID]
    /// Items that survived with the same value at a different index.
    let moved: [Item.ID]

    var isEmpty: Bool {
        removed.isEmpty && added.isEmpty && changed.isEmpty && moved.isEmpty
    }

    /// True when the only change is items appended past `previousCount`. The
    /// layout can absorb those without revisiting the rows already there,
    /// which is what keeps a chat client's send path off O(n).
    ///
    /// Nothing removed, changed or moved means every surviving item kept its
    /// index, so the new ones can only be at the end.
    func isTailAppend(previousCount: Int) -> Bool {
        removed.isEmpty && changed.isEmpty && moved.isEmpty && !added.isEmpty
            && added.count == indexByID.count - previousCount
    }

    init(from old: [Item], to new: [Item], indexByID oldIndexByID: [Item.ID: Int]) {
        var indexByID = [Item.ID: Int](minimumCapacity: new.count)
        var added: [Item.ID] = []
        var changed: [Item.ID] = []
        var moved: [Item.ID] = []

        for (index, item) in new.enumerated() {
            let displaced = indexByID.updateValue(index, forKey: item.id)
            precondition(displaced == nil, "duplicate identifier \(item.id) in the new content.")

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

        var removed: [Item.ID] = []
        for item in old where indexByID[item.id] == nil {
            removed.append(item.id)
        }

        self.indexByID = indexByID
        self.removed = removed
        self.added = added
        self.changed = changed
        self.moved = moved
    }
}
