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

    /// Every loop here runs once per item, and the list is generic over a type
    /// from another module, so nothing in them is specialized: each hash, each
    /// `id` and each comparison goes through a witness table. What keeps an
    /// apply cheap is doing fewer of those per item, not doing them faster.
    init(from old: [Item], to new: [Item], indexByID oldIndexByID: [Item.ID: Int]) {
        // Nothing to compare against, so every item is new. This is a list's
        // first load, and it needs no lookups at all.
        guard !old.isEmpty else {
            var indexByID = [Item.ID: Int](minimumCapacity: new.count)
            var added: [Item.ID] = []
            added.reserveCapacity(new.count)
            for index in new.indices {
                let identifier = new[index].id
                let displaced = indexByID.updateValue(index, forKey: identifier)
                precondition(displaced == nil, "duplicate identifier \(identifier) in the new content.")
                added.append(identifier)
            }
            self.indexByID = indexByID
            removed = []
            self.added = added
            changed = []
            moved = []
            return
        }

        // Items whose identifiers line up at either end are known to survive
        // without looking them up, and their old position is known without
        // the old index. Typical edits — an append, a page of history loaded
        // above, one row changed — leave almost everything in these two runs.
        let shorter = min(old.count, new.count)
        var prefix = 0
        while prefix < shorter, old[prefix].id == new[prefix].id {
            prefix += 1
        }
        var suffix = 0
        while suffix < shorter - prefix,
              old[old.count - 1 - suffix].id == new[new.count - 1 - suffix].id
        {
            suffix += 1
        }
        let shift = new.count - old.count
        let oldMiddle = prefix ..< old.count - suffix
        let newMiddle = prefix ..< new.count - suffix
        let newSuffix = newMiddle.upperBound ..< new.count

        // The two runs hold the identifiers they held before, which the old
        // index already proved unique, so only the middle can bring in a
        // duplicate. When the runs are most of the list, the old index is
        // carried over rather than hashing every identifier in them again:
        // only the suffix positions change, and all by the same shift.
        var indexByID: [Item.ID: Int]
        if oldMiddle.count < prefix + suffix {
            let oldSuffixStart = oldMiddle.upperBound
            indexByID = shift == 0 ? oldIndexByID : oldIndexByID.mapValues {
                $0 < oldSuffixStart ? $0 : $0 + shift
            }
            for index in oldMiddle {
                indexByID.removeValue(forKey: old[index].id)
            }
            indexByID.reserveCapacity(new.count)
        } else {
            indexByID = .init(minimumCapacity: new.count)
            for index in 0 ..< prefix {
                indexByID[new[index].id] = index
            }
            for index in newSuffix {
                indexByID[new[index].id] = index
            }
        }

        var added: [Item.ID] = []
        var changed: [Item.ID] = []
        var moved: [Item.ID] = []
        // The prefix kept its index, so it can only have changed.
        for index in 0 ..< prefix where old[index] != new[index] {
            changed.append(new[index].id)
        }
        for index in newMiddle {
            let item = new[index]
            let identifier = item.id
            let displaced = indexByID.updateValue(index, forKey: identifier)
            precondition(displaced == nil, "duplicate identifier \(identifier) in the new content.")

            guard let previousIndex = oldIndexByID[identifier] else {
                added.append(identifier)
                continue
            }
            if old[previousIndex] != item {
                changed.append(identifier)
            } else if previousIndex != index {
                moved.append(identifier)
            }
        }
        // The whole suffix moved by however much the count changed.
        for index in newSuffix {
            if old[index - shift] != new[index] {
                changed.append(new[index].id)
            } else if shift != 0 {
                moved.append(new[index].id)
            }
        }

        // Only the old middle can hold anything that is gone.
        var removed: [Item.ID] = []
        for index in oldMiddle {
            let identifier = old[index].id
            if indexByID[identifier] == nil {
                removed.append(identifier)
            }
        }

        self.indexByID = indexByID
        self.removed = removed
        self.added = added
        self.changed = changed
        self.moved = moved
    }
}
