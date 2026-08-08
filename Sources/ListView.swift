//
//  Created by ktiays on 2025/1/14.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

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

    /// Held weakly, so a data source that has been released reads as `nil` and
    /// another one can take its place. Nothing the previous one described may
    /// survive that — neither measured heights nor the row views still keyed by
    /// its identifiers — because identifiers are only unique within one data
    /// source.
    public weak var dataSource: DataSource? {
        didSet {
            assert(oldValue == nil)
            reloadData()
        }
    }

    public weak var adapter: (any Adapter)?

    lazy var rowLayout: ListRowLayout = .init(self)
    lazy var visibleRows: [AnyHashable: ListRowView] = [:]
    lazy var reusableRows: [AnyHashable: [ListRowView]] = [:]
    var rowsPendingRemoval: [ListRowView] = []
    var isSliceDrainScheduled = false
    /// When the content width last turned measured heights back into
    /// estimates. The drain holds off while the width is still churning.
    var lastWidthChangeAt: CFTimeInterval = 0

    /// Height a row is assumed to have until it is measured.
    ///
    /// Rows are never measured before they are needed, so this is what holds
    /// the content height together while the list scrolls. A value close to
    /// the typical row keeps the scroller proportion steady as measurement
    /// catches up.
    public var estimatedRowHeight: CGFloat = 44 {
        didSet { invalidateLayout() }
    }

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
            height: rowLayout.contentHeight + topInset + bottomInset
        )
    }

    /// The visible rectangle in the space row frames are measured in, which
    /// sits `topInset` above the scroll coordinate space.
    var contentVisibleRect: CGRect {
        .init(
            origin: .init(x: contentOffset.x, y: contentOffset.y - topInset),
            size: bounds.size
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

    override func layoutContent() {
        rowLayout.prepareForLayout()
        // Measure exactly what the viewport needs and let the drain handle the
        // rest. Compensation has to precede the contentSize update so the
        // clamped offset lands inside the new bounds without turning into a
        // programmatic scroll.
        let visibleRect = contentVisibleRect
        compensateScrollOffset(
            by: rowLayout.measureRows(intersecting: visibleRect, anchorY: visibleRect.minY)
        )
        scheduleSliceDrain()
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
        rowLayout.prepareForLayout()
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

        // Reuse the most recently recycled row of this kind: it is the one
        // still warm in cache, and a pool has no ordering to preserve.
        let row = reusableRows[AnyHashable(kind)]?.popLast()
            ?? adapter.listViewMakeRow(for: kind)
        row.rowKind = kind
        configureRowView(row, for: item, at: index)
        visibleRows[key] = row
        if row.superview != self {
            addSubview(row)
        }
        row.frame = rectForRow(at: index)
        return row
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
        // In-place reconfiguration must keep the row's current content on
        // screen while the adapter applies the update. prepareForReuse is
        // reserved for rows coming back from the reuse pool: resetting here
        // renders the row empty for the frames between this call and any
        // asynchronous content the adapter installs (e.g. a throttled
        // streaming text update).
        adapter?.listView(self, configureRowView: view, for: item, at: index)
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
        rowView.rowKind = nil
        reusableRows[AnyHashable(rowKind), default: []].append(rowView)
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
