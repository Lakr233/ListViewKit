//
//  ListView+Seams.swift
//  ListViewKit
//
//  A seam is where two rows that stay in the list meet: rows that come in
//  between them open the seam, rows that leave from between them close it.
//
//  An animated apply used to fade both in place — the new rows in over the
//  rows still sliding out from under them, the old ones out while the rows
//  below slid up through them — and for the half second that took, two
//  sets of words stood on the same pixels. At a seam there is something
//  better to do, because the rows on either side say exactly where the edge
//  between old and new is on every frame: a row coming in grows out of the
//  seam with its lower edge on the row sliding away under it, and a row
//  going out closes into the seam with its lower edge on the row sliding
//  in. One spring moves all of it, and nothing is drawn over anything.
//  They still fade as they go. A box that has barely opened shows only the
//  top edge of what it holds, and several of those in a row are a smear
//  rather than rows; faint, they are not seen until there is a row to see.
//
//  Only where there is room to open or to close. Rows that come in where
//  others left take their place first: as far down as the old rows stood,
//  new and old swap where they are, and a fade is what a swap is. What the
//  new rows hold past that is what opens the seam, and what the old ones
//  held past the new is what closes it. A chat's name line is the case:
//  keyed by the first message under it, it is another row once a fold above
//  that message opens, standing exactly where the old one stood. The rows
//  at either end of the list have a neighbour on one side only, and fade.
//

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#else
    #error("ListViewKit requires UIKit or AppKit")
#endif

extension ListView {
    /// How far a row may start short of the room that was there and still
    /// count as past it: frames are sums of heights, and two that should
    /// meet can miss by a rounding.
    private static var seamSlack: CGFloat { 0.5 }

    /// Where each mounted row that grows out of a seam starts from: the
    /// seam as it stood in the old layout, in the space row frames are
    /// stated in. A new row with no entry fades in where it stands.
    ///
    /// A run of new rows stands at a seam when the rows either side of it
    /// stay, and nothing that stays stood between those two before. The
    /// rows of the run that start past what did stand there — everything,
    /// when nothing did — open the seam. `added` is in the new order, as
    /// ``ListDifference`` builds it, so each run is a stretch of it.
    final func openingSeams(
        added: [Item.ID],
        previousItems: [Item],
        previousIndexByID: [Item.ID: Int],
        previousGeometry: ListRowLayout<Item>.Geometry
    ) -> [Item.ID: CGFloat] {
        var seams: [Item.ID: CGFloat] = [:]
        var position = 0
        while position < added.count {
            guard let first = indexByID[added[position]] else {
                position += 1
                continue
            }
            var last = first
            var next = position + 1
            while next < added.count, indexByID[added[next]] == last + 1 {
                last += 1
                next += 1
            }
            defer { position = next }
            guard first > 0, last + 1 < items.count,
                  let above = previousIndexByID[items[first - 1].id],
                  let below = previousIndexByID[items[last + 1].id],
                  above < below,
                  !(above + 1 ..< below).contains(where: { indexByID[previousItems[$0].id] != nil }),
                  let aboveFrame = previousGeometry.frame(for: above),
                  let seam = previousGeometry.frame(for: below)
            else { continue }
            // What stood between the two before, which the run's first rows
            // take the place of.
            let stood = seam.minY - aboveFrame.maxY
            let top = rectForRow(at: first).minY
            for index in position ..< next where visibleRows[added[index]] != nil {
                let row = first + index - position
                guard rectForRow(at: row).minY - top >= stood - Self.seamSlack else { continue }
                seams[added[index]] = seam.minY + topInset
            }
        }
        return seams
    }

    /// Where each removed row that closes into a seam closes to: the seam
    /// as it stands in the new layout, in the space row frames are stated
    /// in. A removed row with no entry fades out where it stood.
    ///
    /// The mirror of ``openingSeams(added:previousItems:previousIndexByID:previousGeometry:)``:
    /// the rows either side of the run stay, nothing that stayed stands
    /// between them now, and the rows of the run that started past what
    /// does stand there close the seam. `removed` is in the old order.
    final func closingSeams(
        removed: [Item.ID],
        previousItems: [Item],
        previousIndexByID: [Item.ID: Int],
        previousGeometry: ListRowLayout<Item>.Geometry
    ) -> [Item.ID: CGFloat] {
        var seams: [Item.ID: CGFloat] = [:]
        var position = 0
        while position < removed.count {
            guard let first = previousIndexByID[removed[position]] else {
                position += 1
                continue
            }
            var last = first
            var next = position + 1
            while next < removed.count, previousIndexByID[removed[next]] == last + 1 {
                last += 1
                next += 1
            }
            defer { position = next }
            guard first > 0, last + 1 < previousItems.count,
                  let above = indexByID[previousItems[first - 1].id],
                  let below = indexByID[previousItems[last + 1].id],
                  above < below,
                  !(above + 1 ..< below).contains(where: { previousIndexByID[items[$0].id] != nil }),
                  let top = previousGeometry.frame(for: first)?.minY
            else { continue }
            let seamY = rectForRow(at: below).minY
            // What stands between the two now, which took the place of the
            // run's first rows.
            let stands = seamY - rectForRow(at: above).maxY
            for index in position ..< next {
                guard let frame = previousGeometry.frame(for: first + index - position),
                      frame.minY - top >= stands - Self.seamSlack
                else { continue }
                seams[removed[index]] = seamY
            }
        }
        return seams
    }

    // MARK: - Clipping a row while it unfolds

    /// Has `view` cut off what it draws past its box until the unfold it is
    /// starting has landed.
    ///
    /// A row may have asked not to be clipped — a shadow, a tail, a focus
    /// ring that spill past its box — and while its box is still opening,
    /// everything it holds is past its box. What the row asked for is put
    /// back by ``endUnfolding(_:mountID:)``, or when the row is recycled,
    /// whichever comes first.
    final func beginUnfolding(_ view: ListRowView) {
        if var unfolding = unfoldingRows[view.mountID] {
            unfolding.count += 1
            unfoldingRows[view.mountID] = unfolding
            return
        }
        unfoldingRows[view.mountID] = (clipped: rowClipsToBounds(view), count: 1)
        setRowClipsToBounds(true, on: view)
    }

    /// One unfold of `view` has landed. `mountID` is the mount it started
    /// in: a view recycled since shows another item, and has had its
    /// clipping put back already.
    final func endUnfolding(_ view: ListRowView, mountID: Int) {
        guard view.mountID == mountID, var unfolding = unfoldingRows[mountID] else { return }
        unfolding.count -= 1
        guard unfolding.count <= 0 else {
            unfoldingRows[mountID] = unfolding
            return
        }
        unfoldingRows[mountID] = nil
        setRowClipsToBounds(unfolding.clipped, on: view)
    }

    /// Runs `body` once a row slide that starts now has landed.
    ///
    /// On a timer, as ``holdMountedRows(for:)`` releases its rows, rather
    /// than on the animation's own completion: an animation on a layer
    /// nothing is drawing — a window off screen, a list not in one yet —
    /// does not report that it ended, and what waits on it here is a row's
    /// clipping and a picture's removal, which must happen either way.
    final func afterRowSlide(_ body: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: listRowSlideDuration, repeats: false) { _ in
            MainActor.assumeIsolated(body)
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Puts back what `view` asked for at once: its mount is ending.
    final func stopUnfolding(_ view: ListRowView) {
        guard let unfolding = unfoldingRows.removeValue(forKey: view.mountID) else { return }
        setRowClipsToBounds(unfolding.clipped, on: view)
    }
}
