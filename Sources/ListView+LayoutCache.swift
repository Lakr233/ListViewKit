//
//  Created by ktiays on 2025/1/15.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#else
    #error("ListViewKit requires UIKit or AppKit")
#endif

extension ListView {
    @MainActor final class LayoutCache {
        /// A row height together with the content width it was measured at.
        /// An entry whose width differs from the current content width is an
        /// estimate awaiting re-measurement.
        struct MeasuredHeight {
            var height: CGFloat
            var width: CGFloat
        }

        weak var listView: ListView?

        var heightCache: [AnyHashable: MeasuredHeight] = [:]
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
            guard let listView else { return 0 }
            return listView.dataSource?.numberOfItems(in: listView) ?? 0
        }

        func rebuild() {
            guard let listView else { return }
            guard let adapter = listView.adapter else { return }
            guard let dataSource = listView.dataSource else { return }

            let count = numberOfItems
            var validIdentifiers: Set<AnyHashable> = []
            for index in 0 ..< count {
                guard let key = identifier(for: index) else { continue }
                validIdentifiers.insert(key)
                guard heightCache[key] == nil else { continue }
                guard let item = dataSource.item(at: index, in: listView) else { continue }
                heightCache[key] = measuredHeight(
                    adapter: adapter,
                    item: item,
                    index: index,
                    listView: listView
                )
            }
            let staleIdentifiers = heightCache.keys.filter {
                !validIdentifiers.contains($0)
            }
            for key in staleIdentifiers {
                heightCache.removeValue(forKey: key)
            }

            contentHeightCache = rebuildFrame(listView: listView, count: count)
        }

        func rebuildFrame(
            listView: ListView,
            count: Int,
            startingAt requestedStartIndex: Int = 0
        ) -> CGFloat {
            let contentWidth = listView.bounds.width
            let startIndex = min(max(0, requestedStartIndex), count)
            let prefixHeight: CGFloat
            if startIndex == 0 {
                prefixHeight = 0
                frameCache.removeAll(keepingCapacity: true)
            } else if let precedingFrame = frameCache[startIndex - 1] {
                prefixHeight = precedingFrame.maxY
                for index in startIndex ..< count {
                    frameCache.removeValue(forKey: index)
                }
            } else {
                return rebuildFrame(listView: listView, count: count)
            }

            var usedHeight = prefixHeight
            for index in startIndex ..< count {
                guard let key = identifier(for: index) else { continue }
                let height = heightCache[key]?.height ?? 0
                let frame = CGRect(x: 0, y: usedHeight, width: contentWidth, height: height)
                frameCache[index] = frame
                usedHeight += height
            }
            return usedHeight
        }

        /// Re-measures known rows against an otherwise valid cache and rebuilds
        /// frames only from the earliest affected index. Returns `false` when
        /// structural changes require the normal reconciliation path.
        func invalidateHeights<S: Sequence>(for identifiers: S) -> Bool
            where S.Element: Hashable
        {
            guard let listView,
                  let adapter = listView.adapter,
                  let dataSource = listView.dataSource,
                  contentHeightCache != nil,
                  !isCacheInvalid
            else {
                return false
            }

            var affected: [(key: AnyHashable, index: Int, item: any Identifiable)] = []
            var seen: Set<AnyHashable> = []
            for identifier in identifiers {
                let key = AnyHashable(identifier)
                guard seen.insert(key).inserted else { continue }
                guard let index = dataSource.itemIndex(for: identifier, in: listView),
                      let item = dataSource.item(at: index, in: listView)
                else {
                    return false
                }
                affected.append((key, index, item))
            }
            guard let firstIndex = affected.map(\.index).min() else { return true }

            for entry in affected {
                heightCache[entry.key] = measuredHeight(
                    adapter: adapter,
                    item: entry.item,
                    index: entry.index,
                    listView: listView
                )
            }
            contentHeightCache = rebuildFrame(
                listView: listView,
                count: numberOfItems,
                startingAt: firstIndex
            )
            return true
        }

        private func measuredHeight(
            adapter: any ListViewAdapter,
            item: any Identifiable,
            index: Int,
            listView: ListView
        ) -> MeasuredHeight {
            let measuredHeight = adapter.listView(listView, heightFor: item, at: index)
            assert(
                measuredHeight.isFinite && measuredHeight >= 0,
                "Row heights must be finite and nonnegative."
            )
            return .init(
                height: measuredHeight.isFinite ? ceil(max(0, measuredHeight)) : 0,
                width: listView.bounds.width
            )
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
            return heightCache[key]?.height
        }

        func frame(for index: Int) -> CGRect? {
            if isCacheInvalid { rebuild() }
            return frameCache[index]
        }

        func indices(intersecting rect: CGRect) -> [Int] {
            if isCacheInvalid { rebuild() }
            let count = numberOfItems
            guard count > 0, !rect.isEmpty else { return [] }

            // A complete cache is ordered vertically by index, so locate the
            // first row whose lower edge extends into the visible rectangle.
            guard frameCache.count == count else {
                return frameCache
                    .filter { $0.key < count && $0.value.intersects(rect) }
                    .map(\.key)
                    .sorted()
            }

            var lowerBound = 0
            var upperBound = count
            while lowerBound < upperBound {
                let middle = lowerBound + (upperBound - lowerBound) / 2
                guard let frame = frameCache[middle] else { return [] }
                if frame.maxY <= rect.minY {
                    lowerBound = middle + 1
                } else {
                    upperBound = middle
                }
            }

            var result: [Int] = []
            var index = lowerBound
            while index < count, let frame = frameCache[index] {
                if frame.minY >= rect.maxY { break }
                if frame.intersects(rect) { result.append(index) }
                index += 1
            }
            return result
        }

        func requestInvalidateHeights<S: Sequence>(for identifiers: S) where S.Element: Hashable {
            var erasedIdentifiers: [AnyHashable] = []
            for identifier in identifiers {
                erasedIdentifiers.append(AnyHashable(identifier))
            }
            guard !erasedIdentifiers.isEmpty else { return }
            contentHeightCache = nil
            for identifier in erasedIdentifiers {
                heightCache.removeValue(forKey: identifier)
            }
            erasedIdentifiers
                .compactMap { index(for: $0) }
                .min()
                .flatMap { min in
                    for key in frameCache.keys where key >= min {
                        frameCache.removeValue(forKey: key)
                    }
                }
        }

        func finalizeInvalidationRequests() {
            if contentHeightCache == nil || isCacheInvalid {
                rebuild()
            }
        }

        func invalidateAll() {
            contentHeightCache = nil
            heightCache.removeAll()
            frameCache.removeAll()
        }
    }
}
