//
//  Created by ktiays on 2025/1/15.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import UIKit

extension ListView {
    final class LayoutCache {
        weak var listView: ListView?

        var heightCache: [AnyHashable: CGFloat] = [:]
        var frameCache: [Int: CGRect] = [:]
        var contentHeightCache: CGFloat?
        var isCacheInvalid: Bool {
            numberOfItems != heightCache.count
        }

        var contentBounds: CGRect = .zero {
            didSet {
                let oldWidth = oldValue.width
                let width = contentBounds.width
                if oldWidth == width { return }
                invalidateAll()
            }
        }

        init(_ listView: ListView) {
            self.listView = listView
        }

        var contentHeight: CGFloat {
            if let cache = contentHeightCache {
                return cache
            }
            if isCacheInvalid {
                rebuild()
            }
            return contentHeightCache ?? 0
        }

        var numberOfItems: Int {
            listView?.dataSource?.numberOfItems(in: listView!) ?? 0
        }

        func rebuild() {
            guard let listView else { return }
            guard let adapter = listView.adapter else { return }
            guard let dataSource = listView.dataSource else { return }

            let count = numberOfItems
            for index in 0 ..< count {
                guard let key = identifier(for: index) else { continue }
                guard heightCache[key] == nil else { continue }
                guard let item = dataSource.item(at: index, in: listView) else { continue }
                heightCache[key] = adapter.listView(listView, heightFor: item, at: index)
            }
            heightCache.keys.filter {
                guard let index = index(for: $0) else { return false }
                return index >= count
            }
            .forEach { heightCache.removeValue(forKey: $0) }

            contentHeightCache = rebuildFrame(listView: listView, count: count)
        }

        func rebuildFrame(listView: ListView, count: Int) -> CGFloat {
            let contentWidth = listView.bounds.width
            var usedHeight: CGFloat = 0
            for index in 0 ..< count {
                guard let key = identifier(for: index) else { continue }
                let height = heightCache[key] ?? 0
                let frame = CGRect(x: 0, y: usedHeight, width: contentWidth, height: height)
                frameCache[index] = frame
                usedHeight += height
            }
            return usedHeight
        }

        func identifier(for index: Int) -> AnyHashable? {
            guard let listView else { return nil }
            let identifier = listView.dataSource?.itemIdentifier(at: index, in: listView)
            return identifier.flatMap { .init($0) }
        }

        func index(for identifier: AnyHashable) -> Int? {
            guard let listView else { return nil }
            return listView.dataSource?.itemIndex(for: identifier, in: listView)
        }

        func height(for index: Int) -> CGFloat? {
            if isCacheInvalid { rebuild() }
            guard let key = identifier(for: index) else { return nil }
            return heightCache[key]
        }

        func frame(for index: Int) -> CGRect? {
            if isCacheInvalid { rebuild() }
            return frameCache[index]
        }

        func allFrames() -> [Int: CGRect] {
            if isCacheInvalid { rebuild() }
            return frameCache
        }

        func requestInvalidateHeights<S>(for identifiers: S) where S: Sequence, S.Element: Hashable {
            for id in identifiers {
                heightCache.removeValue(forKey: id)
            }
            identifiers
                .compactMap { index(for: .init($0)) }
                .min()
                .flatMap { min in
                    for key in frameCache.keys where key >= min {
                        frameCache.removeValue(forKey: key)
                    }
                }
        }

        func finalizeInvalidationRequests() {
            rebuild()
        }

        func invalidateAll() {
            contentHeightCache = nil
            heightCache.removeAll()
            frameCache.removeAll()
        }
    }
}
