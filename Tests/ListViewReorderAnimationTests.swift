//
//  ListViewReorderAnimationTests.swift
//  ListViewKit
//
//  The only suite that runs on both platforms: overlapping reorders are the
//  one place where UIKit and AppKit reach the same behaviour by different
//  means, and both are worth holding still. Run the UIKit half with
//  `xcodebuild test -scheme ListViewKitTests -destination 'platform=iOS Simulator,…'`.
//

#if canImport(UIKit)
    import Testing
    import UIKit
    @testable import ListViewKit
#elseif canImport(AppKit)
    import AppKit
    import Testing
    @testable import ListViewKit
#endif

private struct ReorderItem: Identifiable, Hashable {
    let id: Int
}

@Suite(.serialized)
@MainActor
struct ListViewReorderAnimationTests {
    private static let rowHeight: CGFloat = 100

    /// A list in a real window, since a layer only publishes a presentation
    /// value once something is committing frames for it.
    private func makeListView() -> ListView<ReorderItem> {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        let listView = ListView<ReorderItem>(frame: frame)
        #if canImport(UIKit)
            let window = UIWindow(frame: frame)
            window.addSubview(listView)
            window.makeKeyAndVisible()
        #else
            let window = NSWindow(
                contentRect: frame,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView?.addSubview(listView)
        #endif
        listView.rows {
            ListRow(ListRowView.self)
                .height { _, _ in Self.rowHeight }
                .configure { _, _, _ in }
        }
        listView.apply((0 ..< 5).map { ReorderItem(id: $0) })
        settleLayout(listView)
        return listView
    }

    private func settleLayout(_ listView: ListView<ReorderItem>) {
        #if canImport(UIKit)
            listView.layoutIfNeeded()
        #else
            listView.layoutSubtreeIfNeeded()
        #endif
        for _ in 0 ..< 50 {
            guard listView.rowLayout.hasPendingRows else { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    private func presentationY(of view: ListRowView) -> CGFloat? {
        #if canImport(UIKit)
            view.layer.presentation()?.frame.origin.y
        #else
            view.layer?.presentation()?.frame.origin.y
        #endif
    }

    private func advanceOneFrame() {
        RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
    }

    /// A reorder arriving while the previous one is still running must add to
    /// it, not replace it.
    ///
    /// Replacing restarts the curve from rest, which is what the reader sees as
    /// the first animation ending early: the rows stop dead mid-slide and set
    /// off again. Both orders here move row 0 further down, so a stall shows up
    /// as lost speed rather than as a change of direction.
    @Test
    func interruptingAReorderKeepsTheRowsMoving() throws {
        let listView = makeListView()
        let row = try #require(listView.rowView(for: 0))

        listView.apply([4, 0, 1, 2, 3].map { ReorderItem(id: $0) }, animated: true)
        // A layer has no presentation value until something commits a frame.
        advanceOneFrame()
        var speedBefore: CGFloat = 0
        for _ in 0 ..< 8 {
            let start = try #require(presentationY(of: row))
            advanceOneFrame()
            speedBefore = try #require(presentationY(of: row)) - start
        }
        // The row has to be genuinely under way, or there is no stall to catch.
        #expect(speedBefore > 1)

        listView.apply([3, 4, 0, 1, 2].map { ReorderItem(id: $0) }, animated: true)
        let start = try #require(presentationY(of: row))
        advanceOneFrame()
        let speedAfter = try #require(presentationY(of: row)) - start

        // Measured: ~0.93x of the previous frame's speed when the slide is
        // additive, ~0.11x when the new animation replaces the old one.
        #expect(speedAfter > speedBefore / 2)
    }

    /// Blending two animations must not cost the destination: whatever the
    /// rows do on the way, they have to land on the frames layout gave them.
    @Test
    func anInterruptedReorderStillLandsOnItsFinalFrames() throws {
        let listView = makeListView()

        listView.apply([4, 0, 1, 2, 3].map { ReorderItem(id: $0) }, animated: true)
        for _ in 0 ..< 9 { advanceOneFrame() }
        let finalOrder = [3, 4, 0, 1, 2].map { ReorderItem(id: $0) }
        listView.apply(finalOrder, animated: true)

        for _ in 0 ..< 240 {
            advanceOneFrame()
            let arrived = listView.content.allSatisfy { item in
                guard let row = listView.rowView(for: item.id),
                      let presented = presentationY(of: row)
                else { return false }
                return abs(presented - row.frame.origin.y) < 0.5
            }
            if arrived { break }
        }

        for (index, item) in finalOrder.enumerated() {
            let row = try #require(listView.rowView(for: item.id))
            #expect(row.frame.origin.y == CGFloat(index) * Self.rowHeight)
            let presented = try #require(presentationY(of: row))
            #expect(abs(presented - row.frame.origin.y) < 0.5)
        }
    }
}
