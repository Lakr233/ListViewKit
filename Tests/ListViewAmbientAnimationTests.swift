//
//  ListViewAmbientAnimationTests.swift
//  ListViewKit
//
//  A list update routinely runs inside somebody else's animation: the keyboard
//  pattern wraps `layoutIfNeeded()` in a block, and the whole layout pass —
//  including the placement of rows entering the viewport — happens in there.
//  Nothing the layout pass does is the caller's animation to inherit.
//
//  Runs on both platforms; the UIKit half needs
//  `xcodebuild test -scheme ListViewKitTests -destination 'platform=iOS Simulator,…'`.
//

#if canImport(UIKit)
    import Testing
    import UIKit
    @testable import ListViewKit

    private typealias PlatformView = UIView
#elseif canImport(AppKit)
    import AppKit
    import Testing
    @testable import ListViewKit

    private typealias PlatformView = NSView
#endif

private struct AmbientItem: Identifiable, Hashable {
    let id: Int
    var revision = 0
}

/// Row heights the test can change between passes.
@MainActor
private final class HeightBox {
    var values: [Int: CGFloat] = [:]
}

/// A row that positions a subview from the item it was given, so a reused one
/// has its contents in the wrong place until its first layout.
@MainActor
private final class AmbientRow: ListRowView {
    let marker = PlatformView(frame: .zero)
    var markerOffset: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if canImport(AppKit)
            marker.wantsLayer = true
        #endif
        addSubview(marker)
    }

    #if canImport(UIKit)
        override func layoutSubviews() {
            super.layoutSubviews()
            marker.frame = CGRect(x: markerOffset, y: 0, width: 10, height: 10)
        }
    #elseif canImport(AppKit)
        override func layout() {
            super.layout()
            marker.frame = CGRect(x: markerOffset, y: 0, width: 10, height: 10)
        }
    #endif
}

@Suite(.serialized)
@MainActor
struct ListViewAmbientAnimationTests {
    private static let rowHeight: CGFloat = 100

    private func makeListView(
        count: Int = 40,
        size: CGSize = CGSize(width: 200, height: 200),
        heights: HeightBox = .init(),
        inWindow: Bool = false
    ) -> ListView<AmbientItem> {
        let listView = ListView<AmbientItem>(frame: CGRect(origin: .zero, size: size))
        if inWindow {
            attachToWindow(listView, size: size)
        }
        listView.rows {
            ListRow(AmbientRow.self)
                .height { item, _ in heights.values[item.id] ?? Self.rowHeight }
                .configure { row, item, _ in
                    row.markerOffset = CGFloat(item.id % 7) * 10
                }
        }
        listView.apply((0 ..< count).map { AmbientItem(id: $0) })
        settle(listView)
        return listView
    }

    /// Snapshotting a row needs a rendered view hierarchy, which on UIKit means
    /// a real window.
    private func attachToWindow(_ listView: ListView<AmbientItem>, size: CGSize) {
        let frame = CGRect(origin: .zero, size: size)
        #if canImport(UIKit)
            let window = UIWindow(frame: frame)
            window.addSubview(listView)
            window.makeKeyAndVisible()
            // `snapshotView(afterScreenUpdates: false)` has nothing to copy
            // until the hierarchy has been rendered once.
            window.layoutIfNeeded()
            CATransaction.flush()
        #else
            let window = NSWindow(
                contentRect: frame,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView?.addSubview(listView)
        #endif
    }

    private func settle(_ listView: ListView<AmbientItem>) {
        requestLayout(listView)
        for _ in 0 ..< 200 where listView.rowLayout.hasPendingRows {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        requestLayout(listView)
    }

    private func requestLayout(_ listView: ListView<AmbientItem>) {
        #if canImport(UIKit)
            listView.setNeedsLayout()
            listView.layoutIfNeeded()
        #else
            listView.needsLayout = true
            listView.layoutSubtreeIfNeeded()
        #endif
    }

    /// Stands in for a host animating around a list update — the keyboard case.
    ///
    /// `@escaping` only to satisfy `UIView.animate`, which runs the block
    /// synchronously; nothing here outlives the call.
    private func inAnAmbientAnimation(_ body: @escaping () -> Void) {
        #if canImport(UIKit)
            UIView.animate(withDuration: 0.35) { body() }
        #else
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.allowsImplicitAnimation = true
                body()
            }
        #endif
    }

    private func animationKeys(of view: PlatformView) -> [String] {
        #if canImport(UIKit)
            view.layer.animationKeys() ?? []
        #else
            view.layer?.animationKeys() ?? []
        #endif
    }

    private func presentedFrame(of view: PlatformView) -> CGRect? {
        #if canImport(UIKit)
            view.layer.presentation()?.frame
        #else
            view.layer?.presentation()?.frame
        #endif
    }

    // MARK: - Rows entering the viewport

    /// The reported bug: a row scrolled back into view is taken from the pool
    /// still carrying the frame of whoever used it last, and placing it inside
    /// an ambient animation slides it in from there.
    @Test
    func aRecycledRowEntersWithoutSlidingFromItsOldPlace() throws {
        let listView = makeListView()

        // Push the first rows out so the pool has something in it.
        listView.contentOffset.y = 2000
        requestLayout(listView)
        #expect(listView.rowView(for: 0) == nil)

        // Now bring fresh rows in with the layout pass inside a foreign block,
        // exactly as `UIView.animate { … layoutIfNeeded() }` would.
        listView.contentOffset.y = 1000
        inAnAmbientAnimation {
            requestLayout(listView)
        }

        let entering = try #require(listView.rowView(for: 10))
        #expect(animationKeys(of: entering).isEmpty)
        #expect(entering.frame == listView.rectForRow(at: 10))
        if let presented = presentedFrame(of: entering) {
            #expect(presented == entering.frame)
        }
    }

    /// A row created for the first time starts at the origin, so an ambient
    /// context flies it in from the corner. Growing the list is how the
    /// keyboard case reaches this: more of the content fits, and the rows
    /// filling the new space have never existed before.
    @Test
    func aFreshRowEntersWithoutFlyingInFromTheOrigin() throws {
        let listView = makeListView(count: 40, size: CGSize(width: 200, height: 200))
        #expect(listView.rowView(for: 5) == nil)

        inAnAmbientAnimation {
            listView.frame = CGRect(x: 0, y: 0, width: 200, height: 600)
            requestLayout(listView)
        }

        let entering = try #require(listView.rowView(for: 5))
        #expect(animationKeys(of: entering).isEmpty)
        #expect(entering.frame == listView.rectForRow(at: 5))
    }

    /// Motion left on a row belongs to the item it used to show. Reusing the
    /// view without dropping it lets the old slide finish under new content.
    @Test
    func aPooledRowCarriesNoAnimationIntoNewContent() throws {
        let listView = makeListView(count: 40)

        // An animated reorder leaves additive slides on the visible rows.
        var reordered = listView.content
        reordered.swapAt(0, 1)
        listView.apply(reordered, animated: true)
        let slid = try #require(listView.rowView(for: 0))
        #expect(!animationKeys(of: slid).isEmpty)

        // Recycle it without waiting for the slide, then bring the view back
        // under a different item.
        listView.contentOffset.y = 2000
        requestLayout(listView)
        listView.contentOffset.y = 2400
        requestLayout(listView)

        for view in listView.visibleRowViews {
            #expect(animationKeys(of: view).isEmpty)
        }
    }

    /// Placement fixes the row's own frame; its contents have to settle without
    /// animating too, or a reused row's subviews slide over from the previous
    /// item's arrangement.
    @Test
    func anEnteringRowLaysOutItsContentsWithoutAnimating() throws {
        let listView = makeListView()

        listView.contentOffset.y = 2000
        requestLayout(listView)

        listView.contentOffset.y = 1000
        inAnAmbientAnimation {
            requestLayout(listView)
        }
        // The row's own layout runs as the pass descends into it, which for
        // UIKit is inside the same `layoutIfNeeded()` the host called.
        inAnAmbientAnimation {
            requestLayout(listView)
        }

        let entering = try #require(listView.rowView(for: 10) as? AmbientRow)
        #expect(animationKeys(of: entering.marker).isEmpty)
    }

    // MARK: - The layout pass at large

    @Test
    func theLayoutPassDoesNotAnimateRowFrames() throws {
        let heights = HeightBox()
        let listView = makeListView(count: 40, heights: heights)
        let rowsBefore = listView.visibleRowViews
        #expect(rowsBefore.count > 1)

        // A height change moves every row below it. Inside a foreign block the
        // layout pass would hand that motion to the caller's curve.
        heights.values[0] = 40
        listView.invalidateLayout(forRowWith: 0)
        inAnAmbientAnimation {
            requestLayout(listView)
        }
        #expect(listView.rectForRow(at: 0).height == 40)

        // Not just "no implicit position animation": the hand-built additive
        // slide is a list animation too, and a layout pass never owns one.
        for view in rowsBefore where view.superview != nil {
            #expect(animationKeys(of: view).isEmpty)
        }
    }

    @Test
    func aForeignContextDoesNotAnimateTheContentOffset() {
        let listView = makeListView(count: 40)
        listView.contentOffset.y = listView.maximumContentOffset.y

        // Shrinking the content pushes the offset past the edge; the clamp that
        // follows is a correction, not a scroll.
        inAnAmbientAnimation {
            listView.apply((0 ..< 5).map { AmbientItem(id: $0) })
            requestLayout(listView)
        }

        #expect(!animationKeys(of: listView).contains("bounds"))
        #expect(!animationKeys(of: listView).contains("bounds.origin"))
    }

    #if canImport(AppKit)
        @Test
        func theScrollerOverlayDoesNotSlideInsideAForeignContext() throws {
            let listView = makeListView(count: 40)
            let overlay = try #require(listView.subviews.first { view in
                view.subviews.contains { $0 is NSScroller }
            })

            listView.contentOffset.y = 900
            inAnAmbientAnimation {
                requestLayout(listView)
            }

            #expect(animationKeys(of: overlay).isEmpty)
        }
    #endif

    /// Suppressing a new animation and stopping one already running are
    /// different operations. A layout pass runs on every scroll, so conflating
    /// them would cut every reorder short.
    @Test
    func aLayoutPassDoesNotCancelTheListsOwnAnimation() throws {
        let listView = makeListView(count: 3, size: CGSize(width: 200, height: 400))

        var reordered = listView.content
        reordered.swapAt(0, 2)
        listView.apply(reordered, animated: true)
        let sliding = try #require(listView.rowView(for: 0))
        let keysBefore = animationKeys(of: sliding)
        #expect(!keysBefore.isEmpty)

        requestLayout(listView)
        #expect(animationKeys(of: sliding) == keysBefore)
    }

    /// A pooled row is still sized for the item it used to show, so filling it
    /// in before it is placed lays its contents out against a size about to
    /// change.
    @Test
    func aRowIsConfiguredAtTheSizeItWillBeShownAt() {
        let heights = HeightBox()
        heights.values[10] = 160
        let listView = makeListView(count: 40, heights: heights)

        var sizeAtConfigure: CGSize?
        listView.rows {
            ListRow(AmbientRow.self)
                .height { item, _ in heights.values[item.id] ?? Self.rowHeight }
                .configure { row, item, _ in
                    if item.id == 10 { sizeAtConfigure = row.bounds.size }
                }
        }
        listView.apply((0 ..< 40).map { AmbientItem(id: $0) })
        settle(listView)

        listView.contentOffset.y = 900
        requestLayout(listView)

        #expect(sizeAtConfigure == listView.rectForRow(at: 10).size)
    }

    // MARK: - The list's own animations still run

    /// The suppression must not reach into `apply(animated:)`: an insertion
    /// fades and the rows it displaces slide, even when a host has its own
    /// animation open around the call.
    @Test
    func anAnimatedApplyFromInsideAForeignContextStillAnimates() throws {
        let listView = makeListView(count: 3, size: CGSize(width: 200, height: 400))

        inAnAmbientAnimation {
            listView.apply([AmbientItem(id: 99)] + listView.content, animated: true)
        }

        let inserted = try #require(listView.rowView(for: 99))
        let shifted = try #require(listView.rowView(for: 0))
        #expect(!animationKeys(of: inserted).isEmpty)
        #expect(!animationKeys(of: shifted).isEmpty)
        #if canImport(UIKit)
            #expect(inserted.alpha == 1)
        #else
            #expect(inserted.alphaValue == 1)
        #endif
    }

    /// The snapshot a removed row leaves behind is placed, not moved: it starts
    /// life at the origin, so an ambient context flies it in while it fades.
    ///
    /// AppKit only. `disposalSnapshot` is one shared call site, but UIKit
    /// reaches it through `snapshotView(afterScreenUpdates:)`, which has
    /// nothing to copy in a test host that never renders a frame.
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    @Test
    func aDisposalSnapshotDoesNotFlyInFromTheOrigin() throws {
        let listView = makeListView(
            count: 3,
            size: CGSize(width: 200, height: 400),
            inWindow: true
        )
        let rowViews = Set(listView.visibleRowViews.map { ObjectIdentifier($0) })

        inAnAmbientAnimation {
            listView.apply(listView.content.filter { $0.id != 1 }, animated: true)
        }

        let snapshot = try #require(listView.subviews.first { view in
            !(view is ListRowView) && !rowViews.contains(ObjectIdentifier(view))
                && view.frame.height == Self.rowHeight
        })
        #expect(!animationKeys(of: snapshot).contains("position"))
        if let presented = presentedFrame(of: snapshot) {
            #expect(presented.origin == snapshot.frame.origin)
        }
    }
    #endif
}
