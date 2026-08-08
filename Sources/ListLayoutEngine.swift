//
//  ListLayoutEngine.swift
//  ListViewKit
//

import CoreGraphics

/// Vertical row geometry addressed by position.
///
/// Every row carries a height that is either measured or an estimate still
/// awaiting measurement. Prefix sums, hit testing and the "which row still
/// needs measuring" search all run over a single Fenwick tree, so appending a
/// row, measuring a row and locating an offset are each O(log n). Nothing on
/// this path hashes, boxes, or resolves an identifier.
///
/// The engine holds no identity. Carrying a measured height across an
/// insertion or a move belongs to whoever owns the item order; the engine only
/// ever sees positions.
struct ListLayoutEngine {
    /// One row's contribution to the layout.
    ///
    /// Heights are normalized to whole nonnegative points on the way in. A
    /// Fenwick descent adds node sums in a different order than a prefix walk,
    /// so fractional heights let `index(atOffset: offset(at: k))` round to the
    /// wrong row; whole numbers stay exact in a `CGFloat` far past any
    /// reachable list length. Rows are pixel geometry, so this costs nothing.
    struct Row: Equatable {
        let height: CGFloat
        /// True while `height` is an estimate awaiting measurement.
        var isPending: Bool

        init(height: CGFloat, isPending: Bool) {
            self.height = height.isFinite ? ceil(max(0, height)) : 0
            self.isPending = isPending
        }
    }

    /// What a Fenwick node accumulates. Heights answer geometry queries and
    /// pending counts answer scheduling queries, so both ride one traversal.
    private struct Sums {
        var height: CGFloat = 0
        var pending: Int = 0
    }

    private var rows: [Row] = []
    /// Fenwick tree over `rows`, one-based. `tree[i]` sums the rows in
    /// `(i - lowbit(i), i]`, and `tree[0]` is unused padding.
    private var tree: [Sums] = [Sums()]

    init() {}

    // MARK: - Reading

    var count: Int { rows.count }
    var totalHeight: CGFloat { prefix(rows.count).height }
    var pendingCount: Int { prefix(rows.count).pending }
    var hasPendingRows: Bool { pendingCount > 0 }

    func height(at index: Int) -> CGFloat { rows[index].height }
    func isPending(at index: Int) -> Bool { rows[index].isPending }

    /// Distance from the top of the list to the top of `index`.
    func offset(at index: Int) -> CGFloat { prefix(index).height }

    /// The row containing `y`, clamped into range. An empty list returns nil.
    func index(atOffset y: CGFloat) -> Int? {
        guard !rows.isEmpty else { return nil }
        var position = 0
        var remaining = y
        var step = highestStep
        while step > 0 {
            let probe = position + step
            if probe < tree.count, tree[probe].height <= remaining {
                remaining -= tree[probe].height
                position = probe
            }
            step >>= 1
        }
        return min(position, rows.count - 1)
    }

    /// The contiguous span of rows overlapping
    /// `[yRange.lowerBound, yRange.upperBound)`.
    func indices(in yRange: Range<CGFloat>) -> Range<Int> {
        guard let start = index(atOffset: yRange.lowerBound) else { return 0 ..< 0 }
        var edge = offset(at: start)
        // `index(atOffset:)` clamps, so a range wholly past the content lands
        // on the last row without overlapping it.
        guard edge < yRange.upperBound, edge + rows[start].height > yRange.lowerBound else {
            return 0 ..< 0
        }
        var end = start
        repeat {
            edge += rows[end].height
            end += 1
        } while end < rows.count && edge < yRange.upperBound
        return start ..< end
    }

    /// The pending row nearest `index`, preferring the one above on a tie.
    /// Nil when every row has been measured.
    func nextPending(near index: Int) -> Int? {
        let total = pendingCount
        guard total > 0 else { return nil }
        let pivot = min(max(index, 0), rows.count)
        let ranksAbove = prefix(pivot).pending
        let above = ranksAbove > 0 ? indexOfPending(rank: ranksAbove) : nil
        let below = ranksAbove < total ? indexOfPending(rank: ranksAbove + 1) : nil
        switch (above, below) {
        case let (above?, below?):
            return index - above <= below - index ? above : below
        case let (above?, nil):
            return above
        case let (nil, below?):
            return below
        case (nil, nil):
            return nil
        }
    }

    // MARK: - Writing

    /// Replaces the whole layout. O(n), and the path every structural change
    /// other than a plain append takes: the caller is already walking the new
    /// item order to carry measured heights across.
    mutating func reset(_ newRows: [Row]) {
        rows = newRows
        tree = Array(repeating: Sums(), count: rows.count + 1)
        for index in rows.indices {
            let node = index + 1
            tree[node].height += rows[index].height
            tree[node].pending += rows[index].isPending ? 1 : 0
            let parent = node + lowbit(node)
            if parent < tree.count {
                tree[parent].height += tree[node].height
                tree[parent].pending += tree[node].pending
            }
        }
    }

    /// Adds a row at the end in O(log n) — the path a chat client takes for
    /// every new message.
    mutating func append(_ row: Row) {
        let index = rows.count
        let node = index + 1
        // The new node spans `(node - lowbit(node), node]`. Seed it with the
        // rows already in that span, then fold in the new row itself.
        let spanStart = node - lowbit(node)
        let existing = prefix(node - 1)
        let seeded = prefix(spanStart)
        rows.append(row)
        tree.append(Sums(
            height: existing.height - seeded.height,
            pending: existing.pending - seeded.pending
        ))
        add(height: row.height, pending: row.isPending ? 1 : 0, at: index)
    }

    /// Records a measurement, clearing the row's pending flag.
    mutating func setHeight(_ height: CGFloat, at index: Int) {
        let previous = rows[index]
        let measured = Row(height: height, isPending: false)
        rows[index] = measured
        add(
            height: measured.height - previous.height,
            pending: previous.isPending ? -1 : 0,
            at: index
        )
    }

    /// Marks a measured row as needing measurement again, keeping its current
    /// height as the estimate until the new one arrives.
    mutating func invalidate(at index: Int) {
        guard !rows[index].isPending else { return }
        rows[index].isPending = true
        add(height: 0, pending: 1, at: index)
    }

    // MARK: - Fenwick

    private func lowbit(_ value: Int) -> Int { value & -value }

    /// Largest power of two that can start a descent over `rows`.
    private var highestStep: Int {
        guard !rows.isEmpty else { return 0 }
        return 1 << (Int.bitWidth - 1 - rows.count.leadingZeroBitCount)
    }

    /// Sums the first `endIndex` rows.
    private func prefix(_ endIndex: Int) -> Sums {
        var sums = Sums()
        var node = endIndex
        while node > 0 {
            sums.height += tree[node].height
            sums.pending += tree[node].pending
            node -= lowbit(node)
        }
        return sums
    }

    private mutating func add(height: CGFloat, pending: Int, at index: Int) {
        guard height != 0 || pending != 0 else { return }
        var node = index + 1
        while node < tree.count {
            tree[node].height += height
            tree[node].pending += pending
            node += lowbit(node)
        }
    }

    /// Position of the `rank`-th pending row, counting from one.
    private func indexOfPending(rank: Int) -> Int {
        var position = 0
        var remaining = rank
        var step = highestStep
        while step > 0 {
            let probe = position + step
            if probe < tree.count, tree[probe].pending < remaining {
                remaining -= tree[probe].pending
                position = probe
            }
            step >>= 1
        }
        return position
    }
}
