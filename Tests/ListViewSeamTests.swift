//
//  ListViewSeamTests.swift
//  ListViewKit
//
//  Rows that come in or go out between two rows that stay: an animated apply
//  opens or closes the seam between those two, and the rows in it grow out
//  of the seam or close into it on the spring their neighbours slide on.
//  Faded in place instead, each stood over the rows still sliding past it
//  for the length of the fade.
//
//  Runs on both platforms; the UIKit half needs
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

private struct SeamItem: Identifiable, Hashable {
    let id: Int
}

/// A row that asks not to be clipped, as a chat row whose shadow or tail
/// spills past its box does.
@MainActor
private final class SpillingRow: ListRowView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        #if canImport(UIKit)
            clipsToBounds = false
        #else
            layer?.masksToBounds = false
        #endif
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
struct ListViewSeamTests {
    private static let rowHeight: CGFloat = 100

    private func makeListView(_ ids: [Int] = [0, 1, 2]) -> ListView<SeamItem> {
        let size = CGSize(width: 200, height: 600)
        let frame = CGRect(origin: .zero, size: size)
        let listView = ListView<SeamItem>(frame: frame)
        #if canImport(UIKit)
            let window = UIWindow(frame: frame)
            window.addSubview(listView)
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            CATransaction.flush()
        #else
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView?.addSubview(listView)
        #endif
        listView.rows {
            ListRow(SpillingRow.self)
                .height { _, _ in Self.rowHeight }
                .configure { _, _, _ in }
        }
        listView.apply(ids.map(SeamItem.init))
        layOut(listView)
        return listView
    }

    private func layOut(_ listView: ListView<SeamItem>) {
        #if canImport(UIKit)
            listView.setNeedsLayout()
            listView.layoutIfNeeded()
        #else
            listView.needsLayout = true
            listView.layoutSubtreeIfNeeded()
        #endif
    }

    private func animationKeys(of view: ListRowView) -> [String] {
        #if canImport(UIKit)
            view.layer.animationKeys() ?? []
        #else
            view.layer?.animationKeys() ?? []
        #endif
    }

    private func isClipped(_ view: ListRowView) -> Bool {
        rowClipsToBounds(view)
    }

    private func opacity(of view: ListRowView) -> CGFloat {
        #if canImport(UIKit)
            view.alpha
        #else
            view.alphaValue
        #endif
    }

    /// Whether the row's box is travelling to its size, not only its place.
    private func isUnfolding(_ view: ListRowView) -> Bool {
        animationKeys(of: view).contains { $0.hasPrefix("bounds") || $0.hasPrefix("listRowUnfold") }
    }

    /// Long enough for the list's spring to land on either platform.
    private func waitForTheSpring() {
        RunLoop.main.run(until: Date().addingTimeInterval(listRowSlideDuration + 0.3))
    }

    // MARK: - Where the seams are

    @Test
    func rowsBetweenTwoThatStayOpenTheSeamBetweenThem() {
        let listView = makeListView([0, 1, 2, 3])
        let previousItems = listView.content
        let previousIndexByID = listView.indexByID
        let previousGeometry = listView.rowLayout.geometry

        listView.apply([0, 10, 11, 1, 2, 12, 3].map(SeamItem.init))

        let seams = listView.openingSeams(
            added: [10, 11, 12],
            previousItems: previousItems,
            previousIndexByID: previousIndexByID,
            previousGeometry: previousGeometry
        )
        // Each run starts where the row under it stood.
        #expect(seams == [10: Self.rowHeight, 11: Self.rowHeight, 12: Self.rowHeight * 3])
    }

    @Test
    func rowsAtEitherEndOpenNoSeam() {
        let listView = makeListView([0, 1])
        let previousItems = listView.content
        let previousIndexByID = listView.indexByID
        let previousGeometry = listView.rowLayout.geometry

        listView.apply([10, 0, 1, 11].map(SeamItem.init))

        let seams = listView.openingSeams(
            added: [10, 11],
            previousItems: previousItems,
            previousIndexByID: previousIndexByID,
            previousGeometry: previousGeometry
        )
        #expect(seams.isEmpty)
    }

    /// One row for one row of the same height is a swap: there is no room
    /// to open and none to close, and both fade where they stand.
    @Test
    func aRowThatTakesAnothersPlaceOpensNoSeam() {
        let listView = makeListView([0, 1, 2])
        let previousItems = listView.content
        let previousIndexByID = listView.indexByID
        let previousGeometry = listView.rowLayout.geometry

        listView.apply([0, 10, 2].map(SeamItem.init))

        #expect(listView.openingSeams(
            added: [10],
            previousItems: previousItems,
            previousIndexByID: previousIndexByID,
            previousGeometry: previousGeometry
        ).isEmpty)
        #expect(listView.closingSeams(
            removed: [1],
            previousItems: previousItems,
            previousIndexByID: previousIndexByID,
            previousGeometry: previousGeometry
        ).isEmpty)
    }

    /// A chat's name line is keyed by the first message under it, so a fold
    /// opening above that message brings in another name line with the
    /// messages. The new line takes the old one's place; the messages are
    /// what opens the seam, from where the row under them stood.
    @Test
    func rowsPastWhatStoodThereOpenTheSeamAndTheOthersSwap() {
        let listView = makeListView([0, 1, 2])
        let previousItems = listView.content
        let previousIndexByID = listView.indexByID
        let previousGeometry = listView.rowLayout.geometry

        listView.apply([0, 10, 11, 12, 2].map(SeamItem.init))

        let seams = listView.openingSeams(
            added: [10, 11, 12],
            previousItems: previousItems,
            previousIndexByID: previousIndexByID,
            previousGeometry: previousGeometry
        )
        #expect(seams == [11: Self.rowHeight * 2, 12: Self.rowHeight * 2])
    }

    /// And the way back: the rows that stood past the one coming in close
    /// the seam, and the first swaps with it.
    @Test
    func rowsPastWhatStandsThereCloseTheSeamAndTheOthersSwap() {
        let listView = makeListView([0, 10, 11, 12, 2])
        let previousItems = listView.content
        let previousIndexByID = listView.indexByID
        let previousGeometry = listView.rowLayout.geometry

        listView.apply([0, 1, 2].map(SeamItem.init))

        let seams = listView.closingSeams(
            removed: [10, 11, 12],
            previousItems: previousItems,
            previousIndexByID: previousIndexByID,
            previousGeometry: previousGeometry
        )
        #expect(seams == [11: Self.rowHeight * 2, 12: Self.rowHeight * 2])
    }

    /// Two rows that stay but changed places have no seam between them: a
    /// row that came in there is not riding on either.
    @Test
    func rowsBetweenTwoThatChangedPlacesOpenNoSeam() {
        let listView = makeListView([0, 1, 2])
        let previousItems = listView.content
        let previousIndexByID = listView.indexByID
        let previousGeometry = listView.rowLayout.geometry

        listView.apply([2, 10, 0, 1].map(SeamItem.init))

        #expect(listView.openingSeams(
            added: [10],
            previousItems: previousItems,
            previousIndexByID: previousIndexByID,
            previousGeometry: previousGeometry
        ).isEmpty)
    }

    @Test
    func rowsLeavingFromBetweenTwoThatStayCloseTheSeamBetweenThem() {
        let listView = makeListView([0, 1, 2, 3, 4])
        let previousItems = listView.content
        let previousIndexByID = listView.indexByID
        let previousGeometry = listView.rowLayout.geometry

        listView.apply([0, 3, 4].map(SeamItem.init))

        let seams = listView.closingSeams(
            removed: [1, 2],
            previousItems: previousItems,
            previousIndexByID: previousIndexByID,
            previousGeometry: previousGeometry
        )
        // Where the row that slides up under them lands.
        #expect(seams == [1: Self.rowHeight, 2: Self.rowHeight])
    }

    // MARK: - Coming in

    /// The row's box travels to its size, from nothing at the seam, so it
    /// is never drawn over the row sliding away under it.
    @Test
    func aRowComingInAtASeamGrowsOutOfIt() throws {
        let listView = makeListView([0, 1, 2])

        listView.apply([0, 10, 1, 2].map(SeamItem.init), animated: true)

        let row = try #require(listView.rowView(for: 10))
        #expect(opacity(of: row) == 1)
        #expect(isUnfolding(row))
        #expect(row.placedFrame == listView.rectForRow(at: 1))
    }

    /// Everything the row holds is past its box while the box is opening,
    /// so a row that asked not to be clipped is clipped until it has landed.
    @Test
    func aRowThatSpillsIsClippedOnlyWhileItsBoxOpens() throws {
        let listView = makeListView([0, 1, 2])

        listView.apply([0, 10, 1, 2].map(SeamItem.init), animated: true)

        let row = try #require(listView.rowView(for: 10))
        #expect(isClipped(row))
        waitForTheSpring()
        #expect(!isClipped(row))
        #expect(listView.unfoldingRows.isEmpty)
    }

    /// A row recycled while its box is still opening goes back to the pool
    /// as it asked to be: the next item on it is not clipped for good.
    @Test
    func aRowRecycledMidwayIsNoLongerClipped() throws {
        let listView = makeListView([0, 1, 2])

        listView.apply([0, 10, 1, 2].map(SeamItem.init), animated: true)
        let row = try #require(listView.rowView(for: 10))
        #expect(isClipped(row))

        listView.apply([0, 1, 2].map(SeamItem.init))

        #expect(!isClipped(row))
        #expect(listView.unfoldingRows.isEmpty)
        // The first apply's completion finds nothing left to put back.
        waitForTheSpring()
        #expect(!isClipped(row))
    }

    /// The rows at the end have no row under them to ride on: they fade in
    /// where they stand, as before.
    @Test
    func aRowComingInAtTheEndStillFades() throws {
        let listView = makeListView([0, 1, 2])

        listView.apply([0, 1, 2, 10].map(SeamItem.init), animated: true)

        let row = try #require(listView.rowView(for: 10))
        #expect(!isUnfolding(row))
        #expect(!isClipped(row))
    }

    // MARK: - Going out

    // AppKit only: UIKit's picture comes from `snapshotView(afterScreenUpdates:)`,
    // which has nothing to copy in a test host that never renders a frame.
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        private func snapshots(in listView: ListView<SeamItem>) -> [DisposalSnapshotView] {
            listView.subviews.compactMap { $0 as? DisposalSnapshotView }
        }

        /// The picture's box closes over it as it fades, and it is gone once
        /// the spring has landed.
        @Test
        func aRowLeavingFromASeamClosesIntoIt() throws {
            let listView = makeListView([0, 1, 2])

            listView.apply([0, 2].map(SeamItem.init), animated: true)

            let snapshot = try #require(snapshots(in: listView).first)
            #expect(snapshot.alphaValue == 0)
            let keys = snapshot.layer?.animationKeys() ?? []
            #expect(keys.contains("listRowFoldSize"))
            // It still stands where the row stood, so AppKit draws it.
            #expect(snapshot.frame == CGRect(x: 0, y: Self.rowHeight, width: 200, height: Self.rowHeight))
            // And the picture fills it: one with no size is a blank box.
            #expect(snapshot.subviews.first?.frame.size == CGSize(width: 200, height: Self.rowHeight))

            waitForTheSpring()
            #expect(snapshots(in: listView).isEmpty)
        }

        /// The last row has nothing to slide up under it: its picture fades
        /// where it stands, as before.
        @Test
        func aRowLeavingFromTheEndStillFades() throws {
            let listView = makeListView([0, 1, 2])

            listView.apply([0, 1].map(SeamItem.init), animated: true)

            let snapshot = try #require(snapshots(in: listView).first)
            #expect(snapshot.alphaValue == 0)
            let keys = snapshot.layer?.animationKeys() ?? []
            #expect(!keys.contains("listRowFoldSize"))
        }
    #endif
}
