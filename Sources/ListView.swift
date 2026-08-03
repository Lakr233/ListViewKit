//
//  Created by ktiays on 2025/1/14.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import DequeModule

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#else
    #error("ListViewKit requires UIKit or AppKit")
#endif

open class ListView: ListScrollView {
    public var id: UUID = .init()

    public typealias DataSource = ListViewDataSource
    public typealias Adapter = ListViewAdapter

    public weak var dataSource: DataSource? {
        didSet { assert(oldValue == nil) }
    }

    public weak var adapter: (any Adapter)?

    lazy var layoutCache: LayoutCache = .init(self)
    lazy var visibleRows: [AnyHashable: ListRowView] = [:]
    lazy var reusableRows: [AnyHashable: Reference<Deque<ListRowView>>] = [:]
    var rowsPendingRemoval: [ListRowView] = []
    var isDeferredMeasurementScheduled = false
    /// When the content width last turned measured heights into estimates.
    /// The deferred drain reads this to hold off while the width is still
    /// churning — see `drainDeferredMeasurementChunk`.
    var lastWidthReflowAt: CFTimeInterval = 0

    public var topInset: CGFloat = 0 {
        didSet {
            #if canImport(UIKit)
                setNeedsLayout()
            #elseif canImport(AppKit)
                needsLayout = true
            #endif
        }
    }

    public var bottomInset: CGFloat = 0 {
        didSet {
            #if canImport(UIKit)
                setNeedsLayout()
            #elseif canImport(AppKit)
                needsLayout = true
            #endif
        }
    }

    /// Keeps previously measured row heights as estimates when the content
    /// width changes, instead of discarding them all and re-measuring every
    /// row synchronously. Only the rows needed for the visible rect are
    /// measured during layout; the rest are corrected in small chunks on the
    /// main run loop while the scroll position is compensated to keep visible
    /// rows stationary. Estimated frames keep the list scrollable at
    /// approximately the right content height until every row is corrected.
    public var deferredSizeCalculation: Bool = false {
        didSet {
            guard oldValue, !deferredSizeCalculation else { return }
            // Turning the mode off with estimates outstanding falls back to
            // a full synchronous recompute on the next layout pass.
            layoutCache.invalidateAll()
            requestLayout()
        }
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)

        #if canImport(UIKit)
            alwaysBounceVertical = true
            clipsToBounds = true
        #elseif canImport(AppKit)
            layer?.masksToBounds = true
        #endif
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError()
    }

    var supposedContentSize: CGSize {
        .init(
            width: frame.width,
            height: layoutCache.contentHeight + topInset + bottomInset
        )
    }

    override open var frame: CGRect {
        get { super.frame }
        set {
            if super.frame != newValue {
                // prevent scroll animation being canceled
                super.frame = newValue
            }
        }
    }

    #if canImport(UIKit)
        override open func layoutSubviews() {
            super.layoutSubviews()
            performLayout()
        }

    #elseif canImport(AppKit)
        override open func layout() {
            super.layout()
            performLayout()
        }
    #endif

    private func performLayout() {
        let bounds = bounds
        layoutCache.contentBounds = bounds
        if deferredSizeCalculation, layoutCache.hasEstimatedHeights {
            // Correct only the rows the viewport needs, keep everything at
            // and below the top edge stationary, and let the run-loop drain
            // handle the rest. Compensation must precede the contentSize
            // update so the clamped offset lands inside the new bounds
            // without triggering a programmatic scroll.
            let visibleRect = CGRect(
                origin: .init(x: contentOffset.x, y: contentOffset.y - topInset),
                size: bounds.size
            )
            let visibleIndices = layoutCache.indices(intersecting: visibleRect)
            let offsetDelta = layoutCache.correctEstimatedHeights(
                at: visibleIndices,
                anchorY: visibleRect.minY
            )
            compensateScrollOffset(by: offsetDelta)
            scheduleDeferredMeasurement()
        }
        contentSize = supposedContentSize

        let contentOffsetY = contentOffset.y
        let minimumContentOffsetY = minimumContentOffset.y
        let maximumContentOffsetY = maximumContentOffset.y
        if contentOffsetY >= minimumContentOffsetY, contentOffsetY <= maximumContentOffsetY {
            recycleAllVisibleRows()
        }

        prepareVisibleRows()
        for (id, rowView) in visibleRows {
            updateFrame(of: rowView, to: rectForRow(with: id))
        }

        #if DEBUG
            let sortedRows = visibleRows
                .map(\.value)
                .sorted {
                    $0.frame.minY < $1.frame.minY
                }
            var maxY: CGFloat = 0
            for row in sortedRows {
                assert(row.frame.minY >= maxY) // float precision error
                maxY = row.frame.maxY
            }
        #endif

        removeUnusedRowsFromSuperview()
    }

    func updateVisibleItemsLayout() {
        let bounds = bounds
        layoutCache.contentBounds = bounds
        contentSize = supposedContentSize

        for (id, rowView) in visibleRows {
            updateFrame(of: rowView, to: rectForRow(with: id))
        }

        removeUnusedRowsFromSuperview()
    }

    private func updateFrame(of rowView: ListRowView, to targetFrame: CGRect) {
        guard rowView.frame != targetFrame else { return }
        let sizeChanged = rowView.frame.size != targetFrame.size
        rowView.frame = targetFrame
        guard sizeChanged else { return }
        #if canImport(UIKit)
            rowView.setNeedsLayout()
        #elseif canImport(AppKit)
            rowView.needsLayout = true
        #endif
    }
}

extension ListView: @MainActor Identifiable {}

/// internal api
extension ListView {
    func reusableDequeRef(for kind: AnyHashable) -> Reference<Deque<ListRowView>> {
        if let ref = reusableRows[kind] {
            return ref
        }
        @Reference var newRef: Deque<ListRowView> = .init()
        reusableRows[kind] = _newRef
        return _newRef
    }

    @discardableResult
    func ensureRowView(for index: Int) -> ListRowView {
        guard let identifier = dataSource?.itemIdentifier(at: index, in: self) else {
            assertionFailure()
            return .init()
        }
        let key = AnyHashable(identifier)
        if let view = visibleRows[key] {
            return view
        }

        guard let dataSource, let adapter else {
            assertionFailure()
            return .init()
        }

        guard let item = dataSource.item(at: index, in: self) else {
            assertionFailure()
            return .init()
        }
        let kind = adapter.listView(self, rowKindFor: item, at: index)

        return reusableDequeRef(for: .init(kind))
            .modifying { pool in
                let row: ListRowView = if let reusedRow = pool.popFirst() {
                    reusedRow
                } else {
                    adapter.listViewMakeRow(for: kind)
                }
                row.rowKind = kind
                configureRowView(row, for: item, at: index)
                visibleRows[key] = row
                if row.superview != self {
                    addSubview(row)
                }
                row.frame = rectForRow(at: index)
                return row
            }
    }

    func prepareVisibleRows() {
        for index in indicesForVisibleRows {
            _ = ensureRowView(for: index)
        }
    }

    func reconfigureRowView(for identifier: any Hashable) {
        guard let dataSource, let view = visibleRows[AnyHashable(identifier)] else {
            return
        }
        guard let index = dataSource.itemIndex(for: identifier, in: self) else {
            return
        }
        guard let item = dataSource.item(at: index, in: self) else {
            return
        }
        configureRowView(view, for: item, at: index)
        #if canImport(UIKit)
            view.setNeedsLayout()
            view.layoutIfNeeded()
        #elseif canImport(AppKit)
            view.needsLayout = true
            view.display()
        #endif
    }

    func configureRowView(_ rowView: ListRowView, for _: any Identifiable, at index: Int) {
        guard let dataSource, let adapter else { return }
        guard let item = dataSource.item(at: index, in: self) else { return }
        rowView.prepareForReuse()
        adapter.listView(self, configureRowView: rowView, for: item, at: index)
    }

    func recycleAllVisibleRows() {
        let visibleRect = CGRect(origin: contentOffset, size: bounds.size)
        var identifiersNeedsRecycled: Set<AnyHashable> = .init()
        for (id, _) in visibleRows {
            let targetFrame = rectForRow(with: id)
            if !targetFrame.intersects(visibleRect) {
                identifiersNeedsRecycled.insert(id)
            }
        }

        for id in identifiersNeedsRecycled {
            let recycled = recycleRow(with: id)
            assert(recycled != nil)
        }
    }

    @discardableResult
    func recycleRow(with identifier: AnyHashable) -> ListRowView? {
        guard let rowView = visibleRows.removeValue(forKey: identifier) else {
            return nil
        }
        recycleRowView(rowView)
        return rowView
    }

    func recycleRowView(_ rowView: ListRowView) {
        guard let rowKind = rowView.rowKind else {
            assertionFailure()
            return
        }
        let kind = AnyHashable(rowKind)
        rowView.rowKind = nil
        reusableDequeRef(for: kind)
            .modifying { $0.append(rowView) }
        rowsPendingRemoval.append(rowView)
    }

    func removeUnusedRowsFromSuperview() {
        let pendingRows = rowsPendingRemoval
        rowsPendingRemoval.removeAll(keepingCapacity: true)
        for rowView in pendingRows where rowView.rowKind == nil {
            rowView.removeFromSuperview()
        }
    }

    @discardableResult
    func updateRowKindIfNeeded(for identifier: AnyHashable) -> ListRowView? {
        guard let adapter, let dataSource else {
            return nil
        }
        guard let rowView = visibleRows[identifier] else {
            return nil
        }
        guard let currentKind = rowView.rowKind else {
            return nil
        }
        guard let index = dataSource.itemIndex(for: identifier, in: self) else {
            assertionFailure()
            return nil
        }
        guard let item = dataSource.item(at: index, in: self) else {
            assertionFailure()
            return nil
        }
        let newKind = adapter.listView(self, rowKindFor: item, at: index)
        if AnyHashable(currentKind) == AnyHashable(newKind) {
            return nil
        }

        // The kind of the row has changed.
        recycleRow(with: identifier)
        return ensureRowView(for: index)
    }
}
