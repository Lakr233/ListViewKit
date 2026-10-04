//
//  ListViewReorderAnimationTests.swift
//  ListViewKit
//
//  The only suite that runs on both platforms: overlapping reorders are the
//  one place where UIKit and AppKit reach the same behaviour by different
//  means, and both are worth holding still. Run the UIKit half with
//  `xcodebuild test -scheme ListViewKit-Package -destination 'platform=iOS Simulator,…'`.
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

@Suite(
    .serialized,
    .disabled(
        if: ProcessInfo.processInfo.isMacCatalystApp,
        "A hostless Mac Catalyst test bundle has no NSApplication, so it cannot create a UIWindow"
    )
)
@MainActor
struct ListViewReorderAnimationTests {
    private static let rowHeight: CGFloat = 100

    /// A list in a real window, since a layer only publishes a presentation
    /// value once something is committing frames for it.
    private func makeListView(count: Int = 5) -> ListView<ReorderItem> {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        let listView = ListView<ReorderItem>(frame: frame)
        #if canImport(UIKit)
            let window = makeWindow(frame: frame)
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
        listView.apply((0 ..< count).map { ReorderItem(id: $0) })
        settleLayout(listView)
        return listView
    }

    #if canImport(UIKit)
        /// A window that draws. In an app with scenes, a window outside every
        /// scene is never on screen, so nothing commits frames for its layers
        /// and they have no presentation value; such a host gets the window
        /// attached to its scene.
        private func makeWindow(frame: CGRect) -> UIWindow {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
            guard let scene else { return UIWindow(frame: frame) }
            let window = UIWindow(windowScene: scene)
            window.frame = frame
            return window
        }
    #endif

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
    ///
    /// Speeds are taken per second of real time, and a run whose frames
    /// overran is thrown away and run again. A busy machine can stretch a
    /// frame's run-loop slice to a quarter of a second, and by then the first
    /// slide has nearly landed: a row slowing into its destination looks
    /// exactly like the stall this is looking for.
    @Test
    func interruptingAReorderKeepsTheRowsMoving() throws {
        for _ in 0 ..< 10 {
            guard let speeds = try speedsAcrossAnInterruptedReorder() else { continue }
            // The row has to be genuinely under way, or there is no stall to
            // catch: a point a frame at 60Hz.
            #expect(speeds.before > 60)
            // Measured: ~0.93x of the previous frame's speed when the slide is
            // additive, ~0.11x when the new animation replaces the old one.
            #expect(speeds.after > speeds.before / 2)
            return
        }
        // Not a failure of the list: there was no run to judge it on.
        withKnownIssue("Every run overran its frames; the machine was too busy to measure on.", isIntermittent: true) {
            Issue.record("No run kept its frames on time.")
        }
    }

    /// Row 0's speed, in points per second, in the frame before a second
    /// reorder and the frame after it, or nil if the timing overran.
    private func speedsAcrossAnInterruptedReorder() throws -> (before: CGFloat, after: CGFloat)? {
        let listView = makeListView()
        let row = try #require(listView.rowView(for: 0))

        listView.apply([4, 0, 1, 2, 3].map { ReorderItem(id: $0) }, animated: true)
        let started = CACurrentMediaTime()
        // Long enough for frames to have been committed and the slide to be
        // under way. Only the two frames measured below have to be on time.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard let before = try speed(of: row) else { return nil }

        listView.apply([3, 4, 0, 1, 2].map { ReorderItem(id: $0) }, animated: true)
        guard let after = try speed(of: row) else { return nil }
        // The first slide lasts half a second, and past this it is already
        // slowing to land.
        guard CACurrentMediaTime() - started < 0.3 else { return nil }
        return (before, after)
    }

    /// Points per second across one frame, or nil if the frame overran.
    private func speed(of row: ListRowView) throws -> CGFloat? {
        let startY = try #require(presentationY(of: row))
        let startTime = CACurrentMediaTime()
        advanceOneFrame()
        let endY = try #require(presentationY(of: row))
        let elapsed = CACurrentMediaTime() - startTime
        guard elapsed < 2.0 / 60 else { return nil }
        return (endY - startY) / elapsed
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

    /// A row that only comes on screen because of the change slides in from
    /// the side it was on, rather than appearing at its destination.
    @Test
    func aRowMovedOnScreenSlidesInFromBeyondTheEdge() throws {
        let listView = makeListView(count: 20)
        #expect(listView.rowView(for: 15) == nil)

        var order = Array(0 ..< 20)
        order.remove(at: 15)
        order.insert(15, at: 0)
        listView.apply(order.map { ReorderItem(id: $0) }, animated: true)
        let row = try #require(listView.rowView(for: 15))
        #expect(row.placedFrame.minY == 0)

        advanceOneFrame()
        // It was below the viewport, so it starts below the viewport's
        // bottom edge and is still most of the way there one frame in.
        let presented = try #require(presentationY(of: row))
        #expect(presented > listView.bounds.height / 2)
    }

    /// A row moved off screen is still on screen until its slide ends, so a
    /// layout pass in the meantime must not take it away.
    @Test
    func aRowMovedOffScreenStaysUntilItsSlideEnds() throws {
        let listView = makeListView(count: 20)
        let row = try #require(listView.rowView(for: 0))

        var order = Array(0 ..< 20)
        order.remove(at: 0)
        order.append(0)
        listView.apply(order.map { ReorderItem(id: $0) }, animated: true)
        advanceOneFrame()
        listView.requestLayout()
        settleLayout(listView)
        #expect(listView.rowView(for: 0) === row)
        #expect(row.superview === listView)

        // Once the slide has ended, the next pass lets it go.
        RunLoop.main.run(until: Date().addingTimeInterval(listRowSlideDuration + 0.05))
        listView.requestLayout()
        settleLayout(listView)
        #expect(listView.rowView(for: 0) == nil)
        #expect(listView.heldRows.isEmpty)
    }
}
