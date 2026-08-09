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
    @MainActor
    func setRowFrame(_ frame: CGRect, on view: ListRowView, animated: Bool) {
        guard animated else {
            placeView(frame, on: view)
            return
        }
        view.frame = frame
    }

#elseif canImport(AppKit)
    import AppKit

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
    @MainActor
    func setRowFrame(_ frame: CGRect, on view: ListRowView, animated: Bool) {
        guard animated, let layer = view.layer else {
            placeView(frame, on: view)
            return
        }
        let previousPosition = layer.position
        // The frame moves outright; the slide below is what the reader sees.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.frame = frame
        CATransaction.commit()

        let offset = CGPoint(
            x: previousPosition.x - layer.position.x,
            y: previousPosition.y - layer.position.y
        )
        guard offset != .zero else { return }
        let slide = CASpringAnimation(perceptualDuration: listAnimationDuration, bounce: 0)
        slide.keyPath = "position"
        slide.fromValue = offset
        slide.toValue = CGPoint.zero
        slide.isAdditive = true
        slide.duration = slide.settlingDuration
        slideSequence &+= 1
        layer.add(slide, forKey: "listRowSlide\(slideSequence)")
    }

#else
    #error("ListViewKit requires UIKit or AppKit")
#endif
