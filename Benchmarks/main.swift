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

@MainActor
private struct Context {
    let listView: ListView
    let dataSource: ListViewDiffableDataSource<BenchmarkItem>
    let adapter: BenchmarkAdapter

    init(itemCount: Int) {
        listView = ListView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        adapter = BenchmarkAdapter()
        dataSource = ListViewDiffableDataSource<BenchmarkItem>(listView: listView)
        listView.adapter = adapter

        dataSource.applySnapshot(
            using: (0 ..< itemCount).map { BenchmarkItem(id: $0) },
            animatingDifferences: false
        )
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
    }
}

/// One timed path. Every sample runs against a freshly built `Context`, so no
/// benchmark can be contaminated by a previous one's mutations.
@MainActor
private struct Benchmark {
    let key: String
    let label: String
    let iterations: Int
    let body: (Context, Int) -> Void
}

@main
@MainActor
private enum ListViewKitBenchmarks {
    private static let sampleCount = 3

    private static let benchmarks: [Benchmark] = [
        // Visible-range resolution alone. The offset is written once so the
        // number reflects the binary search and nothing else.
        Benchmark(key: "query", label: "20k visible queries", iterations: 20_000) { context, count in
            let listView = context.listView
            listView.contentOffset.y = listView.maximumContentOffset.y / 2
            for _ in 0 ..< count {
                blackHole(listView.indicesForVisibleRows.count)
            }
        },
        // Content-offset writes alone: what a scroll gesture costs before the
        // list does any row work.
        Benchmark(key: "offset", label: "20k offset writes", iterations: 20_000) { context, count in
            let listView = context.listView
            let maximumOffset = listView.maximumContentOffset.y
            for iteration in 0 ..< count {
                listView.contentOffset.y = maximumOffset * CGFloat(iteration % 997) / 996
            }
        },
        Benchmark(key: "layout", label: "1k scroll layouts", iterations: 1_000) { context, count in
            let listView = context.listView
            let maximumOffset = listView.maximumContentOffset.y
            for iteration in 0 ..< count {
                listView.contentOffset.y = maximumOffset * CGFloat(iteration) / CGFloat(max(1, count - 1))
                listView.layoutSubtreeIfNeeded()
            }
        },
        // A growing streaming response: one item changes height repeatedly
        // without diffing a snapshot.
        Benchmark(key: "update", label: "1k tail item updates", iterations: 1_000) { context, count in
            let itemID = max(0, context.dataSource.snapshot().count - 1)
            context.listView.setContentOffset(context.listView.minimumContentOffset, animated: false)
            for iteration in 0 ..< count {
                context.adapter.heightOverrides[itemID] = 44 + CGFloat(iteration % 120)
                context.dataSource.updateItem(BenchmarkItem(id: itemID, revision: iteration + 1))
                context.listView.layoutSubtreeIfNeeded()
            }
        },
        // Appending through a complete snapshot diff, the path a chat client
        // takes for every new message.
        Benchmark(key: "append", label: "200 snapshot appends", iterations: 200) { context, count in
            var nextID = context.dataSource.snapshot().count
            for _ in 0 ..< count {
                var snapshot = context.dataSource.snapshot()
                snapshot.append(BenchmarkItem(id: nextID))
                nextID += 1
                context.dataSource.applySnapshot(snapshot, animatingDifferences: false)
            }
        },
        // Alternating widths, each invalidating every cached height.
        Benchmark(key: "reflow", label: "20 width reflows", iterations: 20) { context, count in
            let listView = context.listView
            for iteration in 0 ..< count {
                listView.frame.size.width = iteration.isMultiple(of: 2) ? 640 : 800
                listView.needsLayout = true
                listView.layoutSubtreeIfNeeded()
            }
        },
    ]

    static func main() {
        let itemCounts = environmentList("LVK_ITEMS").map { $0.compactMap(Int.init) } ?? [1_000, 10_000, 100_000]
        let selectedKeys = environmentList("LVK_BENCH").map(Set.init)
        let selected = benchmarks.filter { selectedKeys?.contains($0.key) ?? true }

        warmUp()

        print("ListViewKit runtime benchmark")
        print("Release configuration; fixed 44pt rows; 800×600 viewport")
        print("")
        print("| Items | Initial layout | " + selected.map(\.label).joined(separator: " | ") + " |")
        print(String(repeating: "| ---: ", count: selected.count + 2) + "|")

        for itemCount in itemCounts {
            var setupSamples: [Double] = []
            var columns: [String] = []
            for benchmark in selected {
                var samples: [Double] = []
                for _ in 0 ..< sampleCount {
                    let (context, setupMilliseconds) = measure { Context(itemCount: itemCount) }
                    setupSamples.append(setupMilliseconds)
                    samples.append(measure { benchmark.body(context, benchmark.iterations) }.1)
                    withExtendedLifetime(context) {}
                }
                columns.append(format(median(samples)))
            }
            print("| \(itemCount) | \(format(median(setupSamples))) ms | " + columns.joined(separator: " ms | ") + " ms |")
        }
    }

    private static func warmUp() {
        let context = Context(itemCount: 100)
        for benchmark in benchmarks {
            benchmark.body(context, min(benchmark.iterations, 20))
        }
    }

    private static func environmentList(_ name: String) -> [String]? {
        ProcessInfo.processInfo.environment[name]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
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

/// Keeps a measured result from being optimized away without the cost of a
/// running checksum in the timed loop.
@inline(never)
private func blackHole(_ value: some Any) {
    withExtendedLifetime(value) {}
}
#else
#error("ListViewKitBenchmarks currently requires AppKit")
#endif
