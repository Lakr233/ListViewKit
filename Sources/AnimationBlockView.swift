//
//  AnimationBlockView.swift
//  ListViewKit
//
//  Created by qaq on 9/12/2025.
//

import Foundation
import MSDisplayLink
import SpringInterpolation
import UIKit

open class AnimationBlockView: UIView {
    public let subview: UIView
    public let displayLink: DisplayLink = .init()

    open var heightAnimator: SpringInterpolation?
    open var previousConstraint: NSLayoutConstraint?

    public init(install subview: UIView) {
        self.subview = subview
        super.init(frame: .zero)
        displayLink.delegatingObject(self)
        addSubview(subview)
        subview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: topAnchor),
            subview.leftAnchor.constraint(equalTo: leftAnchor),
            subview.rightAnchor.constraint(equalTo: rightAnchor),
        ])
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError()
    }

    override open var frame: CGRect {
        set {
            let oldValue = super.frame
            super.frame = newValue
            if oldValue != newValue { scheduleHeightUpdate() }
        }
        get {
            super.frame
        }
    }

    private var previousLayoutFrame: CGRect = .zero
    override open func layoutSubviews() {
        super.layoutSubviews()
        if previousLayoutFrame != frame {
            previousLayoutFrame = frame
            scheduleHeightUpdate()
        }
    }

    open func scheduleHeightUpdate() {
        if heightAnimator == nil {
            heightAnimator = .init(config: .init(
                angularFrequency: 10,
                dampingRatio: 1,
                threshold: 1,
                stopWhenHitTarget: true
            ))
            if subview.frame.height == 0 { // forgive the first layout
                heightAnimator?.setTarget(bounds.height)
                heightAnimator?.setCurrent(bounds.height)
            }
        } else {
            heightAnimator?.setTarget(bounds.height)
        }
        animationTik()
    }

    open func animationTik(delta: TimeInterval = 0) {
        if delta > 0 { heightAnimator?.update(withDeltaTime: delta) }
        guard let height = heightAnimator?.value else { return }
        if let previousConstraint { previousConstraint.isActive = false }
        UIView.performWithoutAnimation {
            let constraint = subview.heightAnchor.constraint(equalToConstant: height)
            constraint.isActive = true
            previousConstraint = constraint
            layoutIfNeeded()
        }
    }
}

extension AnimationBlockView: DisplayLinkDelegate {
    public func synchronization(context: DisplayLinkCallbackContext) {
        animationTik(delta: context.duration)
    }
}
