//
//  ListDifference.swift
//  ListViewKit
//

/// What changed between two orderings of the same item type.
///
/// Classified in one pass over each side. A position change and a value change
/// are the same event here — both mean the row has to be filled in and
/// measured again — so they are not split into categories no caller
/// distinguishes.
struct ListDifference<Item: Identifiable & Hashable & SendableMetatype> {
    /// Position of every identifier in the new ordering, which the list keeps
    /// as its index.
    let indexByID: [Item.ID: Int]
    let removed: [Item.ID]
    let added: [Item.ID]
    /// Items that survived but moved or changed value.
    let remeasured: [Item.ID]

    var isEmpty: Bool {
        removed.isEmpty && added.isEmpty && remeasured.isEmpty
    }

    /// True when the only change is items appended past `previousCount`. The
    /// layout can absorb those without revisiting the rows already there,
    /// which is what keeps a chat client's send path off O(n).
    ///
    /// Nothing removed and nothing remeasured means every surviving item kept
    /// its index, so the new ones can only be at the end.
    func isTailAppend(previousCount: Int) -> Bool {
        removed.isEmpty && remeasured.isEmpty && !added.isEmpty
            && added.count == indexByID.count - previousCount
    }

    init(from old: [Item], to new: [Item], indexByID oldIndexByID: [Item.ID: Int]) {
        var indexByID = [Item.ID: Int](minimumCapacity: new.count)
        var added: [Item.ID] = []
        var remeasured: [Item.ID] = []

        for (index, item) in new.enumerated() {
            let displaced = indexByID.updateValue(index, forKey: item.id)
            precondition(displaced == nil, "duplicate identifier \(item.id) in the new content.")

            guard let previousIndex = oldIndexByID[item.id] else {
                added.append(item.id)
                continue
            }
            if previousIndex != index || old[previousIndex] != item {
                remeasured.append(item.id)
            }
        }

        var removed: [Item.ID] = []
        for item in old where indexByID[item.id] == nil {
            removed.append(item.id)
        }

        self.indexByID = indexByID
        self.removed = removed
        self.added = added
        self.remeasured = remeasured
    }
}
