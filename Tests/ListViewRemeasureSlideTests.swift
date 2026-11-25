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
    private func makeListView(heights: Heights, count: Int = 8) -> (ListView<RemeasureItem>, AnyObject) {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        let listView = ListView<RemeasureItem>(frame: frame)
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
        #if canImport(UIKit)
            view.layer.presentation()?.frame.origin.y
        #else
            view.layer?.presentation()?.frame.origin.y
        #endif
    }

    private func advanceOneFrame() {
        RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
    }

    /// Row 1 grows by 60 pt: rows 2 and on are placed 60 pt lower at once,
    /// and shown sliding there from where they stood; row 0, above it, does
    /// not move.
    @Test
    func rowsUnderARowMeasuredTallerSlideDown() throws {
        let heights = Heights()
        let (listView, window) = makeListView(heights: heights)
        defer { withExtendedLifetime(window) {} }
        let row0 = try #require(listView.rowView(for: 0))
        let row2 = try #require(listView.rowView(for: 2))
        let before0 = row0.placedFrame.minY
        let before2 = row2.placedFrame.minY

        heights.values[1] = 160
        listView.invalidateLayout(forRowsWith: [1], animated: true)

        #expect(abs(row2.placedFrame.minY - (before2 + 60)) < 0.5)
        #expect(abs(row0.placedFrame.minY - before0) < 0.5)
        advanceOneFrame()
        let shown = try #require(presentationY(of: row2))
        // Still on its way: not yet at its new place, not back before its old.
        #expect(shown < before2 + 60 - 1)
        #expect(shown > before2 - 1)
        #expect(abs((presentationY(of: row0) ?? -1) - before0) < 0.5)
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
        advanceOneFrame()
        #expect(abs((presentationY(of: row2) ?? -1) - (before2 + 60)) < 0.5)
    }

    /// A row above the list's anchor — cut by the top edge — growing goes into
    /// the offset: the rows on screen under it keep their place there, and
    /// nothing slides.
    @Test
    func aRowGrowingAboveTheAnchorMovesNothingOnScreen() throws {
        let heights = Heights()
        let (listView, window) = makeListView(heights: heights, count: 20)
        defer { withExtendedLifetime(window) {} }
        listView.setContentOffset(CGPoint(x: 0, y: 250), animated: false)
        settleLayout(listView)
        let row4 = try #require(listView.rowView(for: 4))
        let onScreen = row4.placedFrame.minY - listView.contentOffset.y

        // Row 2 spans 200...300, cut by the top edge at 250.
        heights.values[2] = 160
        listView.invalidateLayout(forRowsWith: [2], animated: true)

        #expect(abs(row4.placedFrame.minY - listView.contentOffset.y - onScreen) < 0.5)
        advanceOneFrame()
        let shown = try #require(presentationY(of: row4))
        #expect(abs(shown - row4.placedFrame.minY) < 0.5)
    }
}
