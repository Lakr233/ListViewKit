#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Foundation
import ListViewKit

private struct BenchmarkItem: Identifiable, Hashable {
    let id: Int
    var revision = 0
}

@MainActor
private struct Context {
    let listView: ListView<BenchmarkItem>
    /// Overrides let a benchmark change one row's height without touching the
    /// registration.
    static var heightOverrides: [Int: CGFloat] = [:]

    init(itemCount: Int) {
        listView = ListView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        listView.rows {
            ListRow(ListRowView.self)
                .height { item, _ in Context.heightOverrides[item.id, default: 44] }
                .configure { _, _, _ in }
        }
        listView.apply((0 ..< itemCount).map { BenchmarkItem(id: $0) })
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
            let itemID = max(0, context.listView.content.count - 1)
            context.listView.setContentOffset(context.listView.minimumContentOffset, animated: false)
            for iteration in 0 ..< count {
                Context.heightOverrides[itemID] = 44 + CGFloat(iteration % 120)
                context.listView.update(BenchmarkItem(id: itemID, revision: iteration + 1))
                context.listView.layoutSubtreeIfNeeded()
            }
        },
        // One new message at a time, the path a chat client takes.
        Benchmark(key: "append", label: "200 appends", iterations: 200) { context, count in
            let listView = context.listView
            for _ in 0 ..< count {
                listView.append(BenchmarkItem(id: listView.content.count))
            }
        },
        // The same growth expressed as a whole-array replacement, which has to
        // diff everything to discover the one new row.
        Benchmark(key: "reapply", label: "200 whole-array applies", iterations: 200) { context, count in
            var items = context.listView.content
            for _ in 0 ..< count {
                items.append(BenchmarkItem(id: items.count))
                context.listView.apply(items)
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
        var selectedKeys = environmentList("LVK_BENCH").map(Set.init)
        // Not a column: a table of its own, printed after the others.
        let reportsFrames = selectedKeys?.remove(framesKey) != nil || selectedKeys == nil
        if reportsFrames, selectedKeys?.isEmpty == true {
            reportFrames()
            return
        }
        let selected = benchmarks.filter { selectedKeys?.contains($0.key) ?? true }
        let unknownKeys = (selectedKeys ?? []).subtracting(benchmarks.map(\.key))
        guard unknownKeys.isEmpty, !selected.isEmpty else {
            let known = (benchmarks.map(\.key) + [framesKey]).joined(separator: ", ")
            let unknown = unknownKeys.sorted().joined(separator: ", ")
            FileHandle.standardError.write(Data("Unknown LVK_BENCH key: \(unknown). Known keys: \(known).\n".utf8))
            exit(1)
        }

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
        if reportsFrames {
            reportFrames()
        }
    }

    // MARK: - Frames

    private static let framesKey = "frames"

    /// What a scroll onto rows that are expensive to measure and to build
    /// costs frame by frame, with and without a preparation range.
    ///
    /// The other columns are totals. This one is about the worst frame: a
    /// row that takes a few milliseconds to measure and a few more to fill
    /// in pays for both in the frame that uncovers it, and two of them
    /// arriving together are a dropped frame however fast the list is.
    private static func reportFrames() {
        print("")
        print("Scrolling onto rows nobody has measured; 3 ms to measure, 4 ms to fill in; 120pt rows, 800×600 viewport")
        print("")
        print("| Scroll | Range | Frames | Mean | Worst | Over 8.3 ms | Rows filled in during layout |")
        print("| ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        for step in [30, 60, 120, 240] as [CGFloat] {
            for range in [ListPreparationRange.none, .viewports(1.5)] {
                let report = frames(step: step, range: range)
                let name = range == .none ? "none" : "1.5 viewports"
                print(
                    "| \(Int(step)) pt/frame | \(name) | \(report.frames.count) "
                        + "| \(format(report.frames.reduce(0, +) / Double(report.frames.count))) ms "
                        + "| \(format(report.frames.max() ?? 0)) ms "
                        + "| \(report.frames.count(where: { $0 > 8.3 })) | \(report.filledInLayout) |"
                )
            }
        }
    }

    private static func frames(step: CGFloat, range: ListPreparationRange) -> (frames: [Double], filledInLayout: Int) {
        var isInLayout = false
        var filledInLayout = 0
        let listView = ListView<BenchmarkItem>(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        listView.estimatedRowHeight = 120
        listView.rows {
            ListRow(ListRowView.self)
                .height { _, _ in
                    spin(milliseconds: 3)
                    return 120
                }
                .configure { _, _, _ in
                    spin(milliseconds: 4)
                    if isInLayout { filledInLayout += 1 }
                }
        }
        listView.preparationRange = range
        listView.apply((0 ..< 400).map { BenchmarkItem(id: $0) })
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        // A hand on the list from the start, as there is through any real
        // scroll: deferred measurement waits for it to lift, so every row is
        // still to be measured and what is compared is the layout pass and
        // the range.
        sendWheel(.began, to: listView)
        defer { sendWheel(.ended, to: listView) }
        // It rests there for a moment before the first swipe.
        let rested = Date().addingTimeInterval(0.5)
        while Date() < rested {
            RunLoop.main.run(mode: .default, before: rested)
        }

        filledInLayout = 0
        var frames: [Double] = []
        var offset: CGFloat = 0
        while offset < 24_000 {
            offset += step
            frames.append(measure {
                // The frame: the offset moves and the list lays out.
                isInLayout = true
                listView.contentOffset.y = offset
                listView.layoutSubtreeIfNeeded()
                isInLayout = false
                // What is left of it: the run loop comes round once.
                RunLoop.main.run(mode: .default, before: Date())
            }.1)
        }
        return (frames, filledInLayout)
    }

    private static func sendWheel(_ phase: CGScrollPhase, to listView: ListView<BenchmarkItem>) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0
        ) else { return }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        guard let wheel = NSEvent(cgEvent: event) else { return }
        listView.scrollWheel(with: wheel)
    }

    private static func spin(milliseconds: Double) {
        let end = DispatchTime.now().uptimeNanoseconds + UInt64(milliseconds * 1_000_000)
        while DispatchTime.now().uptimeNanoseconds < end {}
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
// Xcode builds every package product for the test destination, so this
// target has to compile on UIKit platforms even though it only runs on macOS.
@main
enum Benchmarks {
    static func main() {
        print("ListViewKitBenchmarks requires AppKit; run it on macOS.")
    }
}
#endif
