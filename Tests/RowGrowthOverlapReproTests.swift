#if canImport(AppKit)

    import AppKit
    @testable import ListViewKit
    import Testing

    private struct ReproItem: Identifiable, Hashable {
        var id: Int
        var revision: Int = 0
    }

    private final class ReproProbe {
        var heights: [Int: CGFloat] = [:]

        func height(of item: ReproItem) -> CGFloat {
            heights[item.id, default: 100]
        }
    }

    @MainActor
    private final class ReproRow: ListRowView {}

    /// Mirrors AirBuild's transcript scenario: a mounted image row learns its
    /// real (taller) size after load and the app calls
    /// `invalidateLayout(forRowWith:)`. The mounted views' *actual* frames must
    /// then agree with the layout and not overlap each other.
    @MainActor
    @Suite("Row growth overlap repro", .serialized)
    struct RowGrowthOverlapReproTests {
        private func makeListView(
            probe: ReproProbe,
            count: Int = 20,
            size: CGSize = CGSize(width: 200, height: 400)
        ) -> ListView<ReproItem> {
            let listView = ListView<ReproItem>(frame: CGRect(origin: .zero, size: size))
            listView.rows {
                ListRow(ReproRow.self)
                    .height { item, _ in probe.height(of: item) }
                    .configure { _, _, _ in }
            }
            listView.apply((0 ..< count).map { ReproItem(id: $0) })
            drain(listView)
            return listView
        }

        private func drain(_ listView: ListView<ReproItem>) {
            listView.needsLayout = true
            listView.layoutSubtreeIfNeeded()
            for _ in 0 ..< 200 where listView.rowLayout.hasPendingRows {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            listView.needsLayout = true
            listView.layoutSubtreeIfNeeded()
        }

        /// Actual view frames, not placedFrame and not rectForRow: what the
        /// reader sees.
        private func actualFrames(in listView: ListView<ReproItem>) -> [(id: Int, frame: CGRect)] {
            listView.visibleRows
                .map { (id: $0.key, frame: $0.value.view.frame) }
                .sorted { $0.frame.minY < $1.frame.minY }
        }

        private func expectNoOverlap(_ frames: [(id: Int, frame: CGRect)]) {
            for (above, below) in zip(frames, frames.dropFirst()) {
                #expect(
                    below.frame.minY >= above.frame.maxY - 0.5,
                    "row \(below.id) at \(below.frame) overlaps row \(above.id) at \(above.frame)"
                )
            }
        }

        private func expectViewsMatchLayout(_ listView: ListView<ReproItem>) {
            for (item, entry) in listView.visibleRows {
                let expected = listView.rectForRow(with: item)
                #expect(
                    entry.view.frame == expected,
                    "row \(item): actual frame \(entry.view.frame) != layout \(expected)"
                )
            }
        }

        @Test
        func growingAMountedRowKeepsActualFramesConsistent() {
            let probe = ReproProbe()
            let listView = makeListView(probe: probe)

            // Pinned to the bottom, like the transcript.
            listView.contentOffset.y = listView.contentSize.height - listView.bounds.height
            drain(listView)

            // A visible row learns its real size (placeholder 100 -> 280).
            let grown = listView.indicesForVisibleRows[1]
            probe.heights[grown] = 280
            listView.invalidateLayout(forRowWith: grown)
            drain(listView)

            expectViewsMatchLayout(listView)
            expectNoOverlap(actualFrames(in: listView))
        }

        @Test
        func growingARowAboveTheViewportKeepsActualFramesConsistent() {
            let probe = ReproProbe()
            let listView = makeListView(probe: probe)

            listView.contentOffset.y = 300
            drain(listView)

            // The grown row sits partially above the viewport top, so the
            // offset compensates while the mounted rows re-place.
            let grown = listView.indicesForVisibleRows[0]
            probe.heights[grown] = 280
            listView.invalidateLayout(forRowWith: grown)
            drain(listView)

            expectViewsMatchLayout(listView)
            expectNoOverlap(actualFrames(in: listView))
        }

        /// The real transcript grows the image row while new messages stream
        /// in as animated applies — the invalidate and the applies interleave
        /// on the same runloop turn, as `remeasureRow`'s deferred dispatch
        /// does in AirBuild.
        @Test
        func growingARowDuringAnimatedStreamingKeepsActualFramesConsistent() {
            let probe = ReproProbe()
            let listView = makeListView(probe: probe, count: 10)

            listView.contentOffset.y = max(0, listView.contentSize.height - listView.bounds.height)
            listView.needsLayout = true
            listView.layoutSubtreeIfNeeded()

            // A visible row learns its real size while two more messages
            // stream in animated, before any layout pass runs between them.
            let grown = listView.indicesForVisibleRows[1]
            probe.heights[grown] = 280
            listView.apply((0 ..< 11).map { ReproItem(id: $0) }, animated: true)
            listView.invalidateLayout(forRowWith: grown)
            listView.apply((0 ..< 12).map { ReproItem(id: $0) }, animated: true)
            drain(listView)
            listView.contentOffset.y = max(0, listView.contentSize.height - listView.bounds.height)
            drain(listView)

            expectViewsMatchLayout(listView)
            expectNoOverlap(actualFrames(in: listView))
        }

        /// Same interleave, but the item of the grown row is also replaced in
        /// the applied snapshot (a reconfigure), as a transcript entry whose
        /// attachment metadata updated would be.
        @Test
        func growingAReconfiguredRowDuringStreamingKeepsActualFramesConsistent() {
            let probe = ReproProbe()
            let listView = makeListView(probe: probe, count: 10)

            listView.contentOffset.y = max(0, listView.contentSize.height - listView.bounds.height)
            listView.needsLayout = true
            listView.layoutSubtreeIfNeeded()

            let grown = listView.indicesForVisibleRows[1]
            probe.heights[grown] = 280
            var items = (0 ..< 11).map { ReproItem(id: $0) }
            items[grown].revision = 1
            listView.apply(items, animated: true)
            listView.invalidateLayout(forRowWith: grown)
            drain(listView)

            expectViewsMatchLayout(listView)
            expectNoOverlap(actualFrames(in: listView))
        }

        @Test
        func growingARowTwiceKeepsActualFramesConsistent() {
            let probe = ReproProbe()
            let listView = makeListView(probe: probe)

            listView.contentOffset.y = listView.contentSize.height - listView.bounds.height
            drain(listView)

            let grown = listView.indicesForVisibleRows[1]
            probe.heights[grown] = 180
            listView.invalidateLayout(forRowWith: grown)
            drain(listView)
            probe.heights[grown] = 280
            listView.invalidateLayout(forRowWith: grown)
            drain(listView)

            expectViewsMatchLayout(listView)
            expectNoOverlap(actualFrames(in: listView))
        }
    }

#endif
