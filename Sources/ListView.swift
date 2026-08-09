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
public final class ListView<Item: Identifiable & Hashable & SendableMetatype>: ListScrollView {
    private(set) var items: [Item] = []
    var indexByID: [Item.ID: Int] = [:]
    private var registrations: [ListRowRegistration<Item>] = []

    /// Set in `init` rather than lazily: a lazy initializer is evaluated in a
    /// nonisolated context, which cannot name a main-actor-isolated generic
    /// type. Non-nil for the whole observable lifetime.
    private(set) var rowLayout: ListRowLayout<Item>!
    /// Row views on screen, and the registration each was built from.
    var visibleRows: [Item.ID: (view: ListRowView, registration: Int)] = [:]
    /// Recycled rows, by registration index.
    var reusePools: [[ListRowView]] = []
    /// Hidden rows kept for Auto Layout measurement, by registration index.
    /// The width constraint is what a self-sizing row solves against.
    struct Prototype {
        let view: ListRowView
        let width: NSLayoutConstraint
    }

    private var prototypes: [Int: Prototype] = [:]
    private var rowsPendingRemoval: [ListRowView] = []
    /// Rows placed this pass, still holding the previous item's arrangement.
    private var rowsPendingSettle: [ListRowView] = []

    /// Displaces rows on top of the layout while the list scrolls.
    ///
    /// ```swift
    /// list.rowAnimator = ListScrollSpring.messages
    /// ```
    ///
    /// Nil is the default and costs nothing: no display link, no per-row work,
    /// no overscan. Replacing or clearing one resets the previous animator and
    /// returns every row to where it was placed, so no displacement survives a
    /// change of mind.
    ///
    /// Ignored while the system asks for reduced motion.
    ///
    /// An existential on a per-frame path is a deliberate exception to what
    /// `DESIGN.md` says about `any`. That objection is about the per-row paths
    /// that run a hundred thousand times; this runs once per mounted row per
    /// frame, which is a couple of thousand calls a second at 120Hz.
    public var rowAnimator: (any ListRowAnimator)? {
        didSet {
            // The list mutates the animator in place every frame — `willUpdate`
            // and `rebase` are mutating requirements — and each of those is a
            // write to this property. Only a write from outside is a change of
            // animator.
            guard !isDrivingRowAnimator else { return }
            rowAnimatorDidChange(from: oldValue)
        }
    }

    /// Runs the animator a frame at a time while it says it has more to do.
    var rowAnimatorLink: RowAnimatorDisplayLink?

    /// Whether the list is currently inside the animator.
    ///
    /// This exists for `rowAnimator`'s observer, which cannot otherwise tell a
    /// caller installing a new animator from the list mutating the one it has.
    /// An earlier version also used it to defer a layout requested from inside
    /// `update`; that turned out to be defending against something both
    /// platforms already prevent, and it is gone.
    var isDrivingRowAnimator = false

    /// How far past the viewport rows are kept mounted.
    ///
    /// Cached rather than read where it is used. `maximumDisplacement` is a
    /// live getter on someone else's type, and mounting and recycling reading
    /// two different answers within one pass is exactly the disagreement that
    /// remounts a row every frame.
    var mountOverscan: CGFloat = 0
    /// How many frames the animator has been advanced for, so a test can show
    /// an idle list never ticks and a scrolling one ticks once per frame.
    var animatorTickCount: Int = 0

    /// Layout passes currently on the stack, and the deepest that has ever
    /// been.
    ///
    /// Nothing here enforces the depth; AppKit and UIKit both decline to run a
    /// layout inside a layout. It is measured so that the invariant an
    /// animator relies on — that the mounted set is not rearranged underneath
    /// `update` — is asserted rather than assumed to be inherited.
    private var layoutContentDepth = 0
    var deepestLayoutContentDepth = 0

    var isSliceDrainScheduled = false
    /// How many drain passes have started, so a test can show that one held
    /// off by a drag costs a handful of wake-ups rather than a spinning run
    /// loop.
    var sliceDrainPassCount: Int = 0
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
        rowLayout = ListRowLayout(self)

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
            setAlpha(0, onRowWith: identifier, animated: false)
        }
        // The rows are about to travel to their new frames. If the shorter
        // content pulls the offset off an edge, the viewport has to travel
        // with them instead of cutting to the destination.
        animatesContentSizeCorrection = true
        defer { animatesContentSizeCorrection = false }
        withListAnimation {
            self.updateVisibleRowFrames(animated: true)
            for identifier in difference.added {
                self.setAlpha(1, onRowWith: identifier, animated: true)
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
        rowsPendingSettle.removeAll()
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
    ///
    /// What the reader can actually see. Compensation is anchored here and
    /// ``indicesForVisibleRows`` reports it; neither means anything measured
    /// against a rectangle that was widened to hide the seams of an effect.
    var viewportRect: CGRect {
        .init(
            origin: .init(x: contentOffset.x, y: contentOffset.y - topInset),
            size: bounds.size
        )
    }

    /// The rectangle the rows occupy, in the same space as ``viewportRect``.
    ///
    /// Rows are laid out from zero, so this starts there whatever the insets
    /// are: an inset is space the list leaves around the content, not content.
    var contentRect: CGRect {
        .init(x: 0, y: 0, width: bounds.width, height: rowLayout.contentHeight)
    }

    /// The rectangle rows are kept mounted over.
    ///
    /// Wider than the viewport by whatever the animator may displace a row by,
    /// in both directions, so that a row displaced into view was mounted
    /// before it got there. Equal to ``viewportRect`` when no animator is
    /// installed, which is the default.
    ///
    /// Mounting, recycling, and measurement coverage all read this one. They
    /// have to read the same rectangle: a row mounted by one and recycled by
    /// the other is remounted on the very next pass, for as long as the
    /// disagreement lasts.
    var mountRect: CGRect {
        mountOverscan == 0 ? viewportRect : viewportRect.insetBy(dx: 0, dy: -mountOverscan)
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
        layoutContentDepth += 1
        deepestLayoutContentDepth = max(deepestLayoutContentDepth, layoutContentDepth)
        defer { layoutContentDepth -= 1 }
        refreshMountOverscan()
        measureViewport()
        contentSize = supposedContentSize

        if contentOffset.y >= minimumContentOffset.y, contentOffset.y <= maximumContentOffset.y {
            recycleRowsOutsideViewport()
        }
        prepareVisibleRows()
        updateVisibleRowFrames(animated: false)

        #if DEBUG
            // Asserted on the placements, so it keeps checking the layout even
            // while an animator displaces rows away from it. Whether a
            // displacement overlaps rows is the animator's business — some
            // effects overlap on purpose — and ``ListScrollSpring`` proves it
            // does not.
            var previousMaxY: CGFloat = 0
            for view in visibleRows.values.map(\.view)
                .sorted(by: { $0.placedFrame.minY < $1.placedFrame.minY })
            {
                assert(view.placedFrame.minY >= previousMaxY)
                previousMaxY = view.placedFrame.maxY
            }
        #endif

        removeUnusedRowsFromSuperview()
        settleNewlyPlacedRows()
        applyRowAnimator()
    }

    /// Lays out the rows placed during this pass, with animation suppressed.
    ///
    /// A row out of the pool still has its contents arranged for the item it
    /// used to show, so its first layout moves them the width of the row. That
    /// rearrangement has no history worth animating, and left to the framework
    /// it would run once this pass returns — inside whatever block the update
    /// was called from.
    ///
    /// The end of the pass is the one safe place to force it: the list has
    /// already cleared its own layout flag, so asking a row to lay out cannot
    /// climb back into `layoutContent`.
    private func settleNewlyPlacedRows() {
        guard !rowsPendingSettle.isEmpty else { return }
        let pending = rowsPendingSettle
        rowsPendingSettle.removeAll(keepingCapacity: true)
        withoutListAnimation {
            for view in pending where view.superview === self {
                view.layoutNow()
            }
        }
    }

    /// Measures whatever the viewport needs and leaves the rest to the drain.
    ///
    /// Compensation has to precede any contentSize update so the clamped
    /// offset lands inside the new bounds without turning into a programmatic
    /// scroll.
    /// Moves an animator's stored positions with the content space.
    ///
    /// Overridden rather than called alongside each compensation, because the
    /// two always go together and a compensation site added later would
    /// otherwise have to remember. Keeping compensation out of `scrollDelta`
    /// only says it was not scrolling; it does nothing for an animator holding
    /// a position from an earlier frame, since that position is stated in a
    /// coordinate space that has just moved underneath it.
    override func compensateScrollOffset(by dy: CGFloat) {
        super.compensateScrollOffset(by: dy)
        guard dy != 0, rowAnimator != nil else { return }
        isDrivingRowAnimator = true
        defer { isDrivingRowAnimator = false }
        rowAnimator?.rebase(byContentOffset: dy)
    }

    private func measureViewport() {
        // The width has to be current first: adopting a new one turns every
        // measurement back into an estimate.
        rowLayout.prepareForLayout()
        compensateScrollOffset(
            by: rowLayout.measureRows(intersecting: mountRect, anchoredAt: viewportRect)
        )
        scheduleSliceDrain()
    }

    /// Moves the visible rows onto their current frames.
    ///
    /// `animated` says whether the caller has the list's own animation open
    /// around this. A layout pass never does, however it was reached: it may
    /// well be running inside a caller's animation, but that animation is not
    /// the list's to join.
    func updateVisibleRowFrames(animated: Bool) {
        rowLayout.prepareForLayout()
        contentSize = supposedContentSize
        for (identifier, entry) in visibleRows {
            guard let index = indexByID[identifier] else { continue }
            updateFrame(of: entry.view, to: rectForRow(at: index), animated: animated)
        }
        removeUnusedRowsFromSuperview()
    }

    /// Compared against ``ListRowView/placedFrame`` rather than the view's own
    /// frame, which a row animator's displacement makes meaningless — on UIKit
    /// literally so, since displacement lands on the transform.
    private func updateFrame(of rowView: ListRowView, to targetFrame: CGRect, animated: Bool) {
        guard rowView.placedFrame != targetFrame else { return }
        let sizeChanged = rowView.placedFrame.size != targetFrame.size
        setRowFrame(targetFrame, on: rowView, animated: animated)
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
        // Never displayed, so never worth fading in — and a measurement can
        // happen inside a caller's animation.
        withoutListAnimation { view.isHidden = true }
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
        for index in rowLayout.indices(intersecting: mountRect) {
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
        let view: ListRowView
        if let recycled = reusePools[registrationIndex].popLast() {
            // Whatever motion is left on it was aimed at the item it used to
            // show. Cancelling here rather than at recycle time keeps a row
            // that is only passing through the pool within one pass — still on
            // screen, still sliding — from losing an animation the list owns.
            cancelRowAnimations(on: recycled)
            view = recycled
        } else {
            view = registrations[registrationIndex].makeRow()
        }
        // Placed before it is filled in or parented. A pooled row is still
        // sitting at someone else's frame, so configuring it there would lay
        // its contents out against a size about to change, and parenting it
        // there would show it in the wrong place for a frame.
        setRowFrame(rectForRow(at: index), on: view, animated: false)
        rowsPendingSettle.append(view)
        view.prepareForReuse()
        registrations[registrationIndex].configure(
            view,
            item,
            context(at: index, purpose: .display)
        )
        view.requestLayout()
        visibleRows[item.id] = (view, registrationIndex)
        if view.superview !== self {
            addSubview(view)
        }
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

    /// Recycles the rows the viewport has left behind.
    ///
    /// This reads the same rectangle mounting reads. It used to build its own
    /// in the scroll space instead, which picked the same rows only because
    /// `rectForRow(at:)` and the offset each carry `topInset` and the two
    /// cancelled. An agreement that holds by cancellation is one that breaks
    /// the first time either side is widened.
    private func recycleRowsOutsideViewport() {
        let visibleRect = mountRect
        let stale = visibleRows.compactMap { identifier, _ -> Item.ID? in
            guard let index = indexByID[identifier],
                  let frame = rowLayout.frame(for: index)
            else { return identifier }
            return frame.intersects(visibleRect) ? nil : identifier
        }
        for identifier in stale {
            recycleRow(with: identifier)
        }
    }

    @discardableResult
    func recycleRow(with identifier: Item.ID) -> ListRowView? {
        guard let entry = visibleRows.removeValue(forKey: identifier) else { return nil }
        // Whatever the animator was showing belonged to the item leaving, so
        // it does not travel to the next one on the same view. The scalar
        // model makes this free: there is no per-row state to tear down.
        clearRowDisplacement(on: entry.view)
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

    /// Sets a row's opacity. Hiding it to start the fade is setup rather than
    /// animation: left to an ambient context it would fade out over the
    /// caller's duration while the list fades it back in.
    private func setAlpha(_ alpha: CGFloat, onRowWith identifier: Item.ID, animated: Bool) {
        guard let view = visibleRows[identifier]?.view else { return }
        #if canImport(UIKit)
            let apply = { view.alpha = alpha }
        #elseif canImport(AppKit)
            let apply = { view.alphaValue = alpha }
        #endif
        guard animated else {
            withoutListAnimation(apply)
            return
        }
        apply()
    }
}
