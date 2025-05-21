//
//  ListViewDiffableDataSource+Difference.swift
//  ListViewKit
//
//  Created by 秋星桥 on 5/22/25.
//

import Foundation
import OrderedCollections

extension ListViewDiffableDataSource {
    struct SequenceDiffResult<T> where T: Hashable {
        let elements: OrderedDictionary<T, Item>

        let removed: [Index]
        let added: [Index]
        let updated: [Index]
        let reordered: [ReorderIndex]

        var isEmpty: Bool {
            removed.isEmpty && added.isEmpty && updated.isEmpty && reordered.isEmpty
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
    func difference(with other: [Item]) -> SequenceDiffResult<Item.ID> {
        let snapshot: OrderedDictionary<Item.ID, Item> = .init(uniqueKeysWithValues: other.map {
            ($0.id, $0)
        })
        assert(
            snapshot.count == other.count,
            "duplicate identifiers found in the new collection."
        )

        let oldKeys = Set(elements.keys)
        let newKeys = Set(snapshot.keys)
        let removedKeys = oldKeys.subtracting(newKeys)
        let addedKeys = newKeys.subtracting(oldKeys)
        let commonKeys = oldKeys.intersection(newKeys)

        var oldIndexMap = [Item.ID: Int]()
        var newIndexMap = [Item.ID: Int]()

        for identifier in commonKeys {
            oldIndexMap[identifier] = elements.index(forKey: identifier)!
            newIndexMap[identifier] = snapshot.index(forKey: identifier)!
        }

        let removed = removedKeys.map { identifier in
            SequenceDiffResult<Item.ID>.Index(
                index: elements.index(forKey: identifier)!,
                identifier: identifier
            )
        }

        let added = addedKeys.map { identifier in
            SequenceDiffResult<Item.ID>.Index(
                index: snapshot.index(forKey: identifier)!,
                identifier: identifier
            )
        }

        var updated = [SequenceDiffResult<Item.ID>.Index]()
        var reordered = [SequenceDiffResult<Item.ID>.ReorderIndex]()

        for identifier in commonKeys {
            let oldIndex = oldIndexMap[identifier]!
            let newIndex = newIndexMap[identifier]!

            if elements[identifier] != snapshot[identifier] {
                updated.append(.init(
                    index: newIndex,
                    identifier: identifier
                ))
            } else if oldIndex != newIndex {
                reordered.append(.init(
                    oldIndex: oldIndex,
                    newIndex: newIndex,
                    identifier: identifier
                ))
            }
        }

        return .init(
            elements: snapshot,
            removed: removed,
            added: added,
            updated: updated,
            reordered: reordered
        )
    }
}
