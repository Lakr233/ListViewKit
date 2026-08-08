//
//  ListViewDiffableDataSource+Difference.swift
//  ListViewKit
//
//  Created by 秋星桥 on 5/22/25.
//

import Foundation
import OrderedCollections

extension ListViewDiffableDataSource {
    struct SequenceDiffResult<T: Hashable> {
        let elements: OrderedDictionary<T, Item>

        let removed: [Index]
        let added: [Index]
        let updated: [Index]
        let reordered: [ReorderIndex]

        var isEmpty: Bool {
            removed.isEmpty && added.isEmpty && updated.isEmpty && reordered.isEmpty
        }

        /// True when the only change is rows appended past `previousCount`.
        /// The layout can absorb those without revisiting the rows already
        /// there, which is what keeps a chat client's send path off O(n).
        func isTailAppend(previousCount: Int) -> Bool {
            removed.isEmpty && updated.isEmpty && reordered.isEmpty
                && !added.isEmpty
                && added.count == elements.count - previousCount
                && added[0].index == previousCount
        }
    }
}

extension ListViewDiffableDataSource.SequenceDiffResult {
    struct Index {
        let index: Int
        let identifier: T
    }

    struct ReorderIndex {
        let oldIndex: Int
        let newIndex: Int
        let identifier: T
    }
}

extension ListViewDiffableDataSource {
    /// Classifies `other` against the current elements in one pass over each.
    ///
    /// The intermediate key sets and index maps this used to build were three
    /// `Set`s and two `Dictionary`s the size of the list, allocated on every
    /// apply. An `OrderedDictionary` already answers "where is this key" in
    /// constant time, so the only collection built here is the result itself.
    ///
    /// Walking positions rather than key sets also makes the output
    /// deterministic; iterating a `Set` previously varied the order of
    /// `removed` and `added` between runs.
    func difference(with other: [Item]) -> SequenceDiffResult<Item.ID> {
        var newElements = OrderedDictionary<Item.ID, Item>(minimumCapacity: other.count)
        var added = [SequenceDiffResult<Item.ID>.Index]()
        var updated = [SequenceDiffResult<Item.ID>.Index]()
        var reordered = [SequenceDiffResult<Item.ID>.ReorderIndex]()

        for (newIndex, item) in other.enumerated() {
            // The unique-key initializer this replaces trapped on duplicates in
            // every build, and the indices below are only meaningful while one
            // position maps to one identifier.
            let displaced = newElements.updateValue(item, forKey: item.id)
            precondition(displaced == nil, "duplicate identifier \(item.id) in the new collection.")

            guard let oldIndex = elements.index(forKey: item.id) else {
                added.append(.init(index: newIndex, identifier: item.id))
                continue
            }
            if elements.values[oldIndex] != item {
                updated.append(.init(index: newIndex, identifier: item.id))
            } else if oldIndex != newIndex {
                reordered.append(.init(
                    oldIndex: oldIndex,
                    newIndex: newIndex,
                    identifier: item.id
                ))
            }
        }

        var removed = [SequenceDiffResult<Item.ID>.Index]()
        for (oldIndex, identifier) in elements.keys.enumerated()
            where newElements[identifier] == nil
        {
            removed.append(.init(index: oldIndex, identifier: identifier))
        }

        return .init(
            elements: newElements,
            removed: removed,
            added: added,
            updated: updated,
            reordered: reordered
        )
    }
}
