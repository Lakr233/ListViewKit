//
//  Created by ktiays on 2025/1/16.
//  Copyright (c) 2025 ktiays. All rights reserved.
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

    /// Moves a row to its new frame inside ``withListAnimation``.
    ///
    /// UIView's block animations are additive: one arriving mid-flight adds its
    /// motion to whatever is already running instead of replacing it, so the
    /// row carries its speed through the interruption. Setting the frame is the
    /// whole job here — the AppKit side has to build that behaviour by hand.
    @MainActor
    func setRowFrame(_ frame: CGRect, on view: ListRowView) {
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

    /// Distinguishes overlapping slides on one layer. Reusing a key would evict
    /// the very animation the next one is meant to continue from.
    @MainActor
    private var slideSequence = 0

    /// Moves a row to its new frame, adding the slide to whatever is already in
    /// flight rather than replacing it.
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
    func setRowFrame(_ frame: CGRect, on view: ListRowView) {
        guard let layer = view.layer, NSAnimationContext.current.allowsImplicitAnimation else {
            view.frame = frame
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
