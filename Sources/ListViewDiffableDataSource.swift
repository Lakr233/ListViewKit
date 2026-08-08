//
//  ListViewDiffableDataSource.swift
//  ListViewKit
//
//  Created by 秋星桥 on 5/22/25.
//

import OrderedCollections

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#else
    #error("ListViewKit requires UIKit or AppKit")
#endif

public class ListViewDiffableDataSource<Item: Identifiable & Hashable>: ListViewDataSource {
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

    /// Updates one existing item without diffing a complete snapshot.
    ///
    /// This is the preferred path for high-frequency changes such as a
    /// streaming response. The item's identifier must already exist. Returns
    /// `true` when the stored value changed.
    @discardableResult
    public func updateItem(_ item: Item) -> Bool {
        guard let listView,
              let current = elements[item.id],
              current != item
        else {
            return false
        }

        elements[item.id] = item
        let identifier = AnyHashable(item.id)
        listView.rowLayout.invalidateHeights(for: CollectionOfOne(identifier))

        if let newRowView = listView.updateRowKindIfNeeded(for: identifier) {
            _ = newRowView
        } else {
            listView.reconfigureRowView(for: identifier)
        }

        #if canImport(UIKit)
            listView.setNeedsLayout()
            listView.layoutIfNeeded()
        #elseif canImport(AppKit)
            listView.needsLayout = true
            listView.layoutSubtreeIfNeeded()
        #endif
        return true
    }

    #if canImport(UIKit)
        func createAnimationForDisposeView(on view: UIView, listView: ListView) {
            view.layoutIfNeeded()
            let frameInListView = view.convert(view.bounds, to: listView)
            guard let snapshotView = view.snapshotView(afterScreenUpdates: false) else { return }
            snapshotView.frame = frameInListView
            listView.addSubview(snapshotView)
            withListAnimation {
                snapshotView.alpha = 0
            } completion: { _ in
                MainActor.assumeIsolated {
                    snapshotView.removeFromSuperview()
                }
            }
        }

    #elseif canImport(AppKit)
        func createAnimationForDisposeView(on view: NSView, listView: ListView) {
            view.display()
            let frameInListView = view.convert(view.bounds, to: listView)
            guard let bitmapRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmapRep)
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(bitmapRep)
            let snapshotView = NSImageView(image: image)
            snapshotView.frame = frameInListView
            snapshotView.wantsLayer = true
            listView.addSubview(snapshotView)
            withListAnimation {
                snapshotView.alphaValue = 0
            } completion: { _ in
                MainActor.assumeIsolated {
                    snapshotView.removeFromSuperview()
                }
            }
        }
    #endif

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

        let newElements = diffResult.elements
        let previousCount = elements.count
        elements = newElements

        // Bring the layout in line with the new order. Appending never
        // disturbs the rows already there, so it stays off the O(n) path.
        if diffResult.isTailAppend(previousCount: previousCount) {
            listView.rowLayout.appendRows(count: diffResult.added.count)
        } else {
            listView.rowLayout.reload()
        }

        let updated = diffResult.updated
        let reordered = diffResult.reordered
        // Removed rows only need their measurement forgotten; updated and
        // reordered rows need it taken again, since the adapter is handed both
        // the item and its index.
        listView.rowLayout.invalidateHeights(
            for: (removed + updated).map { AnyHashable($0.identifier) }
                + reordered.map { AnyHashable($0.identifier) }
        )

        for index in updated {
            let identifier = index.identifier
            if let newRowView = listView.updateRowKindIfNeeded(for: identifier) {
                _ = newRowView
            } else {
                listView.reconfigureRowView(for: identifier)
            }
        }

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
                    #if canImport(UIKit)
                        rowView.alpha = 0
                    #elseif canImport(AppKit)
                        rowView.alphaValue = 0
                    #endif
                }
            }
        }

        if animatingDifferences {
            withListAnimation {
                listView.updateVisibleItemsLayout()
                for identifier in addedItemIdentifiers {
                    guard let itemIndexInNewLayout = self.elements.index(forKey: identifier) else { continue }
                    if let rowView = listView.rowView(at: itemIndexInNewLayout) {
                        #if canImport(UIKit)
                            rowView.alpha = 1
                        #elseif canImport(AppKit)
                            rowView.alphaValue = 1
                        #endif
                    }
                }
            } completion: { _ in
                MainActor.assumeIsolated {
                    #if canImport(UIKit)
                        listView.setNeedsLayout()
                        listView.layoutIfNeeded()
                    #elseif canImport(AppKit)
                        listView.needsLayout = true
                        listView.layoutSubtreeIfNeeded()
                    #endif
                }
            }
        } else {
            #if canImport(UIKit)
                listView.setNeedsLayout()
                listView.layoutIfNeeded()
            #elseif canImport(AppKit)
                listView.needsLayout = true
                listView.layoutSubtreeIfNeeded()
            #endif
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
