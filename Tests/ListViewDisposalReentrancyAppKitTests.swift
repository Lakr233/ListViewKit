//
//  ListViewDisposalReentrancyAppKitTests.swift
//  ListViewKit
//
//  An animated apply snapshots each removed row for its fade, and on AppKit
//  taking that snapshot calls `display()`, which runs any layout the window
//  still owes — the list's own included. That pass must not see a half-applied
//  update: a removed row it could still find in the old items would be mounted
//  again on the very view the apply just recycled, and the apply would then
//  take that view out of the hierarchy while the list still counted it as
//  visible. Found in AirBuild: a sent message's local id replaced by the
//  server's left the local row parked in its slot for good, until the next
//  row placed there tripped the overlap assertion.
//

#if canImport(UIKit)
// UIKit's disposal snapshot does not draw, so it cannot re-enter layout.
#elseif canImport(AppKit)
    import AppKit
    import Testing
    @testable import ListViewKit

    private struct DisposalItem: Identifiable, Hashable {
        let id: Int
    }

    @Suite(.serialized)
    @MainActor
    struct ListViewDisposalReentrancyAppKitTests {
        private static let rowHeight: CGFloat = 40

        private func makeListView(count: Int) -> (ListView<DisposalItem>, NSWindow) {
            let size = CGSize(width: 200, height: 400)
            let window = NSWindow(
                contentRect: CGRect(origin: .zero, size: size),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            let listView = ListView<DisposalItem>(frame: CGRect(origin: .zero, size: size))
            // Held by constraints, as a list inside a SwiftUI host is: a
            // constraint-based window is one whose drawing lays out first.
            let container = NSView(frame: CGRect(origin: .zero, size: size))
            window.contentView = container
            listView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(listView)
            NSLayoutConstraint.activate([
                listView.topAnchor.constraint(equalTo: container.topAnchor),
                listView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                listView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                listView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            // `display()` only draws — and so only lays out — a window that
            // is on screen.
            window.orderFrontRegardless()
            listView.rows {
                ListRow(ListRowView.self).height { _, _ in Self.rowHeight }
            }
            listView.apply((0 ..< count).map { DisposalItem(id: $0) })
            listView.layoutSubtreeIfNeeded()
            return (listView, window)
        }

        /// One id replaced by another in the same slot — the send-confirmation
        /// shape — must leave exactly one row there, and every row the list
        /// counts as visible in the hierarchy.
        @Test
        func aReplacedIdLeavesOneRowInItsSlot() {
            let (listView, window) = makeListView(count: 5)
            defer { window.close() }

            // Whatever the window owes when the apply begins is what the
            // disposal snapshot's `display()` runs.
            listView.needsLayout = true
            listView.apply(
                listView.content.map { $0.id == 4 ? DisposalItem(id: 99) : $0 },
                animated: true
            )
            listView.layoutSubtreeIfNeeded()

            #expect(listView.rowView(for: 4) == nil)
            #expect(listView.visibleRowViews.count == listView.content.count)
            for view in listView.visibleRowViews {
                #expect(view.superview === listView)
            }
            let frames = listView.visibleRowViews.map(\.placedFrame).sorted { $0.minY < $1.minY }
            for (upper, lower) in zip(frames, frames.dropFirst()) {
                #expect(lower.minY >= upper.maxY)
            }
        }

        /// The fading copy of a removed row is only a picture: a click in its
        /// slot reaches the row that has moved in underneath it.
        @Test
        func theDisposalSnapshotLetsClicksThrough() throws {
            let (listView, window) = makeListView(count: 5)
            defer { window.close() }

            listView.apply(listView.content.filter { $0.id != 1 }, animated: true)
            listView.layoutSubtreeIfNeeded()

            let successor = try #require(listView.rowView(for: 2))
            let slot = CGPoint(x: successor.placedFrame.midX, y: successor.placedFrame.midY)
            let point = listView.convert(slot, to: listView.superview)
            let hit = try #require(listView.hitTest(point))
            #expect(hit === successor || hit.isDescendant(of: successor))
        }
    }
#endif
