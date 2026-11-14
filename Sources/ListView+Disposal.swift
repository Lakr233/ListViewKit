//
//  ListView+Disposal.swift
//  ListViewKit
//

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#else
    #error("ListViewKit requires UIKit or AppKit")
#endif

extension ListView {
    /// A removed row about to leave the screen, noted before it is recycled.
    struct LeavingRow {
        let identifier: Item.ID
        /// Where the row stood, in the list.
        let frame: CGRect
        #if canImport(UIKit)
            /// Its picture, standing where it stood.
            let snapshot: DisposalSnapshotView
        #elseif canImport(AppKit)
            let view: ListRowView
            let registration: Int
        #endif
    }

    /// Notes the mounted rows among `removed` before any of them is
    /// recycled, each with what it takes to show it leaving.
    ///
    /// On UIKit that is a picture, taken now: the row goes straight back to
    /// the reuse pool, and what leaves the screen is a throwaway copy. On
    /// AppKit it is the row itself, which ``placeDisposals(_:)`` takes back
    /// out of the pool for the length of its exit. A picture there is
    /// drawn by `cacheDisplay`, which sees nothing a layer was handed
    /// directly: an avatar showed as its placeholder letter in the copy,
    /// an image as an empty frame, and a glass bubble over a wallpaper as
    /// its words alone.
    func prepareDisposals(of removed: [Item.ID]) -> [LeavingRow] {
        var leaving: [LeavingRow] = []
        for identifier in removed {
            guard let entry = visibleRows[identifier] else { continue }
            let frame = entry.view.convert(entry.view.bounds, to: self)
            #if canImport(UIKit)
                guard let picture = disposalPicture(of: entry.view) else { continue }
                let snapshot = DisposalSnapshotView(holding: picture, size: frame.size)
                placeView(frame, on: snapshot)
                addSubview(snapshot)
                leaving.append(.init(identifier: identifier, frame: frame, snapshot: snapshot))
            #elseif canImport(AppKit)
                leaving.append(.init(identifier: identifier, frame: frame, view: entry.view, registration: entry.registration))
            #endif
        }
        return leaving
    }

    /// Stands each noted row where it stood, now that the rows themselves
    /// have been recycled, and returns what will leave the screen for each.
    ///
    /// The box stands still until ``fadeDisposal(_:)`` or
    /// ``foldDisposal(_:toSeamAt:)`` sends it off; how it goes is not known
    /// until the new layout is.
    func placeDisposals(_ leaving: [LeavingRow]) -> [(identifier: Item.ID, snapshot: DisposalSnapshotView)] {
        #if canImport(UIKit)
            leaving.map { ($0.identifier, $0.snapshot) }
        #elseif canImport(AppKit)
            leaving.compactMap { row in
                guard let snapshot = disposalSnapshot(of: row) else { return nil }
                placeView(row.frame, on: snapshot)
                addSubview(snapshot)
                return (row.identifier, snapshot)
            }
        #endif
    }

    /// Fades a removed row out in its place.
    ///
    /// For a row nothing closes over: the last rows of the list, or one that
    /// left as another came in at the same place.
    func fadeDisposal(_ snapshot: DisposalSnapshotView) {
        #if canImport(UIKit)
            withListAnimation {
                snapshot.alpha = 0
            } completion: { _ in
                MainActor.assumeIsolated {
                    snapshot.removeFromSuperview()
                }
            }
        #elseif canImport(AppKit)
            withListAnimation {
                snapshot.alphaValue = 0
            }
            afterRowSlide { [weak self] in
                self?.endDisposal(snapshot)
            }
        #endif
    }

    /// Closes a removed row down to nothing at `seamY`, where the rows on
    /// either side of it meet in the new layout, as it fades.
    ///
    /// Its lower edge then rides on the row sliding up under it, which
    /// covers it as it comes: nothing is ever drawn over anything else. A
    /// row left to fade where it stood had the rows below sliding through
    /// it for the length of the fade, their words over its. It still
    /// fades: the last of a box to close is the top edge of what it held,
    /// and a strip of that, left opaque, lingers on the spring's tail.
    func foldDisposal(_ snapshot: DisposalSnapshotView, toSeamAt seamY: CGFloat) {
        #if canImport(UIKit)
            withListAnimation {
                snapshot.frame = CGRect(x: snapshot.frame.minX, y: seamY, width: snapshot.frame.width, height: 0)
                snapshot.alpha = 0
            } completion: { _ in
                MainActor.assumeIsolated {
                    snapshot.removeFromSuperview()
                }
            }
        #elseif canImport(AppKit)
            // Inside the list's animation, as the rows' slides are added:
            // an animation added there takes the group's timing on top of
            // its own, and a spring added outside it ran ahead of the row
            // it was meant to ride on by a fifth of the way (measured on
            // frames of a fold closing, 2026-11-14).
            withListAnimation {
                foldView(snapshot, toSeamAt: seamY)
                snapshot.alphaValue = 0
            }
            afterRowSlide { [weak self] in
                self?.endDisposal(snapshot)
            }
        #endif
    }

    #if canImport(UIKit)
        private func disposalPicture(of view: ListRowView) -> UIView? {
            view.layoutIfNeeded()
            return view.snapshotView(afterScreenUpdates: false)
        }

    #elseif canImport(AppKit)
        /// The box a recycled row leaves the screen in: around the row
        /// itself, taken back out of the pool, or around a picture of it
        /// when the pool it went to is not the list's.
        private func disposalSnapshot(of row: LeavingRow) -> DisposalSnapshotView? {
            if let generation = withholdRecycledRow(row.view, registration: row.registration) {
                // Whatever was still moving it was aimed at a place in the
                // list; in the box it stands at the box's corner.
                cancelRowAnimations(on: row.view)
                let snapshot = DisposalSnapshotView(holding: row.view, size: row.frame.size)
                snapshot.heldRow = (row.registration, generation)
                return snapshot
            }
            guard let picture = disposalPicture(of: row.view) else { return nil }
            return DisposalSnapshotView(holding: picture, size: row.frame.size)
        }

        /// Takes a box that has left off the screen, and puts the row it
        /// held back in the pool.
        private func endDisposal(_ snapshot: DisposalSnapshotView) {
            snapshot.removeFromSuperview()
            guard let held = snapshot.heldRow, let view = snapshot.subviews.first as? ListRowView else { return }
            snapshot.heldRow = nil
            view.removeFromSuperview()
            releaseWithheldRow(view, registration: held.registration, generation: held.generation)
        }

        /// A picture of a row, for one the list cannot hold: drawn by
        /// AppKit, so without anything its layers were handed directly.
        private func disposalPicture(of view: ListRowView) -> NSView? {
            view.display()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                return nil
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(bitmap)
            return NSImageView(image: image)
        }
    #endif
}

#if canImport(UIKit)
    /// A picture of a row on its way out, in a box that can close over it.
    ///
    /// The picture keeps its size and its place at the box's top while the
    /// box closes, so it is covered rather than squeezed. The list animates
    /// with `.allowUserInteraction`, so the box is hit-testable for as long
    /// as it stands; the row sliding in underneath is the one to touch.
    final class DisposalSnapshotView: UIView {
        /// `size` is the row's: a picture just made has not always been
        /// given one.
        init(holding picture: UIView, size: CGSize) {
            super.init(frame: CGRect(origin: .zero, size: size))
            clipsToBounds = true
            isUserInteractionEnabled = false
            picture.frame = bounds
            picture.autoresizingMask = []
            addSubview(picture)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError()
        }
    }

#elseif canImport(AppKit)
    /// A row on its way out — the row itself, or a picture of it — in a
    /// box that can close over it.
    ///
    /// What it holds keeps its size and its place at the box's top while
    /// the box closes, so it is covered rather than squeezed. The box sits
    /// on top of the rows sliding into its slot for as long as it stands,
    /// so it answers no clicks, and neither does the row inside it.
    final class DisposalSnapshotView: NSView {
        /// The pool the row inside came out of, when it is a row: its
        /// registration, and the pools' generation when it was taken.
        var heldRow: (registration: Int, generation: Int)?

        /// `size` is the row's: a picture just made has not always been
        /// given one.
        init(holding picture: NSView, size: CGSize) {
            super.init(frame: CGRect(origin: .zero, size: size))
            wantsLayer = true
            layer?.masksToBounds = true
            picture.frame = bounds
            picture.autoresizingMask = []
            addSubview(picture)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError()
        }

        /// The picture hangs from the box's top, as a row's contents do.
        override var isFlipped: Bool {
            true
        }

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }
    }
#endif
