//
//  Created by ktiays on 2025/1/16.
//  Copyright (c) 2025 ktiays. All rights reserved.
//
//  Two rules hold this file together:
//
//  1. The list animates only what it said to animate. A list update routinely
//     runs inside somebody else's animation — the keyboard pattern wraps
//     `layoutIfNeeded()` in a block, and the whole layout pass happens in
//     there — so ownership has to be passed down explicitly rather than read
//     off the ambient context, which cannot tell the two apart.
//  2. Placing a view is not moving it. A view that was not on screen has no
//     previous position worth interpolating from.
//

import QuartzCore

/// How long a list change takes to settle.
let listAnimationDuration: TimeInterval = 0.5

#if canImport(UIKit)
    import UIKit

    /// How long a row the list moves takes to arrive.
    let listRowSlideDuration = listAnimationDuration

    /// How long the animation a host has open around the current call has
    /// left to run, or 0 outside one.
    @MainActor
    var ambientAnimationDuration: TimeInterval {
        UIView.inheritedAnimationDuration
    }

    @MainActor
    func withListAnimation(_ animation: @escaping () -> Void, completion: (@Sendable (Bool) -> Void)? = nil) {
        UIView.animate(
            withDuration: listAnimationDuration,
            delay: 0,
            usingSpringWithDamping: 0.85,
            initialSpringVelocity: 0.85,
            options: .allowUserInteraction,
            animations: animation,
            completion: completion
        )
    }

    /// Runs `body` with every ambient animation suppressed.
    ///
    /// Infrastructure writes have to opt out of whatever block they happen to
    /// be running inside, and a bare assignment is not enough: `UIView.animate`
    /// installs an animation context for the duration of its closure, and a
    /// view returns an action for any animatable property changed while that
    /// context is live, however deep in the call stack the change happens.
    ///
    /// This suppresses; it never cancels. Stopping an animation already in
    /// flight is a different operation, and conflating the two would kill a
    /// running reorder on the next layout pass.
    @MainActor
    func withoutListAnimation(_ body: () -> Void) {
        UIView.performWithoutAnimation(body)
    }

    /// Puts a view at `frame` without animating.
    ///
    /// Placement is not movement. A row just out of the reuse pool is still
    /// sitting at the frame its previous item left it at, and a fresh one sits
    /// at the origin; neither is a position to travel from.
    @MainActor
    func placeView(_ frame: CGRect, on view: UIView) {
        withoutListAnimation { view.frame = frame }
    }

    /// Drops any list animation still attached to a row.
    ///
    /// A row can be recycled mid-slide. What is left of that motion belongs to
    /// the item it used to show, not to the one moving in. Only the row's own
    /// layer is cleared — its contents belong to the row.
    @MainActor
    func cancelRowAnimations(on view: ListRowView) {
        view.layer.removeAllAnimations()
    }

    /// Moves a row to its new frame.
    ///
    /// `animated: true` means this write belongs to the list's own animation,
    /// which is already open around it — not that a new one starts here.
    ///
    /// UIView's block animations are additive: one arriving mid-flight adds its
    /// motion to whatever is already running instead of replacing it, so the
    /// row carries its speed through the interruption. Setting the frame is the
    /// whole job here — the AppKit side has to build that behaviour by hand.
    /// That additivity only holds inside the list's own block, which is why the
    /// caller has to say whether it is in one.
    ///
    /// Written through `bounds` and `center` rather than `frame`, because a
    /// row carrying a displacement has a transform on it and `frame` means
    /// nothing then. The two are equivalent when the transform is the identity
    /// and animate the same way inside a block.
    @MainActor
    func setRowFrame(_ frame: CGRect, on view: ListRowView, animated: Bool) {
        view.placedFrame = frame
        guard animated else {
            withoutListAnimation { applyRowGeometry(frame, on: view) }
            return
        }
        applyRowGeometry(frame, on: view)
    }

    @MainActor
    private func applyRowGeometry(_ frame: CGRect, on view: ListRowView) {
        view.bounds.size = frame.size
        view.center = CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Shows a row `dy` away from where the list placed it.
    ///
    /// The transform is a different key path from the position a list
    /// animation moves, so a displacement written every frame and a reorder
    /// running underneath it do not overwrite each other. UIKit also hit-tests
    /// through a transform, so a displaced row still answers touches where it
    /// is drawn.
    ///
    /// Suppression is the caller's job: this runs for every mounted row, and
    /// wrapping each one separately would cost more than the write.
    @MainActor
    func setRowPresentationOffset(_ dy: CGFloat, on view: ListRowView) {
        guard view.presentationOffset != dy else { return }
        view.presentationOffset = dy
        view.transform = dy == 0 ? .identity : CGAffineTransform(translationX: 0, y: dy)
    }

    /// Moves a row to its frame from a box of another height, the box
    /// growing or closing over what the row holds.
    ///
    /// For a row that enters at a seam: it stands there with no height, and
    /// travels to its frame while its box opens over it. The row's contents
    /// are laid out for the frame it is headed to throughout, so nothing in
    /// it moves; the box uncovers it. A block animation carries the size
    /// with the position, on the same spring as the rows sliding beside it.
    @MainActor
    func unfoldRow(to frame: CGRect, on view: ListRowView) {
        setRowFrame(frame, on: view, animated: true)
    }

    /// Whether a row cuts off what it draws past its box.
    @MainActor
    func rowClipsToBounds(_ view: ListRowView) -> Bool {
        view.clipsToBounds
    }

    @MainActor
    func setRowClipsToBounds(_ clips: Bool, on view: ListRowView) {
        view.clipsToBounds = clips
    }

#elseif canImport(AppKit)
    import AppKit

    /// The spring a row slides on. What `init(perceptualDuration:bounce:)`
    /// builds for a bounce of 0, spelt out because that initializer needs
    /// macOS 14: a unit mass, stiffness (2π / duration)², and the critical
    /// damping 2√stiffness.
    private func makeRowSlide(keyPath: String = "position") -> CASpringAnimation {
        let slide = CASpringAnimation(keyPath: keyPath)
        let angularFrequency = 2 * Double.pi / listAnimationDuration
        slide.mass = 1
        slide.stiffness = angularFrequency * angularFrequency
        slide.damping = 2 * angularFrequency
        slide.duration = slide.settlingDuration
        return slide
    }

    /// How long a row the list moves takes to arrive: the spring's settling
    /// time, which outlasts ``listAnimationDuration``.
    let listRowSlideDuration = makeRowSlide().duration

    /// How long the animation a host has open around the current call has
    /// left to run, or 0 outside one. Only an implicit context moves a view
    /// whose frame the list sets directly.
    @MainActor
    var ambientAnimationDuration: TimeInterval {
        let context = NSAnimationContext.current
        return context.allowsImplicitAnimation ? context.duration : 0
    }

    @MainActor
    func withListAnimation(_ animation: @escaping () -> Void, completion: (@Sendable (Bool) -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = listAnimationDuration
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation()
        } completionHandler: {
            completion?(true)
        }
    }

    /// Runs `body` with every ambient animation suppressed.
    ///
    /// Infrastructure writes have to opt out of whatever context they happen to
    /// be running inside, and a bare assignment is not enough. Two levers,
    /// because there are two ways in: a view's animatable setters consult the
    /// current animation context, while writes that reach the layer directly
    /// consult the transaction.
    ///
    /// This suppresses; it never cancels. Stopping an animation already in
    /// flight is a different operation, and conflating the two would kill a
    /// running reorder on the next layout pass.
    @MainActor
    func withoutListAnimation(_ body: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            CATransaction.setDisableActions(true)
            body()
        }
    }

    /// Puts a view at `frame` without animating.
    ///
    /// Placement is not movement. A row just out of the reuse pool is still
    /// sitting at the frame its previous item left it at, and a fresh one sits
    /// at the origin; neither is a position to travel from.
    @MainActor
    func placeView(_ frame: CGRect, on view: NSView) {
        withoutListAnimation { view.frame = frame }
    }

    /// Drops any list animation still attached to a row.
    ///
    /// A row can be recycled mid-slide. What is left of that motion belongs to
    /// the item it used to show, not to the one moving in. Only the row's own
    /// layer is cleared — its contents belong to the row.
    @MainActor
    func cancelRowAnimations(on view: ListRowView) {
        view.layer?.removeAllAnimations()
    }

    /// Distinguishes overlapping slides on one layer. Reusing a key would evict
    /// the very animation the next one is meant to continue from.
    @MainActor
    private var slideSequence = 0

    /// A displaced row sits away from where it was placed, so the reader sees
    /// ``ListRowView/placedFrame`` plus the displacement.
    @MainActor
    private func presentedFrame(for view: ListRowView, placedAt frame: CGRect) -> CGRect {
        frame.offsetBy(dx: 0, dy: view.presentationOffset)
    }

    /// Shows a row `dy` away from where the list placed it.
    ///
    /// The frame, not the transform: AppKit hit testing and accessibility read
    /// a view's frame and ignore what its backing layer's transform did, so a
    /// row displaced by a transform would answer clicks somewhere other than
    /// where it is drawn. Composition survives that choice because the slide
    /// in `setRowFrame` is additive — it contributes a delta on top of the
    /// model position rather than driving it, and because a displacement that
    /// is unchanged across a placement write cancels out of the offset that
    /// slide is measured by.
    ///
    /// Suppression is the caller's job: this runs for every mounted row, and
    /// wrapping each one separately would cost more than the write.
    @MainActor
    func setRowPresentationOffset(_ dy: CGFloat, on view: ListRowView) {
        guard view.presentationOffset != dy else { return }
        view.presentationOffset = dy
        view.frame = presentedFrame(for: view, placedAt: view.placedFrame)
    }

    /// Moves a row to its new frame, adding the slide to whatever is already in
    /// flight rather than replacing it.
    ///
    /// `animated: true` means this write belongs to the list's own animation,
    /// which is already open around it — not that a new one starts here.
    ///
    /// An implicit animation replaces its predecessor and starts its curve from
    /// rest. The row's position stays continuous across that — Core Animation
    /// picks the presentation value up as the new start — but its *speed* drops
    /// to zero, so a reorder arriving mid-slide reads as the first one stopping
    /// dead and starting over.
    ///
    /// Additive animations sum instead. The running slide plays out its
    /// remaining curve while the new one contributes only the correction from
    /// where the row was headed to where it is now headed, so the velocities
    /// add up and the row never stalls. Each animates its delta down to zero
    /// and is removed once it lands, leaving nothing behind to drift.
    ///
    /// A row carrying a displacement composes with this without special
    /// handling, as long as the write below carries it too: the offset is the
    /// difference between two positions taken either side of the write, and a
    /// displacement present in both cancels out of it.
    @MainActor
    func setRowFrame(_ frame: CGRect, on view: ListRowView, animated: Bool) {
        view.placedFrame = frame
        guard animated, let layer = view.layer else {
            placeView(presentedFrame(for: view, placedAt: frame), on: view)
            return
        }
        let previousPosition = layer.position
        // The frame moves outright; the slide below is what the reader sees.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.frame = presentedFrame(for: view, placedAt: frame)
        CATransaction.commit()

        let offset = CGPoint(
            x: previousPosition.x - layer.position.x,
            y: previousPosition.y - layer.position.y
        )
        guard offset != .zero else { return }
        let slide = makeRowSlide()
        slide.fromValue = offset
        slide.toValue = CGPoint.zero
        slide.isAdditive = true
        slideSequence &+= 1
        layer.add(slide, forKey: "listRowSlide\(slideSequence)")
    }

    /// Moves a row to its frame from a box of another height, the box
    /// growing or closing over what the row holds.
    ///
    /// For a row that enters at a seam: it stands there with no height, and
    /// travels to its frame while its box opens over it. The row's contents
    /// are laid out for the frame it is headed to throughout, so nothing in
    /// it moves; the box uncovers it.
    ///
    /// ``setRowFrame(_:on:animated:)`` slides a row and lets its size change
    /// at once, which is right for a row that was already showing. Here the
    /// size travels too, as a second additive spring beside the slide, with
    /// the same numbers: the row's lower edge then stays on the row sliding
    /// under it for the whole of the move.
    @MainActor
    func unfoldRow(to frame: CGRect, on view: ListRowView) {
        guard let layer = view.layer else {
            setRowFrame(frame, on: view, animated: false)
            return
        }
        let previousSize = layer.bounds.size
        setRowFrame(frame, on: view, animated: true)
        let closed = CGSize(
            width: previousSize.width - layer.bounds.width,
            height: previousSize.height - layer.bounds.height
        )
        guard closed != .zero else { return }
        let unfold = makeRowSlide(keyPath: "bounds.size")
        unfold.fromValue = closed
        unfold.toValue = CGSize.zero
        unfold.isAdditive = true
        slideSequence &+= 1
        layer.add(unfold, forKey: "listRowUnfold\(slideSequence)")
    }

    /// Closes a view over what it holds, down to nothing at `seamY`, on the
    /// spring a row slides on.
    ///
    /// For the picture of a row that left at a seam. The view keeps the
    /// frame it has: AppKit draws a view only while it has a size, and the
    /// picture is drawn after this returns. What closes is what the reader
    /// is shown, held where it lands until the caller takes the view away.
    ///
    /// Called inside the list's animation, as the rows' slides are added:
    /// an animation added there takes the group's timing on top of its own,
    /// and this one has to keep step with them.
    @MainActor
    func foldView(_ view: NSView, toSeamAt seamY: CGFloat) {
        guard let layer = view.layer else { return }
        let standing = view.frame
        let position = layer.position
        let size = layer.bounds.size
        // Where the layer would stand with the view closed at the seam,
        // read off the view rather than worked out from its anchor.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.frame = CGRect(x: standing.minX, y: seamY, width: standing.width, height: 0)
        let closedPosition = layer.position
        let closedSize = layer.bounds.size
        view.frame = standing
        CATransaction.commit()

        let slide = makeRowSlide()
        slide.fromValue = position
        slide.toValue = closedPosition
        let fold = makeRowSlide(keyPath: "bounds.size")
        fold.fromValue = size
        fold.toValue = closedSize
        for animation in [slide, fold] {
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }
        layer.add(slide, forKey: "listRowFoldPosition")
        layer.add(fold, forKey: "listRowFoldSize")
    }

    /// Whether a row cuts off what it draws past its box.
    @MainActor
    func rowClipsToBounds(_ view: ListRowView) -> Bool {
        view.layer?.masksToBounds ?? false
    }

    @MainActor
    func setRowClipsToBounds(_ clips: Bool, on view: ListRowView) {
        view.layer?.masksToBounds = clips
    }

#else
    #error("ListViewKit requires UIKit or AppKit")
#endif
