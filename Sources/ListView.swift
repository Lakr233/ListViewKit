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
///
/// ## Subclassing
///
/// The class is open, and so is the row lifecycle: ``rows(_:)``, the content
/// calls, ``layoutContent()``, ``mountRowView(at:)``,
/// ``reconfigureRow(with:)``, ``recycleRow(with:)`` and the hooks they reach
/// the reuse pool and the registrations through. Every override must call
/// `super` unless its documentation says otherwise. What stays closed is
/// either storage the list keeps consistent across those calls, or work done
/// on every layout pass or for every row, where an overridable member would
/// cost dynamic dispatch on the hottest path.
open class ListView<Item: Identifiable & Hashable & SendableMetatype>: ListScrollView {
    // Every member that is not open is marked `final`, here and in
    // `ListScrollView`. The class used to be final as a whole, which let the
    // optimizer call and inline its own members and its superclass's
    // directly; opened, it stopped doing so, and a streaming `update`
    // measured about four percent slower until each was finalized by hand.

    private(set) final var items: [Item] = []
    final var indexByID: [Item.ID: Int] = [:]
    private final var registrations: [ListRowRegistration<Item>] = []

    /// Set in `init` rather than lazily: a lazy initializer is evaluated in a
    /// nonisolated context, which cannot name a main-actor-isolated generic
    /// type. Non-nil for the whole observable lifetime.
    private(set) final var rowLayout: ListRowLayout<Item>!
    /// Row views on screen, and the registration each was built from.
    final var visibleRows: [Item.ID: (view: ListRowView, registration: Int)] = [:]
    /// Recycled rows, by registration index.
    final var reusePools: [[ListRowView]] = []
    /// Hidden rows kept for Auto Layout measurement, by registration index.
    /// The width constraint is what a self-sizing row solves against.
    struct Prototype {
        let view: ListRowView
        let width: NSLayoutConstraint
    }

    private final var prototypes: [Int: Prototype] = [:]
    private final var rowsPendingRemoval: [ListRowView] = []
    /// Rows placed this pass, still holding the previous item's arrangement.
    private final var rowsPendingSettle: [ListRowView] = []
    /// Rows kept mounted while an animation may still be showing them, with
    /// the time it ends.
    ///
    /// Recycling reads where the layout says a row is, but while something
    /// animates the reader sees where it is on the way there: a row sliding
    /// off after an apply, or one the keyboard's resize is still uncovering.
    /// Recycling such a row blanks part of the screen, and the pool can hand
    /// the very view straight to another item while it is still on display.
    /// Only rows already on screen are held. The pool keeps working, since
    /// what is in it is off screen already.
    final var heldRows: [Item.ID: CFTimeInterval] = [:]
    /// Releases the held rows once their animations have ended.
    private final var heldRowRelease: Timer?

    /// Displaces rows on top of the layout while the list scrolls.
    ///
    /// ```swift
    /// list.rowAnimator = ListBouncyAnimator()
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
    public final var rowAnimator: (any ListRowAnimator)? {
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
    final var rowAnimatorLink: RowAnimatorDisplayLink?

    /// Whether the list is currently inside the animator.
    ///
    /// This exists for `rowAnimator`'s observer, which cannot otherwise tell a
    /// caller installing a new animator from the list mutating the one it has.
    /// An earlier version also used it to defer a layout requested from inside
    /// `update`; that turned out to be defending against something both
    /// platforms already prevent, and it is gone.
    final var isDrivingRowAnimator = false

    /// How far past the viewport rows are kept mounted.
    ///
    /// Cached rather than read where it is used. `maximumDisplacement` is a
    /// live getter on someone else's type, and mounting and recycling reading
    /// two different answers within one pass is exactly the disagreement that
    /// remounts a row every frame.
    final var mountOverscan: CGFloat = 0
    /// How many frames the animator has been advanced for, so a test can show
    /// an idle list never ticks and a scrolling one ticks once per frame.
    final var animatorTickCount: Int = 0
    /// Stands in for the system's reduce-motion setting when set, so a test
    /// can switch it mid-animation.
    final var reducedMotionOverride: Bool?
    /// Where the reader last held the content, measured from the viewport's
    /// top edge, or `nil` before any interaction has been seen.
    ///
    /// Remembered across gestures: momentum keeps scrolling after the finger
    /// lifts, and the anchor the lag is graded from has to stay where the
    /// finger was, not jump to a default mid-flight.
    final var rowAnimatorGripViewportY: CGFloat?

    /// Layout passes currently on the stack, and the deepest that has ever
    /// been.
    ///
    /// Nothing here enforces the depth; AppKit and UIKit both decline to run a
    /// layout inside a layout. It is measured so that the invariant an
    /// animator relies on — that the mounted set is not rearranged underneath
    /// `update` — is asserted rather than assumed to be inherited.
    private final var layoutContentDepth = 0
    final var deepestLayoutContentDepth = 0

    /// Where the animated scroll in flight was asked to go, if it was asked
    /// for a row or the end rather than an offset.
    final var scrollDestination: ListScrollDestination<Item.ID>?

    final var isSliceDrainScheduled = false
    /// How many drain passes have started, so a test can show that one held
    /// off by a drag costs a handful of wake-ups rather than a spinning run
    /// loop.
    final var sliceDrainPassCount: Int = 0
    /// When the content width last turned measured heights back into
    /// estimates. The drain holds off while the width is still churning.
    final var lastWidthChangeAt: CFTimeInterval = 0

    /// Height a row is assumed to have until it is measured, unless its
    /// registration overrides it with ``ListRow/estimatedHeight(_:)``.
    ///
    /// Rows are never measured before they are needed, so this is what holds
    /// the content height together while the list scrolls. A value close to
    /// the typical row keeps the scroller proportion steady as measurement
    /// catches up.
    ///
    /// Set it before applying content. A row takes its estimate when the
    /// layout picks it up and keeps it until measured, so changing this later
    /// reaches rows added afterwards and, on any apply that is not a plain
    /// append, every row still unmeasured. It never discards a measurement:
    /// an estimate cannot make a measured height wrong.
    public final var estimatedRowHeight: CGFloat = 44

    public final var topInset: CGFloat = 0 {
        didSet { requestLayout() }
    }

    public final var bottomInset: CGFloat = 0 {
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
    ///
    /// An override must call `super`.
    open func rows(@ListRowsBuilder<Item> _ build: () -> [ListRowRegistration<Item>]) {
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
    public final var content: [Item] { items }

    /// Replaces the content, animating the difference if asked.
    ///
    /// Only what actually changed is touched: rows that kept their value keep
    /// their measured height, wherever they moved to, and appending to the end
    /// never revisits the rows already there. A registration whose height
    /// reads the index says so with ``ListRow/heightDependsOnIndex()``, and its
    /// rows are measured again whenever they move.
    ///
    /// An override must call `super`.
    open func apply(_ newItems: [Item], animated: Bool = false) {
        let difference = ListDifference(from: items, to: newItems, indexByID: indexByID)
        guard !difference.isEmpty else { return }

        // Every snapshot is taken before any row is recycled. On AppKit taking
        // one draws the row, and drawing runs whatever layout the window owes —
        // this list's included. That pass has to find the list as it was: once
        // a removed row is recycled but the old items are still in place, the
        // pass mounts the item again on the very view just pooled, the loop
        // below takes that view out of the hierarchy, and the list keeps a
        // detached row parked in the slot for good.
        if animated {
            for identifier in difference.removed {
                guard let view = visibleRows[identifier]?.view else { continue }
                animateDisposal(of: view)
            }
        }
        for identifier in difference.removed {
            recycleRow(with: identifier)?.removeFromSuperview()
        }

        // Where everything was, for rows that only come on screen because of
        // this change: they travel in from there instead of appearing.
        let previousGeometry = animated ? rowLayout.geometry : nil
        let previousIndexByID = indexByID
        let previousItems = items
        let previouslyMounted = Set(visibleRows.keys)

        let previousCount = items.count
        items = newItems
        indexByID = difference.indexByID

        // A tail append has nothing removed, changed or moved to invalidate.
        if difference.isTailAppend(previousCount: previousCount) {
            rowLayout.appendRows(count: difference.added.count)
        } else {
            rowLayout.reload(
                invalidating: difference.removed,
                difference.changed,
                movedRowsMeasuredByIndex(difference.moved)
            )
        }
        // Settle the viewport before anything animates: rows placed at their
        // estimate would animate to the wrong height and snap once the real
        // one arrives.
        measureViewport()

        for identifier in difference.changed {
            reconfigureRow(with: identifier)
        }
        // A row that only moved was configured with the index it had before.
        // Only the mounted ones show that index, so only they are filled in
        // again; the rest pick up the new one when they are next mounted.
        for identifier in Array(visibleRows.keys) {
            guard let previousIndex = previousIndexByID[identifier],
                  let index = indexByID[identifier],
                  previousIndex != index,
                  previousItems[previousIndex] == items[index]
            else { continue }
            reconfigureRow(with: identifier)
        }
        prepareVisibleRows()

        guard animated, let previousGeometry else {
            requestLayout()
            layoutNow()
            return
        }
        for identifier in difference.added {
            setAlpha(0, onRowWith: identifier, animated: false)
        }
        for (identifier, entry) in visibleRows where !previouslyMounted.contains(identifier) {
            guard let previousIndex = previousIndexByID[identifier],
                  let previousFrame = previousGeometry.frame(for: previousIndex)
            else { continue }
            setRowFrame(entryFrame(from: previousFrame, of: entry.view), on: entry.view, animated: false)
        }
        holdMountedRows(for: listRowSlideDuration)
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

    /// The moved items whose registration measures them by their index, and
    /// so whose height went stale with the move.
    ///
    /// Matching an item to its registration runs the caller's predicates, so
    /// a list where no registration asked for this skips the walk entirely:
    /// a moved row there keeps its height whatever it is.
    private final func movedRowsMeasuredByIndex(_ moved: [Item.ID]) -> [Item.ID] {
        guard registrations.contains(where: \.heightDependsOnIndex) else { return [] }
        return moved.filter { identifier in
            guard let index = indexByID[identifier],
                  let registrationIndex = registrationIndex(for: items[index])
            else { return false }
            return registrations[registrationIndex].heightDependsOnIndex
        }
    }

    /// Where a row that only came on screen because of an apply starts its
    /// slide: where it was before, but no further out than just past the edge
    /// of the mounted area.
    ///
    /// Its old position can be thousands of points away, and a row covering
    /// that in one slide crosses the screen too fast to follow. Starting it at
    /// the edge it was beyond keeps the direction of the move and the pace of
    /// its neighbours. It keeps its new size, so only its position moves.
    private final func entryFrame(from previousFrame: CGRect, of view: ListRowView) -> CGRect {
        let target = view.placedFrame
        let edge = mountRect
        let y = if previousFrame.maxY <= edge.minY {
            max(previousFrame.minY, edge.minY - target.height)
        } else if previousFrame.minY >= edge.maxY {
            min(previousFrame.minY, edge.maxY)
        } else {
            previousFrame.minY
        }
        return CGRect(x: target.minX, y: y, width: target.width, height: target.height)
    }

    /// Adds items to the end without diffing.
    ///
    /// ``apply(_:animated:)`` has to compare the whole array to find out what
    /// changed, which is O(n) per call however little moved. Appending is
    /// O(log n) per row and never touches the rows already there, so a chat
    /// client's send path does not grow with its history.
    ///
    /// An override must call `super`. ``append(_:)`` does not come through
    /// here, so a subclass that watches appends overrides both.
    open func append(contentsOf newItems: some Sequence<Item>) {
        appendItems(newItems)
    }

    /// Adds one item to the end. See ``append(contentsOf:)``.
    ///
    /// An override must call `super`.
    open func append(_ item: Item) {
        // Not through the open generic `append(contentsOf:)`: a call there
        // cannot be specialized for `CollectionOfOne`, and a chat client's
        // send path would iterate it through witness tables.
        appendItems(CollectionOfOne(item))
    }

    private final func appendItems(_ newItems: some Sequence<Item>) {
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

    /// Updates one existing item without diffing the whole list.
    ///
    /// This is the path for high-frequency changes such as a streaming
    /// response. Returns `true` when the stored value actually changed.
    ///
    /// An override must call `super`, and runs once per update: keep it
    /// cheap on a list that streams.
    @discardableResult
    open func update(_ item: Item) -> Bool {
        guard let index = indexByID[item.id], items[index] != item else { return false }
        items[index] = item
        rowLayout.invalidateHeights(for: CollectionOfOne(item.id))
        reconfigureRow(with: item.id)
        requestLayout()
        layoutNow()
        return true
    }

    /// Rebuilds every row view and every measurement from scratch.
    ///
    /// An override must call `super`.
    open func reloadData() {
        reloadRowViews()
    }

    private final func reloadRowViews() {
        for entry in visibleRows.values {
            forgetRowAnimation(of: entry.view)
            entry.view.removeFromSuperview()
        }
        visibleRows.removeAll()
        heldRows.removeAll()
        rowsPendingRemoval.removeAll()
        rowsPendingSettle.removeAll()
        for index in reusePools.indices {
            reusePools[index].removeAll()
        }
        invalidateLayout()
    }

    /// Invalidates every row height.
    ///
    /// Prefer ``invalidateLayout(forRowWith:)`` when one self-sizing row
    /// changes: keeping the other measurements is substantially cheaper for
    /// streaming or expandable content. An override must call `super`.
    open func invalidateLayout() {
        rowLayout.invalidateAll()
        requestLayout()
    }

    /// Invalidates the measured height of one row.
    ///
    /// Use this when hosted or expandable content changes size without the
    /// item itself changing. The row keeps its current height as an estimate
    /// until it is measured again. An override must call `super`.
    open func invalidateLayout(forRowWith identifier: Item.ID) {
        rowLayout.invalidateHeights(for: CollectionOfOne(identifier))
        requestLayout()
    }

    // MARK: - Scrolling

    /// Scrolls until the row at `index` sits at `position`.
    ///
    /// Animated, the scroll keeps heading for the row as rows on the way are
    /// measured, so it lands on the row rather than on where the estimates
    /// placed it.
    ///
    /// ``scrollToRow(with:at:animated:)`` funnels through here. An override
    /// must call `super`.
    open func scrollToRow(at index: Int, at position: ListRowPosition, animated: Bool = true) {
        guard index >= 0, index < content.count else { return }

        let placement = resolvedPlacement(ofRowAt: index, at: position)
        let targetOffset = placement.map { offset(showingRowAt: index, at: $0) } ?? contentOffset
        guard animated else {
            setContentOffset(targetOffset, animated: false)
            return
        }
        scroll(to: targetOffset)
        if let placement {
            scrollDestination = .init(place: .row(content[index].id, placement), serial: scrollingSerial)
        }
    }

    /// Scrolls until the row for `identifier` sits at `position`.
    open func scrollToRow(with identifier: Item.ID, at position: ListRowPosition, animated: Bool = true) {
        guard let index = index(of: identifier) else { return }
        scrollToRow(at: index, at: position, animated: animated)
    }

    /// Scrolls to the end of the content.
    ///
    /// Animated, the scroll follows the end as rows on the way are measured.
    /// An override must call `super`.
    open func scrollToBottom(animated: Bool = true) {
        guard animated else {
            setContentOffset(maximumContentOffset, animated: false)
            return
        }
        scroll(to: maximumContentOffset)
        scrollDestination = .init(place: .bottom, serial: scrollingSerial)
    }

    // MARK: - Layout

    final var supposedContentSize: CGSize {
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
    final var viewportRect: CGRect {
        .init(
            origin: .init(x: contentOffset.x, y: contentOffset.y - topInset),
            size: bounds.size
        )
    }

    /// The rectangle the rows occupy, in the same space as ``viewportRect``.
    ///
    /// Rows are laid out from zero, so this starts there whatever the insets
    /// are: an inset is space the list leaves around the content, not content.
    final var contentRect: CGRect {
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
    final var mountRect: CGRect {
        mountOverscan == 0 ? viewportRect : viewportRect.insetBy(dx: 0, dy: -mountOverscan)
    }

    /// Final, and only forwards: the list reads its own offset and size
    /// several times per pass, and a subclass able to override them would
    /// make every one of those reads dynamic. Behaviour belongs to
    /// ``ListScrollView``.
    override public final var contentOffset: CGPoint {
        get { super.contentOffset }
        set { super.contentOffset = newValue }
    }

    override public final var contentSize: CGSize {
        get { super.contentSize }
        set { super.contentSize = newValue }
    }

    override open var frame: CGRect {
        get { super.frame }
        set {
            // Assigning an unchanged frame cancels an in-flight scroll.
            guard super.frame != newValue else { return }
            super.frame = newValue
        }
    }

    /// Measures the viewport, then mounts, places and recycles rows. Runs
    /// once per layout pass; an override must call `super`.
    override open func layoutContent() {
        layoutContentDepth += 1
        deepestLayoutContentDepth = max(deepestLayoutContentDepth, layoutContentDepth)
        defer { layoutContentDepth -= 1 }
        refreshMountOverscan()
        measureViewport()
        contentSize = supposedContentSize
        // Content that shrank pulls the offset back onto its new end, which
        // brings rows into view the measurement above never saw. Each round
        // measures every one of them, so this ends.
        while rowLayout.hasPendingRows(intersecting: mountRect) {
            measureViewport()
            contentSize = supposedContentSize
        }
        // Every measurement this pass makes, and any the drain made since the
        // last one, is in by now.
        retargetScrollDestination()

        // A pass inside a host's animation — the keyboard resizing the list,
        // say — moves the viewport on screen over the length of that
        // animation, while this pass only sees where it ends up.
        holdMountedRows(for: ambientAnimationDuration)
        if contentOffset.y >= minimumContentOffset.y, contentOffset.y <= maximumContentOffset.y {
            recycleRowsOutsideViewport()
        }
        prepareVisibleRows()
        updateVisibleRowFrames(animated: false)

        #if DEBUG
            // Asserted on the placements, so it keeps checking the layout even
            // while an animator displaces rows away from it. Whether a
            // displacement overlaps rows is the animator's business — some
            // effects, ``ListBouncyAnimator`` among them, overlap on purpose.
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

    /// Returns the rows to rest whenever the list changes windows.
    ///
    /// The animator's link ticks only while the list is in a window. Leaving
    /// one mid-spring would hold the rows displaced, with a link waiting for
    /// a frame that will not come. Entering one is no better: a layout pass
    /// outside a window can still displace rows, and the link it would need
    /// to settle them is never started there. Nobody saw either motion, so
    /// neither is worth finishing.
    override open func windowDidChange() {
        super.windowDidChange()
        guard rowAnimator != nil else { return }
        resetRowAnimator()
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
    private final func settleNewlyPlacedRows() {
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
    override open func compensateScrollOffset(by dy: CGFloat) {
        super.compensateScrollOffset(by: dy)
        guard dy != 0, rowAnimator != nil else { return }
        // Saved and restored rather than cleared. Compensation can be reached
        // from inside the animator — measurement runs during a layout an
        // implementation asked for — and clearing the flag on the way out of
        // the inner call would let the outer one's writeback be mistaken for a
        // caller installing a new animator, which resets the whole thing.
        let wasRunning = isDrivingRowAnimator
        isDrivingRowAnimator = true
        defer { isDrivingRowAnimator = wasRunning }
        rowAnimator?.rebase(byContentOffset: dy)
    }

    private final func measureViewport() {
        // The width has to be current first: adopting a new one turns every
        // measurement back into an estimate.
        rowLayout.prepareForLayout()
        let dy = rowLayout.measureRows(intersecting: mountRect, anchoredAt: viewportRect)
        // Checked here as well as inside: on most passes nothing above the
        // viewport changed, and the overridable call is not worth making.
        if dy != 0 {
            compensateScrollOffset(by: dy)
        }
        scheduleSliceDrain()
    }

    /// Moves the visible rows onto their current frames.
    ///
    /// `animated` says whether the caller has the list's own animation open
    /// around this. A layout pass never does, however it was reached: it may
    /// well be running inside a caller's animation, but that animation is not
    /// the list's to join.
    final func updateVisibleRowFrames(animated: Bool) {
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
    private final func updateFrame(of rowView: ListRowView, to targetFrame: CGRect, animated: Bool) {
        guard rowView.placedFrame != targetFrame else { return }
        let sizeChanged = rowView.placedFrame.size != targetFrame.size
        setRowFrame(targetFrame, on: rowView, animated: animated)
        guard sizeChanged else { return }
        rowView.requestLayout()
        // The frame was set without animating, so the contents follow it the
        // same way. Left to the framework, the row lays out as the pass
        // descends into it — inside whatever animation the host has open —
        // and its contents would slide to a size the row already snapped to.
        if !animated {
            rowsPendingSettle.append(rowView)
        }
    }

    final func requestLayout() {
        #if canImport(UIKit)
            setNeedsLayout()
        #elseif canImport(AppKit)
            needsLayout = true
        #endif
    }

    private final func layoutNow() {
        #if canImport(UIKit)
            layoutIfNeeded()
        #elseif canImport(AppKit)
            layoutSubtreeIfNeeded()
        #endif
    }

    // MARK: - Row views

    /// Index of the registration that claims `item`, or nil when none does.
    ///
    /// Runs for every row measured, and for every row an apply estimates when
    /// the rows have conditions, so it reads only the condition out of each
    /// registration instead of copying the whole thing.
    ///
    /// The index is the registration's position in the ``rows(_:)``
    /// declaration. Not overridable: measurement calls it for every row.
    public final func registrationIndex(for item: Item) -> Int? {
        for index in registrations.indices {
            guard let matches = registrations[index].matches else { return index }
            if matches(item) { return index }
        }
        return nil
    }

    /// Height assumed for `item` until it is measured.
    final func estimatedHeight(for item: Item) -> CGFloat {
        guard let index = registrationIndex(for: item) else { return estimatedRowHeight }
        return registrations[index].estimatedHeight ?? estimatedRowHeight
    }

    /// The estimate every item gets when it does not depend on the item: the
    /// first registration claims everything, or there are none yet. Nil when
    /// each item has to be asked.
    final var uniformEstimatedHeight: CGFloat? {
        guard let first = registrations.first else { return estimatedRowHeight }
        guard first.matches == nil else { return nil }
        return first.estimatedHeight ?? estimatedRowHeight
    }

    final func registration(_ index: Int) -> ListRowRegistration<Item> {
        registrations[index]
    }

    final func context(at index: Int, purpose: ListRowPurpose) -> ListRowContext {
        .init(index: index, width: bounds.width, purpose: purpose)
    }

    /// A hidden row kept for measuring registrations that have no height
    /// closure. Parented to the list so it inherits appearance and traits,
    /// but pinned out of the way and never treated as content.
    final func prototype(for registrationIndex: Int) -> Prototype {
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

    /// Mounts a row for every index the mounted area covers that has none.
    final func prepareVisibleRows() {
        for index in rowLayout.indices(intersecting: mountRect) {
            ensureRowView(at: index)
        }
    }

    /// Mounts a row for the item at `index` unless one is mounted already.
    ///
    /// Runs for every mounted index on every layout pass, so it is not
    /// overridable; the overridable step is ``mountRowView(at:)``, which it
    /// calls only when there is a row to mount.
    final func ensureRowView(at index: Int) {
        guard index >= 0, index < items.count,
              visibleRows[items[index].id] == nil
        else { return }
        mountRowView(at: index)
    }

    /// Mounts a row for the item at `index`, which has none mounted.
    ///
    /// The row comes from ``dequeueReusableRowView(forRegistrationAt:)``, or
    /// ``makeRowView(forRegistrationAt:)`` when the pool is empty, is placed,
    /// reset with ``ListRowView/prepareForReuse()``, filled in through
    /// ``configureRowView(_:with:at:registrationIndex:)`` and added to the
    /// list. Does nothing for an item no registration claims.
    ///
    /// The list calls it as the layout brings an item into the mounted area,
    /// and when a changed item moves to another row type. An override must
    /// call `super`, and must not call it for an index that is mounted.
    open func mountRowView(at index: Int) {
        let item = items[index]
        assert(visibleRows[item.id] == nil, "row \(item.id) is already mounted")
        guard let registrationIndex = registrationIndex(for: item) else { return }

        let view: ListRowView
        if let recycled = dequeueReusableRowView(forRegistrationAt: registrationIndex) {
            // Whatever motion is left on it was aimed at the item it used to
            // show. Cancelling here rather than at recycle time keeps a row
            // that is only passing through the pool within one pass — still on
            // screen, still sliding — from losing an animation the list owns.
            cancelRowAnimations(on: recycled)
            view = recycled
        } else {
            view = makeRowView(forRegistrationAt: registrationIndex)
        }
        // Placed before it is filled in or parented. A pooled row is still
        // sitting at someone else's frame, so configuring it there would lay
        // its contents out against a size about to change, and parenting it
        // there would show it in the wrong place for a frame.
        setRowFrame(rectForRow(at: index), on: view, animated: false)
        view.beginMount()
        rowsPendingSettle.append(view)
        // Filled in without animating. A pooled row still shows the previous
        // item, and whatever the configuration changes would otherwise travel
        // from that item's values on the curve of any animation the host has
        // open around the pass.
        withoutListAnimation {
            view.prepareForReuse()
            configureRowView(view, with: item, at: index, registrationIndex: registrationIndex)
        }
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
    ///
    /// Runs for every ``update(_:)`` and for the mounted rows an apply
    /// changed or moved; does nothing for an item with no row mounted. An
    /// override must call `super`.
    open func reconfigureRow(with identifier: Item.ID) {
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
        configureRowView(entry.view, with: item, at: index, registrationIndex: entry.registration)
        entry.view.requestLayout()
    }

    /// Fills `view` in with `item` through the configuration of the
    /// registration at `registrationIndex`, for display.
    ///
    /// Called when a row is mounted, after ``ListRowView/prepareForReuse()``,
    /// and when a mounted row is refilled, without it. Measurement of a
    /// self-sizing row configures its hidden prototype directly and never
    /// comes through here. An override must call `super`.
    open func configureRowView(
        _ view: ListRowView,
        with item: Item,
        at index: Int,
        registrationIndex: Int
    ) {
        registrations[registrationIndex].configure(
            view,
            item,
            context(at: index, purpose: .display)
        )
    }

    /// Makes a new row view for the registration at `registrationIndex`,
    /// when the pool has none to hand out.
    ///
    /// An override may return a configured instance of its own, but it must
    /// be of the row type that registration declared, since its
    /// configuration casts to that type. The hidden prototype a self-sizing
    /// registration is measured on is made directly, not through here.
    open func makeRowView(forRegistrationAt registrationIndex: Int) -> ListRowView {
        registrations[registrationIndex].makeRow()
    }

    /// Takes the most recently recycled row of the registration at
    /// `registrationIndex` out of the pool, or nil when the pool is empty.
    ///
    /// The most recent one is still warm in cache, and a pool has no
    /// ordering to preserve. An override that hands out a view of its own
    /// must not hand out one that is still mounted.
    open func dequeueReusableRowView(forRegistrationAt registrationIndex: Int) -> ListRowView? {
        reusePools[registrationIndex].popLast()
    }

    /// Returns a row the list has just unmounted to the pool of the
    /// registration at `registrationIndex`.
    ///
    /// The row leaves the view hierarchy at the end of the pass unless it is
    /// mounted again first. An override that does not call `super` keeps
    /// the row out of the pool; the list holds no other reference to it.
    open func enqueueReusableRowView(_ view: ListRowView, forRegistrationAt registrationIndex: Int) {
        reusePools[registrationIndex].append(view)
    }

    /// Recycles the rows the viewport has left behind.
    ///
    /// This reads the same rectangle mounting reads. It used to build its own
    /// in the scroll space instead, which picked the same rows only because
    /// `rectForRow(at:)` and the offset each carry `topInset` and the two
    /// cancelled. An agreement that holds by cancellation is one that breaks
    /// the first time either side is widened.
    ///
    /// Runs once per layout pass, so it is not overridable; every row it
    /// unmounts goes through the overridable ``recycleRow(with:)``.
    private final func recycleRowsOutsideViewport() {
        let visibleRect = mountRect
        let now = CACurrentMediaTime()
        heldRows = heldRows.filter { $0.value > now }
        let stale = visibleRows.compactMap { identifier, _ -> Item.ID? in
            guard let index = indexByID[identifier],
                  let frame = rowLayout.frame(for: index)
            else { return identifier }
            if heldRows[identifier] != nil { return nil }
            return frame.intersects(visibleRect) ? nil : identifier
        }
        for identifier in stale {
            recycleRow(with: identifier)
        }
    }

    /// Keeps every row on screen mounted for `duration`, then lays out once
    /// so the ones the layout has moved away are recycled.
    final func holdMountedRows(for duration: TimeInterval) {
        guard duration > 0 else { return }
        let releaseTime = CACurrentMediaTime() + duration
        for identifier in visibleRows.keys {
            heldRows[identifier] = max(heldRows[identifier] ?? 0, releaseTime)
        }
        // A timer rather than a dispatch: it fires from a nested run loop too,
        // and one rescheduled later covers everything an earlier one would.
        heldRowRelease?.invalidate()
        let latest = heldRows.values.max() ?? releaseTime
        heldRowRelease = Timer.scheduledTimer(
            withTimeInterval: max(0, latest - CACurrentMediaTime()),
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.heldRowRelease = nil
                self?.requestLayout()
            }
        }
        if let heldRowRelease {
            RunLoop.main.add(heldRowRelease, forMode: .common)
        }
    }

    /// Unmounts the row showing `identifier` and hands it to
    /// ``enqueueReusableRowView(_:forRegistrationAt:)``, returning it, or
    /// returns nil when no row is mounted for it.
    ///
    /// Every unmount comes through here: rows leaving the mounted area,
    /// removed items, and a changed item that now belongs to another row
    /// type. An override must call `super`; one that returns early without
    /// it keeps the row mounted, and is asked again on the next pass.
    @discardableResult
    open func recycleRow(with identifier: Item.ID) -> ListRowView? {
        guard let entry = visibleRows.removeValue(forKey: identifier) else { return nil }
        heldRows[identifier] = nil
        // Whatever the animator was showing belonged to the item leaving, so
        // it does not travel to the next one on the same view, and neither
        // does the spring it was showing it with.
        clearRowDisplacement(on: entry.view)
        forgetRowAnimation(of: entry.view)
        enqueueReusableRowView(entry.view, forRegistrationAt: entry.registration)
        rowsPendingRemoval.append(entry.view)
        return entry.view
    }

    /// Runs twice in every layout pass, which on most frames of a scroll has
    /// recycled nothing. The early return keeps those frames from building a
    /// set of every mounted row only to find nothing to look up in it.
    private final func removeUnusedRowsFromSuperview() {
        guard !rowsPendingRemoval.isEmpty else { return }
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
    private final func setAlpha(_ alpha: CGFloat, onRowWith identifier: Item.ID, animated: Bool) {
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
