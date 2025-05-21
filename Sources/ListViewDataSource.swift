//
//  Created by ktiays on 2025/1/14.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import OrderedCollections
import UIKit

/// The methods that an object adopts to manage data for a list view.
public class ListViewDataSource {
    public typealias ItemType = Hashable & Identifiable

    init() {}

    /// Tells the data source to return the number of rows in list view.
    public func numberOfItems(in _: ListView) -> Int {
        fatalError()
    }

    public func item(at _: Int, in _: ListView) -> (any ItemType)? {
        fatalError()
    }

    func itemIndex(for _: any Hashable, in _: ListView) -> Int? {
        fatalError()
    }

    func itemIdentifier(at index: Int, in listView: ListView) -> (any Hashable)? {
        item(at: index, in: listView)?.id
    }
}

/// The object you use to manage data for a list view.
public class ListViewDiffableDataSource<Item>: ListViewDataSource
    where Item: Identifiable & Hashable
{
    public typealias Snapshot = ListViewDataSourceSnapshot<Item>

    private weak var listView: ListView?
    private var elements: OrderedDictionary<Item.ID, Item> = .init()

    public init(listView: ListView) {
        self.listView = listView
    }

    /// Returns a representation of the current state of the data in the list view.
    public func snapshot() -> Snapshot {
        .init(elements: elements)
    }

    /// Resets the UI to reflect the state of the data in the snapshot,
    /// optionally animating the UI changes.
    @inlinable
    public func applySnapshot(
        using reloadData: some Collection<Item>,
        animatingDifferences: Bool = false
    ) {
        var snapshot = snapshot()
        snapshot.replace(with: reloadData)
        applySnapshot(snapshot, animatingDifferences: animatingDifferences)
    }

    private func createAnimationForDisposeView(on view: UIView, listView: ListView) {
        view.layoutIfNeeded()
        let frameInListView = view.convert(view.bounds, to: listView)
        guard let snapshotView = view.snapshotView(afterScreenUpdates: false) else { return }
        snapshotView.frame = frameInListView
        listView.addSubview(snapshotView)
        withListAnimation {
            snapshotView.alpha = 0
        } completion: { _ in
            snapshotView.removeFromSuperview()
        }
    }

    /// Updates the UI to reflect the state of the data in the snapshot,
    /// optionally animating the UI changes.
    public func applySnapshot(
        _ snapshot: Snapshot,
        animatingDifferences: Bool = false
    ) {
        guard let listView else { return }

        let diffResult = difference(with: snapshot.elements)
        if diffResult.isEmpty { return }

        let removed = diffResult.removed
        for removedIndex in removed {
            let key = removedIndex.identifier
            guard let recycled = listView.recycleRow(with: key) else {
                continue
            }
            if animatingDifferences {
                createAnimationForDisposeView(on: recycled, listView: listView)
            }
            recycled.removeFromSuperview()
        }
        listView.layoutCache.requestInvalidateHeights(for: removed.map(\.identifier))

        let newElements = diffResult.elements
        elements = newElements

        let updated = diffResult.updated
        listView.layoutCache.requestInvalidateHeights(for: updated.map(\.identifier))
        for index in updated {
            let identifier = index.identifier
            if let newRowView = listView.updateRowKindIfNeeded(for: identifier) {
                _ = newRowView
            } else {
                listView.reconfigureRowView(for: identifier)
            }
        }
        listView.prepareVisibleRows()

        listView.layoutCache.finalizeInvalidationRequests()

        if animatingDifferences {
            withListAnimation {
                listView.updateVisibleItemsLayout()
            } completion: { _ in
                listView.setNeedsLayout()
                listView.layoutIfNeeded()
            }
        } else {
            listView.setNeedsLayout()
            listView.layoutIfNeeded()
        }
    }

    override public func numberOfItems(in _: ListView) -> Int {
        elements.count
    }

    override public func item(
        at index: Int,
        in _: ListView
    ) -> (any ItemType)? {
        guard index >= 0, index < elements.count else {
            return nil
        }
        return elements.elements[index].value
    }

    override func itemIndex(for identifier: any Hashable, in _: ListView) -> Int? {
        guard let key = identifier as? Item.ID else {
            return nil
        }
        return elements.index(forKey: key)
    }
}

extension ListViewDiffableDataSource {
    private struct SequenceDiffResult<T> where T: Hashable {
        struct Index {
            let index: Int
            let identifier: T
        }

        let removed: [Index]
        let added: [Index]
        let updated: [Index]

        let elements: OrderedDictionary<T, Item>

        var isEmpty: Bool {
            removed.isEmpty && added.isEmpty && updated.isEmpty
        }
    }

    private func difference(with other: [Item]) -> SequenceDiffResult<Item.ID> {
        let snapshot: OrderedDictionary<Item.ID, Item> = .init(uniqueKeysWithValues: other.map {
            ($0.id, $0)
        })
        assert(
            snapshot.count == other.count,
            "Duplicate identifiers found in the new collection."
        )
        let removed = elements.keys.subtracting(snapshot.keys).map { identifier in
            SequenceDiffResult<Item.ID>.Index(
                index: elements.index(forKey: identifier)!,
                identifier: identifier
            )
        }
        let added = snapshot.keys.subtracting(elements.keys).map { identifier in
            SequenceDiffResult<Item.ID>.Index(
                index: snapshot.index(forKey: identifier)!,
                identifier: identifier
            )
        }
        let updated = snapshot.keys.intersection(elements.keys).filter { identifier in
            snapshot[identifier] != elements[identifier]
        }.map { identifier in
            SequenceDiffResult<Item.ID>.Index(
                index: snapshot.index(forKey: identifier)!,
                identifier: identifier
            )
        }
        return .init(removed: removed, added: added, updated: updated, elements: snapshot)
    }
}

public struct ListViewDataSourceSnapshot<Item> where Item: Identifiable & Hashable {
    fileprivate var elements: [Item]

    /// The number of elements in the data source.
    public var count: Int { elements.count }

    /// A Boolean value indicating whether the data source is empty.
    public var isEmpty: Bool { elements.isEmpty }

    init(elements: OrderedDictionary<Item.ID, Item>) {
        self.elements = elements.values.elements
    }

    public func item(at index: Int) -> Item? {
        if index < 0 || index >= elements.count {
            return nil
        }
        return elements[index]
    }

    /// Inserts a new item at the specified position.
    public mutating func insert(_ item: Item, at index: Int) {
        if index < 0 || index > elements.count {
            return
        }

        elements.insert(item, at: index)
    }

    /// Adds a new element at the end of the data source.
    public mutating func append(_ item: Item) {
        elements.append(item)
    }

    /// Updates the item stored in the data source at the specified position.
    public mutating func updateItem(_ item: Item, at index: Int) {
        if index < 0 || index >= elements.count {
            return
        }
        elements[index] = item
    }

    /// Removes and returns the item at the specified position.
    @discardableResult
    public mutating func remove(at index: Int) -> Item? {
        if index < 0 || index >= elements.count {
            return nil
        }
        return elements.remove(at: index)
    }

    /// Replaces current elements with the elements in the specified collection.
    public mutating func replace(with sequence: some Sequence<Item>) {
        elements = sequence.map(\.self)
    }
}
