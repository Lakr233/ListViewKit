//
//  ListViewRemeasureSlideTests.swift
//  ListViewKit
//
//  A row measured again — its content grew where it stands, nothing in the
//  items changed — moves the rows under it. Animated, they slide there from
//  where they stood, as in an animated apply, instead of jumping by what the
//  row gained in one frame. Runs on both platforms; the UIKit half with
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

private struct RemeasureItem: Identifiable, Hashable {
    let id: Int
}

/// The heights the rows measure at, changed under the list as content would be.
@MainActor
private final class Heights {
    var values: [Int: CGFloat] = [:]
    func height(of id: Int) -> CGFloat {
        values[id] ?? 100
    }
}

@Suite(
    .serialized,
    .disabled(
        if: ProcessInfo.processInfo.isMacCatalystApp,
        "A hostless Mac Catalyst test bundle has no NSApplication, so it cannot create a UIWindow"
    )
)
@MainActor
struct ListViewRemeasureSlideTests {
    /// A list in a real window: a layer publishes a presentation value only
    /// once something commits frames for it.
    private func makeListView(
        heights: Heights,
        count: Int = 8,
        topInset: CGFloat = 0
    ) -> (ListView<RemeasureItem>, AnyObject) {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        let listView = ListView<RemeasureItem>(frame: frame)
        listView.topInset = topInset
        #if canImport(UIKit)
            let window = makeWindow(frame: frame)
            window.addSubview(listView)
            window.makeKeyAndVisible()
        #else
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView?.addSubview(listView)
        #endif
        listView.rows {
            ListRow(ListRowView.self)
                .height { item, _ in heights.height(of: item.id) }
                .configure { _, _, _ in }
        }
        listView.apply((0 ..< count).map { RemeasureItem(id: $0) })
        settleLayout(listView)
        return (listView, window)
    }

    #if canImport(UIKit)
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

    private func settleLayout(_ listView: ListView<RemeasureItem>) {
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
        presentationFrame(of: view)?.minY
    }

    private func presentationFrame(of view: ListRowView) -> CGRect? {
        #if canImport(UIKit)
            view.layer.presentation()?.frame
        #else
            view.layer?.presentation()?.frame
        #endif
    }

    private func animationCount(on view: ListRowView) -> Int {
        #if canImport(UIKit)
            view.layer.animationKeys()?.count ?? 0
        #else
            view.layer?.animationKeys()?.count ?? 0
        #endif
    }

    private func settleSlides() {
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
    }

    private func advanceOneFrame() {
        RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
    }

    /// Row 1 grows by 60 pt: rows 2 and on are placed 60 pt lower at once,
    /// and shown sliding there from where they stood — under way, then
    /// landed — while row 1's box grows with them, its lower edge on row 2's
    /// upper one all the way; row 0, above it, does not move.
    @Test
    func rowsUnderARowMeasuredTallerSlideDown() throws {
        let heights = Heights()
        let (listView, window) = makeListView(heights: heights)
        defer { withExtendedLifetime(window) {} }
        let row0 = try #require(listView.rowView(for: 0))
        let row1 = try #require(listView.rowView(for: 1))
        let row2 = try #require(listView.rowView(for: 2))
        let before0 = row0.placedFrame.minY
        let before2 = row2.placedFrame.minY

        heights.values[1] = 160
        listView.invalidateLayout(forRowsWith: [1], animated: true)

        #expect(abs(row2.placedFrame.minY - (before2 + 60)) < 0.5)
        #expect(abs(row0.placedFrame.minY - before0) < 0.5)
        #expect(abs(row1.placedFrame.height - 160) < 0.5)
        var underWay = false
        for _ in 0 ..< 20 {
            advanceOneFrame()
            guard let shown = presentationY(of: row2), let box = presentationFrame(of: row1) else { continue }
            #expect(shown > before2 - 1 && shown < before2 + 60 + 1)
            if shown > before2 + 1, shown < before2 + 59 {
                underWay = true
                // No overlap, no gap: row 1's box ends where row 2 begins.
                #expect(abs(box.maxY - shown) < 2)
            }
            #expect(abs((presentationY(of: row0) ?? -1) - before0) < 0.5)
        }
        #expect(underWay)
        settleSlides()
        #expect(abs((presentationY(of: row2) ?? -1) - (before2 + 60)) < 0.5)
    }

    /// Unanimated, the rows are where they belong in the frame that measures
    /// them: the call the list has always had.
    @Test
    func unanimatedTheRowsArePlacedAtOnce() throws {
        let heights = Heights()
        let (listView, window) = makeListView(heights: heights)
        defer { withExtendedLifetime(window) {} }
        let row2 = try #require(listView.rowView(for: 2))
        let before2 = row2.placedFrame.minY

        heights.values[1] = 160
        listView.invalidateLayout(forRowsWith: [1], animated: false)
        settleLayout(listView)

        #expect(abs(row2.placedFrame.minY - (before2 + 60)) < 0.5)
        #expect(animationCount(on: row2) == 0)
        advanceOneFrame()
        #expect(abs((presentationY(of: row2) ?? -1) - (before2 + 60)) < 0.5)
    }

    /// A row above the list's anchor — cut by the top edge — growing goes into
    /// the offset: the anchor and the rows under it keep their place on
    /// screen and do not slide; the row grows upward from the anchor, its
    /// lower edge on the anchor's upper one throughout.
    @Test
    func aRowGrowingAboveTheAnchorMovesNothingUnderIt() throws {
        let heights = Heights()
        let (listView, window) = makeListView(heights: heights, count: 20)
        defer { withExtendedLifetime(window) {} }
        listView.setContentOffset(CGPoint(x: 0, y: 250), animated: false)
        settleLayout(listView)
        let row2 = try #require(listView.rowView(for: 2))
        let row3 = try #require(listView.rowView(for: 3))
        let row4 = try #require(listView.rowView(for: 4))
        let onScreen3 = row3.placedFrame.minY - listView.contentOffset.y
        let onScreen4 = row4.placedFrame.minY - listView.contentOffset.y

        // Row 2 spans 200...300, cut by the top edge at 250.
        heights.values[2] = 160
        listView.invalidateLayout(forRowsWith: [2], animated: true)

        #expect(abs(row3.placedFrame.minY - listView.contentOffset.y - onScreen3) < 0.5)
        #expect(abs(row4.placedFrame.minY - listView.contentOffset.y - onScreen4) < 0.5)
        for _ in 0 ..< 10 {
            advanceOneFrame()
            let shown3 = try #require(presentationY(of: row3))
            #expect(abs(shown3 - row3.placedFrame.minY) < 0.5)
            #expect(abs((presentationY(of: row4) ?? -1) - row4.placedFrame.minY) < 0.5)
            if let box = presentationFrame(of: row2) {
                #expect(abs(box.maxY - shown3) < 2)
            }
        }
    }

    /// A list with a top inset, a row shrinking: the row that comes on
    /// screen at the bottom rises in from under the edge, with the rows above
    /// it, rather than starting the inset's height too high.
    @Test
    func aRowComingOnScreenRisesFromUnderTheEdge() throws {
        let heights = Heights()
        let (listView, window) = makeListView(heights: heights, count: 12, topInset: 100)
        defer { withExtendedLifetime(window) {} }
        #expect(listView.rowView(for: 5) == nil)

        heights.values[1] = 40
        listView.invalidateLayout(forRowsWith: [1], animated: true)

        let entering = try #require(listView.rowView(for: 5))
        let target = entering.placedFrame.minY
        var rose = false
        for _ in 0 ..< 20 {
            advanceOneFrame()
            guard let shown = presentationY(of: entering) else { continue }
            // Never above where it is headed: it comes up from below.
            #expect(shown > target - 1)
            if shown > target + 1 { rose = true }
        }
        #expect(rose)
        settleSlides()
        #expect(abs((presentationY(of: entering) ?? -1) - target) < 0.5)
    }
}
