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

/// A row whose one subview fills it, laid out by the row: what a row's
/// contents do when its box changes size.
@MainActor
private final class FillRow: ListRowView {
    #if canImport(UIKit)
        let fill = UIView()
    #else
        let fill = NSView()
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(fill)
    }

    #if canImport(UIKit)
        override func layoutSubviews() {
            super.layoutSubviews()
            fill.frame = bounds
        }
    #else
        override func layout() {
            super.layout()
            fill.frame = bounds
        }
    #endif
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
            ListRow(FillRow.self)
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
        #expect(animationCount(on: row3) == 0)
        #expect(animationCount(on: row4) == 0)
        var growing = false
        for _ in 0 ..< 10 {
            advanceOneFrame()
            let shown3 = try #require(presentationY(of: row3))
            #expect(abs(shown3 - row3.placedFrame.minY) < 0.5)
            #expect(abs((presentationY(of: row4) ?? -1) - row4.placedFrame.minY) < 0.5)
            let box = try #require(presentationFrame(of: row2))
            #expect(abs(box.maxY - shown3) < 2)
            if box.height > 101, box.height < 159 { growing = true }
        }
        // Its box opened over the frames, not at once.
        #expect(growing)
    }

    /// The last row in sight closes from 500 pt to 200: the rows under it
    /// come on screen and rise with its lower edge, flush with it, rather
    /// than standing at their places over the box still closing.
    @Test
    func rowsUnderAClosingLastRowRiseWithItsEdge() throws {
        let heights = Heights()
        heights.values[1] = 500
        let (listView, window) = makeListView(heights: heights)
        defer { withExtendedLifetime(window) {} }
        let closing = try #require(listView.rowView(for: 1))
        #expect(listView.rowView(for: 2) == nil)

        heights.values[1] = 200
        listView.invalidateLayout(forRowsWith: [1], animated: true)

        let entering = try #require(listView.rowView(for: 2))
        var under = false
        for _ in 0 ..< 20 {
            advanceOneFrame()
            guard let box = presentationFrame(of: closing), let shown = presentationY(of: entering) else { continue }
            #expect(abs(box.maxY - shown) < 2)
            if shown > entering.placedFrame.minY + 1 { under = true }
        }
        #expect(under)
    }

    /// A row closes while the row under it straddles the lower edge: the row
    /// that comes on screen under that one moves with it, flush, from where
    /// it was — not held at the edge, inside it.
    @Test
    func aRowComingOnUnderAStraddlerMovesWithIt() throws {
        let heights = Heights()
        heights.values[1] = 300
        heights.values[2] = 300
        let (listView, window) = makeListView(heights: heights)
        defer { withExtendedLifetime(window) {} }
        let straddler = try #require(listView.rowView(for: 2))
        #expect(listView.rowView(for: 3) == nil)

        heights.values[1] = 100
        listView.invalidateLayout(forRowsWith: [1], animated: true)

        let entering = try #require(listView.rowView(for: 3))
        var moving = false
        for _ in 0 ..< 20 {
            advanceOneFrame()
            let box = try #require(presentationFrame(of: straddler))
            let shown = try #require(presentationY(of: entering))
            #expect(abs(box.maxY - shown) < 2)
            if shown > entering.placedFrame.minY + 1 { moving = true }
        }
        #expect(moving)
    }

    /// With a top inset, a row straddling the upper edge closes: the offset
    /// takes it up, and the row that comes on screen above it moves down
    /// with its upper edge, flush, rather than starting inside it.
    @Test
    func aRowComingOnAboveAClosingStraddlerMovesWithIt() throws {
        let heights = Heights()
        let (listView, window) = makeListView(heights: heights, count: 20, topInset: 100)
        defer { withExtendedLifetime(window) {} }
        listView.setContentOffset(CGPoint(x: 0, y: 350), animated: false)
        settleLayout(listView)
        // Row 2 stands at 300...400 in the list's space, cut by the edge.
        let straddler = try #require(listView.rowView(for: 2))
        #expect(listView.rowView(for: 1) == nil)

        heights.values[2] = 20
        listView.invalidateLayout(forRowsWith: [2], animated: true)

        let entering = try #require(listView.rowView(for: 1))
        var moving = false
        for _ in 0 ..< 20 {
            advanceOneFrame()
            let box = try #require(presentationFrame(of: straddler))
            let shown = try #require(presentationFrame(of: entering))
            #expect(abs(shown.maxY - box.minY) < 2)
            if shown.minY < entering.placedFrame.minY - 1 { moving = true }
        }
        #expect(moving)
    }

    /// A second remeasure while the first one's slide is still running:
    /// the row that comes on screen is drawn against its neighbour as the
    /// reader sees it, mid-slide, all the way — not where the list already
    /// has that neighbour.
    ///
    /// A run whose frames overran is thrown away and run again, as the
    /// reorder suite does: on a machine too busy to keep its frames the
    /// slides land before they can be compared.
    @Test
    func aRowComingOnMidSlideStaysAgainstItsDrawnNeighbour() throws {
        for _ in 0 ..< 10 {
            guard let gaps = try gapsAcrossASecondRemeasure() else { continue }
            #expect(gaps.allSatisfy { $0 < 2 }, "largest gap \(gaps.max() ?? 0)")
            return
        }
        withKnownIssue("Every run overran its frames; the machine was too busy to measure on.", isIntermittent: true) {
            Issue.record("No run kept its frames on time.")
        }
    }

    /// The gap between the entering row and its neighbour, as drawn, each
    /// frame after the second remeasure, or nil if a frame overran.
    private func gapsAcrossASecondRemeasure() throws -> [CGFloat]? {
        let heights = Heights()
        let (listView, window) = makeListView(heights: heights, count: 12)
        defer { withExtendedLifetime(window) {} }
        heights.values[1] = 160
        listView.invalidateLayout(forRowsWith: [1], animated: true)
        advanceOneFrame()
        advanceOneFrame()
        let above = try #require(listView.rowView(for: 5))
        // Still on its way when the second remeasure comes.
        guard let midway = presentationY(of: above), abs(midway - above.placedFrame.minY) > 1 else { return nil }

        heights.values[1] = 20
        listView.invalidateLayout(forRowsWith: [1], animated: true)

        let entering = try #require(listView.rowView(for: 6))
        var gaps: [CGFloat] = []
        var moved = false
        for _ in 0 ..< 20 {
            let start = Date()
            advanceOneFrame()
            guard Date().timeIntervalSince(start) < 0.04 else { return nil }
            let box = try #require(presentationFrame(of: above))
            let shown = try #require(presentationY(of: entering))
            gaps.append(abs(box.maxY - shown))
            if abs(shown - entering.placedFrame.minY) > 1 { moved = true }
        }
        #expect(moved)
        return gaps
    }

    /// A second remeasure while the first one's box is still closing: the
    /// row that comes on under it starts against its lower edge as drawn,
    /// mid-close, and stays on it.
    @Test
    func aRowComingOnUnderAClosingBoxStaysOnItsEdge() throws {
        for _ in 0 ..< 10 {
            guard let gaps = try gapsUnderAClosingBox() else { continue }
            #expect(gaps.allSatisfy { $0 < 2 }, "largest gap \(gaps.max() ?? 0)")
            return
        }
        withKnownIssue("Every run overran its frames; the machine was too busy to measure on.", isIntermittent: true) {
            Issue.record("No run kept its frames on time.")
        }
    }

    private func gapsUnderAClosingBox() throws -> [CGFloat]? {
        let heights = Heights()
        heights.values[1] = 700
        let (listView, window) = makeListView(heights: heights)
        defer { withExtendedLifetime(window) {} }
        let closing = try #require(listView.rowView(for: 1))
        heights.values[1] = 500
        listView.invalidateLayout(forRowsWith: [1], animated: true)
        advanceOneFrame()
        advanceOneFrame()
        #expect(listView.rowView(for: 2) == nil)

        heights.values[1] = 200
        listView.invalidateLayout(forRowsWith: [1], animated: true)

        let entering = try #require(listView.rowView(for: 2))
        var gaps: [CGFloat] = []
        for _ in 0 ..< 20 {
            let start = Date()
            advanceOneFrame()
            guard Date().timeIntervalSince(start) < 0.04 else { return nil }
            let box = try #require(presentationFrame(of: closing))
            let shown = try #require(presentationY(of: entering))
            gaps.append(abs(box.maxY - shown))
        }
        return gaps
    }

    /// A pass still owed when the remeasure comes — the top inset changed —
    /// runs first: the rows above the change, which do not move, do not
    /// slide from where the owed pass would have put them.
    @Test
    func aPassOwedRunsBeforeTheRemeasure() throws {
        let heights = Heights()
        let (listView, window) = makeListView(heights: heights)
        defer { withExtendedLifetime(window) {} }
        let row0 = try #require(listView.rowView(for: 0))
        listView.topInset = 50

        heights.values[2] = 160
        listView.invalidateLayout(forRowsWith: [2], animated: true)

        #expect(animationCount(on: row0) == 0)
        advanceOneFrame()
        #expect(abs((presentationY(of: row0) ?? -1) - row0.placedFrame.minY) < 0.5)
    }

    /// A row whose box changes size lays its contents out at the new one.
    @Test
    func aResizedRowLaysOutItsContents() throws {
        let heights = Heights()
        let (listView, window) = makeListView(heights: heights)
        defer { withExtendedLifetime(window) {} }
        let row = try #require(listView.rowView(for: 1) as? FillRow)

        heights.values[1] = 160
        listView.invalidateLayout(forRowsWith: [1], animated: true)
        advanceOneFrame()

        // Laid out at the new size by the row, on the next pass, unforced.
        #expect(abs(row.fill.frame.height - 160) < 0.5)
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
        let above = try #require(listView.rowView(for: 4))
        let target = entering.placedFrame.minY
        var rose = false
        for _ in 0 ..< 20 {
            advanceOneFrame()
            guard let shown = presentationY(of: entering) else { continue }
            // Never above where it is headed: it comes up from below, on the
            // row above it.
            #expect(shown > target - 1)
            #expect(abs((presentationFrame(of: above)?.maxY ?? -1) - shown) < 2)
            if shown > target + 1 { rose = true }
        }
        #expect(rose)
        settleSlides()
        #expect(abs((presentationY(of: entering) ?? -1) - target) < 0.5)
    }
}
