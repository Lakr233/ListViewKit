//
//  Created by ktiays on 2025/1/14.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import DequeModule
import UIKit

/// A view that presents data using rows in a single column.
open class ListView: ListScrollView {
    public typealias DataSource = ListViewDataSource
    public typealias Adapter = ListViewAdapter

    /// The object that acts as the data source of the list view.
    public weak var dataSource: DataSource?
    public weak var adapter: (any Adapter)?

    private var _delegate: (any UIScrollViewDelegate)?
    override open var delegate: (any UIScrollViewDelegate)? {
        set { _delegate = newValue }
        get { _delegate }
    }

    /// An array of indices, each identifying a visible row in the list view.
    public var indicesForVisibleRows: [Int] {
        let visibleRect = CGRect(origin: contentOffset, size: bounds.size)
        return layoutCache.allFrames()
            .filter { $0.value.intersects(visibleRect) }
            .map(\.key)
            .sorted()
    }

    /// The row views that are visible in the list view.
    public var visibleRowViews: [ListRowView] {
        visibleRows.values.map(\.self)
    }

    private(set) lazy var layoutCache: LayoutCache = .init(self)
    private(set) lazy var visibleRows: [AnyHashable: ListRowView] = [:]
    private lazy var reusableRows: [AnyHashable: Reference<Deque<ListRowView>>] = [:]
    /// A Boolean value that indicates whether the content size update was skipped.
    private var isContentSizeUpdateSkipped: Bool = false

    public var verticalExtendingSpacer: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }
    
    override public init(frame: CGRect) {
        super.init(frame: frame)

        alwaysBounceVertical = true
        clipsToBounds = true
        super.delegate = self
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError()
    }

    override open func layoutSubviews() {
        super.layoutSubviews()

        let bounds = bounds
        layoutCache.contentBounds = bounds

        if !isTracking {
            contentSize = .init(
                width: frame.width,
                height: layoutCache.contentHeight + verticalExtendingSpacer
            )
            isContentSizeUpdateSkipped = false
        } else {
            isContentSizeUpdateSkipped = true
        }

        let contentOffsetY = contentOffset.y
        let minimumContentOffsetY = minimumContentOffset.y
        let maximumContentOffsetY = maximumContentOffset.y
        if contentOffsetY >= minimumContentOffsetY, contentOffsetY <= maximumContentOffsetY {
            recycleAllVisibleRows()
        }

        prepareVisibleRows()
        for (id, rowView) in visibleRows {
            rowView.frame = rectForRow(with: id)
            rowView.setNeedsLayout()
        }

        #if DEBUG
            let sortedRows = visibleRows
                .map(\.value)
                .sorted {
                    $0.frame.minY < $1.frame.minY
                }
            var maxY: CGFloat = 0
            for row in sortedRows {
                assert(row.frame.minY >= maxY)
                maxY = row.frame.maxY
            }
        #endif
        removeUnusedRowsFromSuperview()
    }

    /// Crafted for animating contents already on screen
    func updateVisibleItemsLayout() {
        let bounds = bounds
        layoutCache.contentBounds = bounds
        contentSize = .init(
            width: ceil(frame.width),
            height: layoutCache.contentHeight + verticalExtendingSpacer
        )

        for (id, rowView) in visibleRows {
            rowView.frame = rectForRow(with: id)
            rowView.setNeedsLayout()
        }

        removeUnusedRowsFromSuperview()
    }

    public func invaliateLayout() {
        layoutCache.invalidateAll()
        setNeedsLayout()
    }

    /// Returns the row view at the index you specify.
    public func rowView(at index: Int) -> ListRowView? {
        guard let identifier = dataSource?.itemIdentifier(at: index, in: self) else {
            return nil
        }
        return visibleRows[AnyHashable(identifier)]
    }

    /// Returns the drawing area for a row that an index path identifies.
    public func rectForRow(at index: Int) -> CGRect {
        layoutCache.frame(for: index) ?? .zero
    }

    /// Returns the drawing area for a row that an identifier identifies.
    public func rectForRow(with identifier: some Hashable) -> CGRect {
        guard let index = dataSource?.itemIndex(for: identifier, in: self) else {
            return .zero
        }
        return rectForRow(at: index)
    }

    /// Reloads all rows of the list view.
    public func reloadData() {
        visibleRows.forEach { $0.value.removeFromSuperview() }
        visibleRows.removeAll()
        removeUnusedRowsFromSuperview()
        reusableRows.removeAll()
        invaliateLayout()
    }
}

public extension ListView {
    /// The position in the list view (top, middle, bottom) to scroll a specified row to.
    enum ScrollPosition {
        /// The list view scrolls the row of interest to be fully visible with a minimum of movement.
        case none
        /// The list view scrolls the row of interest to the top of the visible table view.
        case top
        /// The list view scrolls the row of interest to the middle of the visible table view.
        case middle
        /// The list view scrolls the row of interest to the bottom of the visible table view.
        case bottom
    }

    /// Scrolls through the list view until a row that an index path identifies is at a particular location on the screen.
    func scrollToRow(at index: Int, at scrollPosition: ScrollPosition, animated: Bool) {
        let targetRect = rectForRow(at: index)
        let targetContentOffsetY: CGFloat = {
            switch scrollPosition {
            case .none:
                let visibleRect = CGRect(origin: contentOffset, size: bounds.size)
                if targetRect.height > visibleRect.height {
                    return targetRect.minY
                }

                if visibleRect.contains(targetRect) {
                    // The `targetRect` is already visible.
                    return contentOffset.y
                }

                return if targetRect.minY < visibleRect.minY {
                    // The `targetRect` is above `visibleRect`
                    targetRect.minY
                } else {
                    // The `targetRect` is below `visibleRect`
                    targetRect.maxY - bounds.height
                }
            case .top:
                return targetRect.minY
            case .middle:
                return targetRect.midY - bounds.midY
            case .bottom:
                return targetRect.maxY - bounds.height
            }
        }()
        scroll(
            to: .init(
                x: 0,
                y: min(max(minimumContentOffset.y, targetContentOffsetY), maximumContentOffset.y)
            ),
            animated: animated
        )
    }
}

extension ListView {
    private func reusableDequeRef(for kind: AnyHashable) -> Reference<Deque<ListRowView>> {
        if let ref = reusableRows[kind] {
            return ref
        }
        @Reference var newRef: Deque<ListRowView> = .init()
        reusableRows[kind] = _newRef
        return _newRef
    }

    @discardableResult
    private func ensureRowView(for index: Int) -> ListRowView {
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
                    adapter.makeListRowView(for: kind)
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
    }

    func configureRowView(_ rowView: ListRowView, for _: any Identifiable, at index: Int) {
        guard let dataSource, let adapter else { return }
        guard let item = dataSource.item(at: index, in: self) else { return }
        rowView.prepareForReuse()
        adapter.listView(self, configureRowView: rowView, for: item, at: index)
        rowView._contextMenuInteractionCallback = { [unowned self] _, location in
            let converted = rowView.contentView.convert(location, to: self)
            adapter.listView(self, willDisplayContextMenuAt: converted, for: item, at: index, view: rowView)
        }
    }

    private func recycleAllVisibleRows() {
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
    }

    private func removeUnusedRowsFromSuperview() {
        for dequeRef in reusableRows.values {
            for item in dequeRef.wrappedValue {
                item.removeFromSuperview()
            }
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

// MARK: Delegate Forwarding

extension ListView: UIScrollViewDelegate {
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        _delegate?.scrollViewDidScroll?(scrollView)
    }

    public func scrollViewDidZoom(_ scrollView: UIScrollView) {
        _delegate?.scrollViewDidZoom?(scrollView)
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        _delegate?.scrollViewWillBeginDragging?(scrollView)
    }

    public func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        _delegate?.scrollViewWillEndDragging?(scrollView, withVelocity: velocity, targetContentOffset: targetContentOffset)
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        _delegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: decelerate)
        if isContentSizeUpdateSkipped {
            setNeedsLayout()
        }
    }

    public func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
        _delegate?.scrollViewWillBeginDecelerating?(scrollView)
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        _delegate?.scrollViewDidEndDecelerating?(scrollView)
    }

    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        _delegate?.scrollViewDidEndScrollingAnimation?(scrollView)
    }

    public func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        _delegate?.viewForZooming?(in: scrollView)
    }

    public func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        _delegate?.scrollViewWillBeginZooming?(scrollView, with: view)
    }

    public func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        _delegate?.scrollViewDidEndZooming?(scrollView, with: view, atScale: scale)
    }

    public func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        _delegate?.scrollViewShouldScrollToTop?(scrollView) ?? true
    }

    public func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        _delegate?.scrollViewDidScrollToTop?(scrollView)
    }

    public func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        _delegate?.scrollViewDidChangeAdjustedContentInset?(scrollView)
    }
}
