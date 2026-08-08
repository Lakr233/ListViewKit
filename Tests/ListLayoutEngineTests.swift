import CoreGraphics
import Testing
@testable import ListViewKit

/// The obvious implementation: a plain array summed linearly. Every engine
/// answer is compared against this, so the Fenwick tree never becomes the
/// definition of correct.
private struct NaiveLayout {
    var rows: [ListLayoutEngine.Row] = []

    var totalHeight: CGFloat { rows.reduce(0) { $0 + $1.height } }
    var pendingCount: Int { rows.count { $0.isPending } }

    func offset(at index: Int) -> CGFloat {
        rows[..<index].reduce(0) { $0 + $1.height }
    }

    func index(atOffset y: CGFloat) -> Int? {
        guard !rows.isEmpty else { return nil }
        // The last row whose top edge is at or before `y`, matching a Fenwick
        // descent's tie-breaking through zero-height rows.
        var result = 0
        for index in rows.indices where offset(at: index) <= y {
            result = index
        }
        return result
    }

    /// Deliberately defined by overlap rather than by the engine's descent, so
    /// the two are not the same rule written twice.
    func indices(in yRange: Range<CGFloat>) -> Range<Int> {
        let overlapping = rows.indices.filter { index in
            let top = offset(at: index)
            return top < yRange.upperBound && top + rows[index].height > yRange.lowerBound
        }
        guard let first = overlapping.first, let last = overlapping.last else { return 0 ..< 0 }
        return first ..< last + 1
    }

    func nextPending(near index: Int) -> Int? {
        let pending = rows.indices.filter { rows[$0].isPending }
        guard !pending.isEmpty else { return nil }
        // Prefer the row above on a tie, matching the engine.
        return pending.min { lhs, rhs in
            let left = (abs(index - lhs), lhs > index ? 1 : 0)
            let right = (abs(index - rhs), rhs > index ? 1 : 0)
            return left < right
        }
    }
}

/// Deterministic so a failure reproduces exactly.
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(below bound: Int) -> Int {
        bound <= 0 ? 0 : Int(next() % UInt64(bound))
    }

    /// Fractional on purpose: the engine normalizes heights to whole points,
    /// and that normalization is what keeps a descent and a prefix walk in
    /// agreement.
    mutating func height() -> CGFloat {
        CGFloat(int(below: 4_000)) / 10
    }
}

@Suite
struct ListLayoutEngineTests {
    private func expectMatches(
        _ engine: ListLayoutEngine,
        _ naive: NaiveLayout,
        _ random: inout SplitMix64,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(engine.count == naive.rows.count, sourceLocation: sourceLocation)
        #expect(engine.totalHeight == naive.totalHeight, sourceLocation: sourceLocation)
        #expect(engine.pendingCount == naive.pendingCount, sourceLocation: sourceLocation)
        guard !naive.rows.isEmpty else { return }

        for _ in 0 ..< 4 {
            let index = random.int(below: naive.rows.count)
            #expect(engine.offset(at: index) == naive.offset(at: index), sourceLocation: sourceLocation)
            #expect(engine.height(at: index) == naive.rows[index].height, sourceLocation: sourceLocation)
            #expect(engine.isPending(at: index) == naive.rows[index].isPending, sourceLocation: sourceLocation)
            #expect(engine.nextPending(near: index) == naive.nextPending(near: index), sourceLocation: sourceLocation)

            let span = max(naive.totalHeight, 1)
            let start = CGFloat(random.int(below: Int(span) + 1))
            let length = CGFloat(random.int(below: 900))
            #expect(engine.index(atOffset: start) == naive.index(atOffset: start), sourceLocation: sourceLocation)
            #expect(
                engine.indices(in: start ..< start + length) == naive.indices(in: start ..< start + length),
                sourceLocation: sourceLocation
            )
        }
    }

    /// Appends, measurements and invalidations interleaved at random, compared
    /// against the naive model after every single operation.
    @Test
    func matchesTheNaiveModelUnderRandomOperations() {
        var random = SplitMix64(state: 0x5EED)
        var engine = ListLayoutEngine()
        var naive = NaiveLayout()

        for step in 0 ..< 4_000 {
            switch random.int(below: 10) {
            case 0 ..< 5:
                let row = ListLayoutEngine.Row(
                    height: random.height(),
                    isPending: random.int(below: 2) == 0
                )
                engine.append(row)
                naive.rows.append(row)
            case 5 ..< 8 where !naive.rows.isEmpty:
                let index = random.int(below: naive.rows.count)
                let height = random.height()
                engine.setHeight(height, at: index)
                naive.rows[index] = .init(height: height, isPending: false)
            case 8 where !naive.rows.isEmpty:
                let index = random.int(below: naive.rows.count)
                engine.invalidate(at: index)
                naive.rows[index].isPending = true
            case 9:
                let newRows = (0 ..< random.int(below: 40)).map { _ in
                    ListLayoutEngine.Row(
                        height: random.height(),
                        isPending: random.int(below: 2) == 0
                    )
                }
                engine.reset(newRows)
                naive.rows = newRows
            default:
                continue
            }
            if step % 7 == 0 {
                expectMatches(engine, naive, &random)
            }
        }
        expectMatches(engine, naive, &random)
    }

    /// Zero-height rows share a prefix sum with their neighbours, which is
    /// exactly where a descent's tie-breaking can disagree with a linear scan.
    @Test
    func agreesWithTheNaiveModelAroundZeroHeightRows() {
        var random = SplitMix64(state: 0xC0FFEE)
        var engine = ListLayoutEngine()
        var naive = NaiveLayout()

        for _ in 0 ..< 200 {
            let row = ListLayoutEngine.Row(
                height: random.int(below: 3) == 0 ? 0 : random.height(),
                isPending: random.int(below: 2) == 0
            )
            engine.append(row)
            naive.rows.append(row)
        }
        for _ in 0 ..< 400 {
            expectMatches(engine, naive, &random)
        }
    }

    /// A descent has to land on exactly the row a prefix walk says starts
    /// there, for every row. This is the invariant whole-point heights buy.
    @Test
    func hitTestingRoundTripsThroughEveryRowTop() {
        var random = SplitMix64(state: 0xA11CE)
        var engine = ListLayoutEngine()
        for _ in 0 ..< 3_000 {
            engine.append(.init(height: random.height(), isPending: false))
        }
        for index in 0 ..< engine.count where engine.height(at: index) > 0 {
            #expect(engine.index(atOffset: engine.offset(at: index)) == index)
        }
    }

    @Test
    func rangesOutsideTheContentAreEmpty() {
        var engine = ListLayoutEngine()
        for _ in 0 ..< 3 {
            engine.append(.init(height: 10, isPending: false))
        }
        #expect(engine.indices(in: 100 ..< 110).isEmpty)
        #expect(engine.indices(in: 30 ..< 40).isEmpty)
        #expect(engine.indices(in: -50 ..< -10).isEmpty)
        #expect(engine.indices(in: 29 ..< 40) == 2 ..< 3)
        #expect(engine.indices(in: -10 ..< 1) == 0 ..< 1)
    }

    @Test
    func emptyLayoutAnswersWithoutRows() {
        let engine = ListLayoutEngine()
        #expect(engine.count == 0)
        #expect(engine.totalHeight == 0)
        #expect(!engine.hasPendingRows)
        #expect(engine.index(atOffset: 0) == nil)
        #expect(engine.index(atOffset: 100) == nil)
        #expect(engine.indices(in: 0 ..< 100).isEmpty)
        #expect(engine.nextPending(near: 0) == nil)
    }

    @Test
    func offsetsAreExactAtBothEnds() {
        var engine = ListLayoutEngine()
        for _ in 0 ..< 100 {
            engine.append(.init(height: 10, isPending: false))
        }
        #expect(engine.offset(at: 0) == 0)
        #expect(engine.offset(at: 100) == 1_000)
        #expect(engine.totalHeight == 1_000)
        #expect(engine.index(atOffset: -5) == 0)
        #expect(engine.index(atOffset: 0) == 0)
        #expect(engine.index(atOffset: 9.9) == 0)
        #expect(engine.index(atOffset: 10) == 1)
        #expect(engine.index(atOffset: 100_000) == 99)
        #expect(engine.indices(in: 0 ..< 25) == 0 ..< 3)
        #expect(engine.indices(in: 10 ..< 20) == 1 ..< 2)
    }

    /// Draining walks outward from the viewport, so the tie-break and the
    /// ordering matter more than raw distance.
    @Test
    func nextPendingWalksOutwardFromTheViewport() {
        var engine = ListLayoutEngine()
        for index in 0 ..< 12 {
            engine.append(.init(height: 10, isPending: index == 2 || index == 8))
        }
        #expect(engine.nextPending(near: 0) == 2)
        #expect(engine.nextPending(near: 4) == 2)
        // Equidistant: the row above wins, so a drain never oscillates.
        #expect(engine.nextPending(near: 5) == 2)
        #expect(engine.nextPending(near: 6) == 8)
        #expect(engine.nextPending(near: 11) == 8)

        engine.setHeight(10, at: 2)
        #expect(engine.nextPending(near: 0) == 8)
        engine.setHeight(10, at: 8)
        #expect(engine.nextPending(near: 0) == nil)
        #expect(!engine.hasPendingRows)
    }

    /// The whole point of the tree: a hundred thousand appends stay linear
    /// overall rather than quadratic, and every query stays exact.
    @Test
    func staysExactAcrossOneHundredThousandAppends() {
        var engine = ListLayoutEngine()
        for index in 0 ..< 100_000 {
            engine.append(.init(height: 44, isPending: index % 3 == 0))
        }
        #expect(engine.count == 100_000)
        #expect(engine.totalHeight == 4_400_000)
        #expect(engine.pendingCount == 33_334)
        #expect(engine.offset(at: 50_000) == 2_200_000)
        #expect(engine.index(atOffset: 2_200_000) == 50_000)
        #expect(engine.indices(in: 2_200_000 ..< 2_200_600) == 50_000 ..< 50_014)

        engine.setHeight(100, at: 0)
        #expect(engine.totalHeight == 4_400_056)
        #expect(engine.offset(at: 1) == 100)
        #expect(engine.pendingCount == 33_333)
    }
}
