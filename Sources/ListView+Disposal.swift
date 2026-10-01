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
    /// Fades a snapshot of a removed row out in its place.
    ///
    /// The row itself goes straight back to the reuse pool, so the animation
    /// runs on a throwaway copy rather than holding a row hostage for the
    /// duration.
    func animateDisposal(of view: ListRowView) {
        let frameInList = view.convert(view.bounds, to: self)
        guard let snapshot = disposalSnapshot(of: view) else { return }
        placeView(frameInList, on: snapshot)
        addSubview(snapshot)
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

    #if canImport(UIKit)
        private func disposalSnapshot(of view: ListRowView) -> UIView? {
            view.layoutIfNeeded()
            let snapshot = view.snapshotView(afterScreenUpdates: false)
            // The list animates with `.allowUserInteraction`, so the fade is
            // hit-testable; the row sliding in underneath is the one to touch.
            snapshot?.isUserInteractionEnabled = false
            return snapshot
        }

    #elseif canImport(AppKit)
        private func disposalSnapshot(of view: ListRowView) -> NSView? {
            view.display()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                return nil
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(bitmap)
            let snapshot = DisposalSnapshotView(image: image)
            snapshot.wantsLayer = true
            return snapshot
        }
    #endif
}

#if canImport(AppKit) && !canImport(UIKit)
    /// A picture of a row on its way out. It sits on top of the rows sliding
    /// into its slot for the length of the fade, so it answers no clicks.
    private final class DisposalSnapshotView: NSImageView {
        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }
    }
#endif
