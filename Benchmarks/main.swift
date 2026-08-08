#if canImport(AppKit)
import AppKit
import Foundation
import ListViewKit

private struct BenchmarkItem: Identifiable, Hashable {
    let id: Int
    var revision = 0
}

@MainActor
private final class BenchmarkAdapter: ListViewAdapter {
    enum RowKind: Hashable {
        case row
    }

    var heightOverrides: [Int: CGFloat] = [:]

    func listView(_: ListView, rowKindFor _: ItemType, at _: Int) -> ListViewAdapter.RowKind {
        RowKind.row
    }

    func listViewMakeRow(for _: ListViewAdapter.RowKind) -> ListRowView {
        ListRowView()
    }

    func listView(_: ListView, heightFor item: ItemType, at _: Int) -> CGFloat {
        let item = item as! BenchmarkItem
        return heightOverrides[item.id, default: 44]
    }

    func listView(_: ListView, configureRowView _: ListRowView, for _: ItemType, at _: Int) {}
}

@main
@MainActor
private struct ListViewKitBenchmarks {
    private struct Context {
        let listView: ListView
        let dataSource: ListViewDiffableDataSource<BenchmarkItem>
        let adapter: BenchmarkAdapter
    }

    private static let itemCounts = [1_000, 10_000, 100_000]
    private static let sampleCount = 3
    private static let visibleQueryCount = 20_000
    private static let offsetWriteCount = 20_000
    private static let scrollLayoutCount = 1_000
    private static let tailHeightUpdateCount = 1_000
    private static let appendCount = 200
    private static let widthReflowCount = 20

    static func main() {
        let warmupContext = makeContext(itemCount: 100)
        _ = runVisibleQueries(in: warmupContext.listView, count: 100)
        _ = runOffsetWrites(in: warmupContext.listView, count: 100)
        _ = runScrollLayouts(in: warmupContext.listView, count: 10)

        print("ListViewKit runtime benchmark")
        print("Release configuration; fixed 44pt rows; 800×600 viewport")
        print("")
        print(
            "| Items | Initial layout | 20k visible queries | Per query "
                + "| 20k offset writes | 1k scroll layouts | 1k tail item updates "
                + "| 200 snapshot appends | 20 width reflows |"
        )
        print("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")

        for itemCount in itemCounts {
            var context: Context?
            var initialSamples: [Double] = []
            for _ in 0 ..< sampleCount {
                let (candidate, milliseconds) = measure {
                    makeContext(itemCount: itemCount)
                }
                context = candidate
                initialSamples.append(milliseconds)
            }
            guard let context else { continue }

            let visibleSamples = (0 ..< sampleCount).map { _ in
                measure {
                    runVisibleQueries(in: context.listView, count: visibleQueryCount)
                }.1
            }
            let offsetSamples = (0 ..< sampleCount).map { _ in
                measure {
                    runOffsetWrites(in: context.listView, count: offsetWriteCount)
                }.1
            }
            let layoutSamples = (0 ..< sampleCount).map { _ in
                measure {
                    runScrollLayouts(in: context.listView, count: scrollLayoutCount)
                }.1
            }
            let heightUpdateSamples = (0 ..< sampleCount).map { _ in
                measure {
                    runTailHeightUpdates(in: context, count: tailHeightUpdateCount)
                }.1
            }
            let appendSamples = (0 ..< sampleCount).map { _ in
                let appendContext = makeContext(itemCount: itemCount)
                return measure {
                    runSnapshotAppends(in: appendContext, count: appendCount)
                }.1
            }
            let widthReflowSamples = (0 ..< sampleCount).map { _ in
                measure {
                    runWidthReflows(in: context.listView, count: widthReflowCount)
                }.1
            }
            let initialMilliseconds = median(initialSamples)
            let visibleMilliseconds = median(visibleSamples)
            let offsetMilliseconds = median(offsetSamples)
            let layoutMilliseconds = median(layoutSamples)
            let heightUpdateMilliseconds = median(heightUpdateSamples)
            let appendMilliseconds = median(appendSamples)
            let widthReflowMilliseconds = median(widthReflowSamples)
            let microsecondsPerQuery = visibleMilliseconds * 1_000 / Double(visibleQueryCount)

            print(
                "| \(itemCount) | \(format(initialMilliseconds)) ms "
                    + "| \(format(visibleMilliseconds)) ms "
                    + "| \(format(microsecondsPerQuery)) µs "
                    + "| \(format(offsetMilliseconds)) ms "
                    + "| \(format(layoutMilliseconds)) ms "
                    + "| \(format(heightUpdateMilliseconds)) ms "
                    + "| \(format(appendMilliseconds)) ms "
                    + "| \(format(widthReflowMilliseconds)) ms |"
            )
            withExtendedLifetime(context) {}
        }
    }

    private static func makeContext(itemCount: Int) -> Context {
        let listView = ListView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let adapter = BenchmarkAdapter()
        let dataSource = ListViewDiffableDataSource<BenchmarkItem>(listView: listView)
        listView.adapter = adapter

        dataSource.applySnapshot(
            using: (0 ..< itemCount).map { BenchmarkItem(id: $0) },
            animatingDifferences: false
        )
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        return Context(listView: listView, dataSource: dataSource, adapter: adapter)
    }

    /// Visible-range resolution alone: the content offset is written once, then
    /// the query runs repeatedly against the same viewport.
    private static func runVisibleQueries(in listView: ListView, count: Int) -> Int {
        listView.contentOffset.y = listView.maximumContentOffset.y / 2
        var resultCount = 0
        for _ in 0 ..< count {
            resultCount &+= listView.indicesForVisibleRows.count
        }
        return resultCount
    }

    /// Content-offset writes alone: what a scroll gesture costs before any row
    /// work happens.
    private static func runOffsetWrites(in listView: ListView, count: Int) -> CGFloat {
        let maximumOffset = listView.maximumContentOffset.y
        var checksum: CGFloat = 0
        for iteration in 0 ..< count {
            let progress = CGFloat(iteration % 997) / 996
            listView.contentOffset.y = maximumOffset * progress
            checksum += listView.contentOffset.y
        }
        return checksum
    }

    private static func runScrollLayouts(in listView: ListView, count: Int) -> Int {
        let maximumOffset = listView.maximumContentOffset.y
        var visibleRowCount = 0
        for iteration in 0 ..< count {
            let progress = CGFloat(iteration) / CGFloat(max(1, count - 1))
            listView.contentOffset.y = maximumOffset * progress
            listView.layoutSubtreeIfNeeded()
            visibleRowCount &+= listView.visibleRowViews.count
        }
        return visibleRowCount
    }

    private static func runTailHeightUpdates(in context: Context, count: Int) -> CGFloat {
        let itemID = max(0, context.dataSource.snapshot().count - 1)
        context.listView.setContentOffset(context.listView.minimumContentOffset, animated: false)
        var checksum: CGFloat = 0
        for iteration in 0 ..< count {
            context.adapter.heightOverrides[itemID] = 44 + CGFloat(iteration % 120)
            _ = context.dataSource.updateItem(BenchmarkItem(
                id: itemID,
                revision: iteration + 1
            ))
            context.listView.layoutSubtreeIfNeeded()
            checksum += context.listView.contentSize.height
        }
        return checksum
    }

    /// Appending one row through a full snapshot diff, the path a chat client
    /// takes for every new message.
    private static func runSnapshotAppends(in context: Context, count: Int) -> Int {
        var nextID = context.dataSource.snapshot().count
        for _ in 0 ..< count {
            var snapshot = context.dataSource.snapshot()
            snapshot.append(BenchmarkItem(id: nextID))
            nextID += 1
            context.dataSource.applySnapshot(snapshot, animatingDifferences: false)
        }
        return nextID
    }

    /// Alternating content-width changes, each of which invalidates every
    /// cached height and forces a full synchronous re-measure.
    private static func runWidthReflows(in listView: ListView, count: Int) -> CGFloat {
        var checksum: CGFloat = 0
        for iteration in 0 ..< count {
            listView.frame.size.width = iteration.isMultiple(of: 2) ? 640 : 800
            listView.needsLayout = true
            listView.layoutSubtreeIfNeeded()
            checksum += listView.contentSize.height
        }
        listView.frame.size.width = 800
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        return checksum
    }

    private static func measure<Result>(_ operation: () -> Result) -> (Result, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = operation()
        let end = DispatchTime.now().uptimeNanoseconds
        return (result, Double(end - start) / 1_000_000)
    }

    private static func median(_ samples: [Double]) -> Double {
        let sortedSamples = samples.sorted()
        return sortedSamples[sortedSamples.count / 2]
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
#else
#error("ListViewKitBenchmarks currently requires AppKit")
#endif
