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

/// A diffable, reusing list of `Item`.
///
/// The list owns its content. Declare the row types once, then hand it
/// arrays:
///
/// ```swift
/// let list = ListView<Message>()
/// list.rows {
///     ListRow(TextRow.self)
///         .height { message, ctx in TextRow.height(for: message.text, width: ctx.width) }
///         .configure { row, message, _ in row.show(message.text) }
/// }
/// list.apply(messages, animated: true)
/// ```
///
/// Rows are measured only when they are needed. Everything else is corrected
/// in slices between frames, so opening a list and appending to it cost the
/// same whether it holds ten rows or a hundred thousand.
public final class ListView<Item: Identifiable & Hashable>: ListScrollView {
    private(set) var items: [Item] = []
    var indexByID: [Item.ID: Int] = [:]
    private var registrations: [ListRowRegistration<Item>] = []

    lazy var rowLayout: ListRowLayout<Item> = .init(self)
    /// Row views on screen, and the registration each was built from.
    var visibleRows: [Item.ID: (view: ListRowView, registration: Int)] = [:]
    /// Recycled rows, by registration index.
    private var reusePools: [[ListRowView]] = []
    /// Hidden rows kept for Auto Layout measurement, by registration index.
    /// The width constraint is what a self-sizing row solves against.
    struct Prototype {
        let view: ListRowView
        let width: NSLayoutConstraint
    }

    private var prototypes: [Int: Prototype] = [:]
    private var rowsPendingRemoval: [ListRowView] = []

    var isSliceDrainScheduled = false
    /// When the content width last turned measured heights back into
    /// estimates. The drain holds off while the width is still churning.
    var lastWidthChangeAt: CFTimeInterval = 0

    /// Height a row is assumed to have until it is measured, unless its
    /// registration overrides it with ``ListRow/estimatedHeight(_:)``.
    ///
    /// Rows are never measured before they are needed, so this is what holds
    /// the content height together while the list scrolls. A value close to
    /// the typical row keeps the scroller proportion steady as measurement
    /// catches up.
    public var estimatedRowHeight: CGFloat = 44 {
        didSet { invalidateLayout() }
    }

    public var topInset: CGFloat = 0 {
        didSet { requestLayout() }
    }

    public var bottomInset: CGFloat = 0 {
        didSet { requestLayout() }
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

    public convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError()
    }

    // MARK: - Rows

    /// Declares the row types this list can display. Replaces any previous
    /// declaration and discards every measurement, since heights belong to
    /// the registration that produced them.
    public func rows(@ListRowsBuilder<Item> _ build: () -> [ListRowRegistration<Item>]) {
        registrations = build()
        precondition(!registrations.isEmpty, "A list needs at least one row type.")
        reusePools = .init(repeating: [], count: registrations.count)
        for prototype in prototypes.values {
            prototype.view.removeFromSuperview()
        }
        prototypes.removeAll()
        reloadRowViews()
    }

    // MARK: - Content

    /// The items currently displayed.
    public var content: [Item] { items }

    /// Replaces the content, animating the difference if asked.
    ///
    /// Only what actually changed is touched: rows that kept their value keep
    /// their measured height, and appending to the end never revisits the rows
    /// already there.
    public func apply(_ newItems: [Item], animated: Bool = false) {
        let difference = ListDifference(from: items, to: newItems, indexByID: indexByID)
        guard !difference.isEmpty else { return }

        for identifier in difference.removed {
            guard let recycled = recycleRow(with: identifier) else { continue }
            if animated {
                animateDisposal(of: recycled)
            }
            recycled.removeFromSuperview()
        }

        let previousCount = items.count
        items = newItems
        indexByID = difference.indexByID

        if difference.isTailAppend(previousCount: previousCount) {
            rowLayout.appendRows(count: difference.added.count)
        } else {
            rowLayout.reload()
        }
        rowLayout.invalidateHeights(for: difference.removed + difference.remeasured)
        // Settle the viewport before anything animates: rows placed at their
        // estimate would animate to the wrong height and snap once the real
        // one arrives.
        measureViewport()

        for identifier in difference.remeasured {
            reconfigureRow(with: identifier)
        }
        prepareVisibleRows()

        guard animated else {
            requestLayout()
            layoutNow()
            return
        }
        for identifier in difference.added {
            setAlpha(0, onRowWith: identifier)
        }
        withListAnimation {
            self.updateVisibleRowFrames()
            for identifier in difference.added {
                self.setAlpha(1, onRowWith: identifier)
            }
        } completion: { _ in
            MainActor.assumeIsolated {
                // Only ask for a layout. Forcing one here would run inside a
                // later animation if applies overlap, moving its rows early.
                self.requestLayout()
            }
        }
    }

    /// Adds items to the end without diffing.
    ///
    /// ``apply(_:animated:)`` has to compare the whole array to find out what
    /// changed, which is O(n) per call however little moved. Appending is
    /// O(log n) per row and never touches the rows already there, so a chat
    /// client's send path does not grow with its history.
    public func append(contentsOf newItems: some Sequence<Item>) {
        let previousCount = items.count
        for item in newItems {
            precondition(indexByID[item.id] == nil, "duplicate identifier \(item.id) in the list.")
            indexByID[item.id] = items.count
            items.append(item)
        }
        guard items.count > previousCount else { return }
        rowLayout.appendRows(count: items.count - previousCount)
        prepareVisibleRows()
        requestLayout()
        layoutNow()
    }

    public func append(_ item: Item) {
        append(contentsOf: CollectionOfOne(item))
    }

    /// Updates one existing item without diffing the whole list.
    ///
    /// This is the path for high-frequency changes such as a streaming
    /// response. Returns `true` when the stored value actually changed.
    @discardableResult
    public func update(_ item: Item) -> Bool {
        guard let index = indexByID[item.id], items[index] != item else { return false }
        items[index] = item
        rowLayout.invalidateHeights(for: CollectionOfOne(item.id))
        reconfigureRow(with: item.id)
        requestLayout()
        layoutNow()
        return true
    }

    /// Rebuilds every row view and every measurement from scratch.
    public func reloadData() {
        reloadRowViews()
    }

    private func reloadRowViews() {
        for entry in visibleRows.values {
            entry.view.removeFromSuperview()
        }
        visibleRows.removeAll()
        rowsPendingRemoval.removeAll()
        for index in reusePools.indices {
            reusePools[index].removeAll()
        }
        invalidateLayout()
    }

    // MARK: - Layout

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

    override public var frame: CGRect {
        get { super.frame }
        set {
            // Assigning an unchanged frame cancels an in-flight scroll.
            guard super.frame != newValue else { return }
            super.frame = newValue
        }
    }

    override func layoutContent() {
        measureViewport()
        contentSize = supposedContentSize

        if contentOffset.y >= minimumContentOffset.y, contentOffset.y <= maximumContentOffset.y {
            recycleRowsOutsideViewport()
        }
        prepareVisibleRows()
        updateVisibleRowFrames()

        #if DEBUG
            var previousMaxY: CGFloat = 0
            for view in visibleRows.values.map(\.view).sorted(by: { $0.frame.minY < $1.frame.minY }) {
                assert(view.frame.minY >= previousMaxY)
                previousMaxY = view.frame.maxY
            }
        #endif

        removeUnusedRowsFromSuperview()
    }

    /// Measures whatever the viewport needs and leaves the rest to the drain.
    ///
    /// Compensation has to precede any contentSize update so the clamped
    /// offset lands inside the new bounds without turning into a programmatic
    /// scroll.
    private func measureViewport() {
        // The width has to be current first: adopting a new one turns every
        // measurement back into an estimate.
        rowLayout.prepareForLayout()
        let visibleRect = contentVisibleRect
        compensateScrollOffset(
            by: rowLayout.measureRows(intersecting: visibleRect, anchorY: visibleRect.minY)
        )
        scheduleSliceDrain()
    }

    func updateVisibleRowFrames() {
        rowLayout.prepareForLayout()
        contentSize = supposedContentSize
        for (identifier, entry) in visibleRows {
            guard let index = indexByID[identifier] else { continue }
            updateFrame(of: entry.view, to: rectForRow(at: index))
        }
        removeUnusedRowsFromSuperview()
    }

    private func updateFrame(of rowView: ListRowView, to targetFrame: CGRect) {
        guard rowView.frame != targetFrame else { return }
        let sizeChanged = rowView.frame.size != targetFrame.size
        rowView.frame = targetFrame
        guard sizeChanged else { return }
        rowView.requestLayout()
    }

    func requestLayout() {
        #if canImport(UIKit)
            setNeedsLayout()
        #elseif canImport(AppKit)
            needsLayout = true
        #endif
    }

    private func layoutNow() {
        #if canImport(UIKit)
            layoutIfNeeded()
        #elseif canImport(AppKit)
            layoutSubtreeIfNeeded()
        #endif
    }

    // MARK: - Row views

    /// Index of the registration that claims `item`, or nil when none does.
    func registrationIndex(for item: Item) -> Int? {
        registrations.firstIndex { $0.matches(item) }
    }

    func registration(_ index: Int) -> ListRowRegistration<Item> {
        registrations[index]
    }

    func context(at index: Int, purpose: ListRowPurpose) -> ListRowContext {
        .init(index: index, width: bounds.width, purpose: purpose)
    }

    /// A hidden row kept for measuring registrations that have no height
    /// closure. Parented to the list so it inherits appearance and traits,
    /// but pinned out of the way and never treated as content.
    func prototype(for registrationIndex: Int) -> Prototype {
        if let existing = prototypes[registrationIndex] { return existing }
        let view = registrations[registrationIndex].makeRow()
        view.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        let width = view.widthAnchor.constraint(equalToConstant: bounds.width)
        // Position is pinned only so Auto Layout has no ambiguity to warn
        // about; nothing ever reads this view's origin.
        NSLayoutConstraint.activate([
            width,
            view.topAnchor.constraint(equalTo: topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
        ])
        let prototype = Prototype(view: view, width: width)
        prototypes[registrationIndex] = prototype
        return prototype
    }

    func prepareVisibleRows() {
        for index in rowLayout.indices(intersecting: contentVisibleRect) {
            ensureRowView(at: index)
        }
    }

    private func ensureRowView(at index: Int) {
        guard index >= 0, index < items.count else { return }
        let item = items[index]
        if visibleRows[item.id] != nil { return }
        guard let registrationIndex = registrationIndex(for: item) else { return }

        // Reuse the most recently recycled row of this kind: it is the one
        // still warm in cache, and a pool has no ordering to preserve.
        let view = reusePools[registrationIndex].popLast()
            ?? registrations[registrationIndex].makeRow()
        view.prepareForReuse()
        registrations[registrationIndex].configure(
            view,
            item,
            context(at: index, purpose: .display)
        )
        visibleRows[item.id] = (view, registrationIndex)
        if view.superview !== self {
            addSubview(view)
        }
        view.frame = rectForRow(at: index)
    }

    /// Refills a row that is already on screen.
    ///
    /// Deliberately skips `prepareForReuse`, which is for rows coming back
    /// from the pool. Resetting here would blank the row for the frames
    /// between this call and whatever asynchronous content the configuration
    /// installs, such as a throttled streaming update.
    private func reconfigureRow(with identifier: Item.ID) {
        guard let entry = visibleRows[identifier],
              let index = indexByID[identifier]
        else { return }
        let item = items[index]

        // A changed item may now belong to a different row type.
        if registrationIndex(for: item) != entry.registration {
            recycleRow(with: identifier)
            ensureRowView(at: index)
            return
        }
        registrations[entry.registration].configure(
            entry.view,
            item,
            context(at: index, purpose: .display)
        )
        entry.view.requestLayout()
    }

    private func recycleRowsOutsideViewport() {
        let visibleRect = CGRect(origin: contentOffset, size: bounds.size)
        let stale = visibleRows.compactMap { identifier, _ -> Item.ID? in
            guard let index = indexByID[identifier] else { return identifier }
            return rectForRow(at: index).intersects(visibleRect) ? nil : identifier
        }
        for identifier in stale {
            recycleRow(with: identifier)
        }
    }

    @discardableResult
    func recycleRow(with identifier: Item.ID) -> ListRowView? {
        guard let entry = visibleRows.removeValue(forKey: identifier) else { return nil }
        reusePools[entry.registration].append(entry.view)
        rowsPendingRemoval.append(entry.view)
        return entry.view
    }

    private func removeUnusedRowsFromSuperview() {
        let pending = rowsPendingRemoval
        rowsPendingRemoval.removeAll(keepingCapacity: true)
        let reused = Set(visibleRows.values.map { ObjectIdentifier($0.view) })
        for view in pending where !reused.contains(ObjectIdentifier(view)) {
            view.removeFromSuperview()
        }
    }

    private func setAlpha(_ alpha: CGFloat, onRowWith identifier: Item.ID) {
        guard let view = visibleRows[identifier]?.view else { return }
        #if canImport(UIKit)
            view.alpha = alpha
        #elseif canImport(AppKit)
            view.alphaValue = alpha
        #endif
    }
}
