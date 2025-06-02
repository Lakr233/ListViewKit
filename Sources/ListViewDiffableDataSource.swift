//
//  ListViewDiffableDataSource.swift
//  ListViewKit
//
//  Created by 秋星桥 on 5/22/25.
//

import OrderedCollections
import UIKit

public class ListViewDiffableDataSource<Item>: ListViewDataSource
    where Item: Identifiable & Hashable
{
    public typealias Snapshot = ListViewDataSourceSnapshot<Item>

    weak var listView: ListView?
    var elements: OrderedDictionary<Item.ID, Item> = .init()

    public init(listView: ListView) {
        self.listView = listView
        super.init()
        listView.dataSource = self
    }

    public func snapshot() -> Snapshot {
        .init(elements: elements)
    }

    @inlinable
    public func applySnapshot(
        using reloadData: some Collection<Item>,
        animatingDifferences: Bool = false
    ) {
        var snapshot = snapshot()
        snapshot.replace(with: reloadData)
        applySnapshot(snapshot, animatingDifferences: animatingDifferences)
    }

    func createAnimationForDisposeView(on view: UIView, listView: ListView) {
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

    public func applySnapshot(
        _ snapshot: Snapshot,
        animatingDifferences: Bool = false
    ) {
        guard let listView else { return }

        let diffResult = difference(with: snapshot.elements)
        if diffResult.isEmpty { return }

        let addedItemIdentifiers = diffResult.added.map(\.identifier)

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

        let reordered = diffResult.reordered
        listView.layoutCache.requestInvalidateHeights(for: reordered.map(\.identifier))
        for reorderInfo in reordered {
            let identifier = reorderInfo.identifier
            // Force update/reconfigure for reordered items as requested
            if let newRowView = listView.updateRowKindIfNeeded(for: identifier) {
                _ = newRowView
            } else {
                listView.reconfigureRowView(for: identifier)
            }
        }

        listView.prepareVisibleRows()

        if animatingDifferences {
            for identifier in addedItemIdentifiers {
                guard let itemIndexInNewLayout = elements.index(forKey: identifier) else { continue }
                if let rowView = listView.rowView(at: itemIndexInNewLayout) {
                    rowView.alpha = 0
                }
            }
        }

        listView.layoutCache.finalizeInvalidationRequests()

        if animatingDifferences {
            listView.updateVisibleItemsLayout()
            listView.setNeedsLayout()
            listView.layoutIfNeeded()
            withListAnimation {
                for identifier in addedItemIdentifiers {
                    guard let itemIndexInNewLayout = self.elements.index(forKey: identifier) else { continue }
                    if let rowView = listView.rowView(at: itemIndexInNewLayout) {
                        rowView.alpha = 1
                    }
                }
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
