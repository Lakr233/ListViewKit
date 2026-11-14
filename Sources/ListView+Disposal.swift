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
    /// Stands a picture of a removed row where the row stood, and returns it.
    ///
    /// The row itself goes straight back to the reuse pool, so what leaves
    /// the screen is a throwaway copy rather than a row held hostage for the
    /// duration. The picture stands still until ``fadeDisposal(_:)`` or
    /// ``foldDisposal(_:toSeamAt:)`` sends it off; how it goes is not known
    /// until the new layout is, and the picture has to be taken before any
    /// row is recycled.
    func placeDisposalSnapshot(of view: ListRowView) -> DisposalSnapshotView? {
        let frameInList = view.convert(view.bounds, to: self)
        guard let picture = disposalPicture(of: view) else { return nil }
        let snapshot = DisposalSnapshotView(picture: picture, size: frameInList.size)
        placeView(frameInList, on: snapshot)
        addSubview(snapshot)
        return snapshot
    }

    /// Fades a removed row's picture out in its place.
    ///
    /// For a row nothing closes over: the last rows of the list, or one that
    /// left as another came in at the same place.
    func fadeDisposal(_ snapshot: DisposalSnapshotView) {
        withListAnimation {
            #if canImport(UIKit)
                snapshot.alpha = 0
            #elseif canImport(AppKit)
                snapshot.alphaValue = 0
            #endif
        } completion: { _ in
            MainActor.assumeIsolated {
                snapshot.removeFromSuperview()
            }
        }
    }

    /// Closes a removed row's picture down to nothing at `seamY`, where the
    /// rows on either side of it meet in the new layout, as it fades.
    ///
    /// The picture's lower edge then rides on the row sliding up under it,
    /// which covers it as it comes: nothing is ever drawn over anything
    /// else. A picture left to fade where it stood had the rows below
    /// sliding through it for the length of the fade, their words over its.
    /// It still fades: the last of a box to close is the top edge of what
    /// it held, and a strip of that, left opaque, lingers on the spring's
    /// tail.
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
            afterRowSlide {
                snapshot.removeFromSuperview()
            }
        #endif
    }

    #if canImport(UIKit)
        private func disposalPicture(of view: ListRowView) -> UIView? {
            view.layoutIfNeeded()
            return view.snapshotView(afterScreenUpdates: false)
        }

    #elseif canImport(AppKit)
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
        init(picture: UIView, size: CGSize) {
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
    /// A picture of a row on its way out, in a box that can close over it.
    ///
    /// The picture keeps its size and its place at the box's top while the
    /// box closes, so it is covered rather than squeezed. It sits on top of
    /// the rows sliding into its slot for as long as it stands, so it
    /// answers no clicks.
    final class DisposalSnapshotView: NSView {
        /// `size` is the row's: a picture just made has not always been
        /// given one.
        init(picture: NSView, size: CGSize) {
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
