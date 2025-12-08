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

    // 按需启动的 DisplayLink，动画结束/离屏后释放，避免常驻占用帧回调
    private var displayLink: DisplayLink?

    open var heightAnimator: SpringInterpolation?
    private var heightConstraint: NSLayoutConstraint!

    public init(install subview: UIView) {
        self.subview = subview
        super.init(frame: .zero)
        addSubview(subview)
        subview.translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = subview.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate(
            [
                subview.topAnchor.constraint(equalTo: topAnchor),
                subview.leftAnchor.constraint(equalTo: leftAnchor),
                subview.rightAnchor.constraint(equalTo: rightAnchor),
                heightConstraint,
            ]
        )
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

    deinit { stopDisplayLink() }

    private var previousLayoutFrame: CGRect = .zero
    override open func layoutSubviews() {
        super.layoutSubviews()
        if previousLayoutFrame != frame {
            previousLayoutFrame = frame
            scheduleHeightUpdate()
        }
    }

    override open func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopDisplayLink() }
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }
        let link = DisplayLink()
        link.delegatingObject(self)
        displayLink = link
    }

    private func stopDisplayLinkIfIdle() {
        guard let animator = heightAnimator else {
            stopDisplayLink()
            return
        }
        if animator.completed { stopDisplayLink() }
    }

    private func stopDisplayLink() {
        displayLink?.delegatingObject(nil)
        displayLink = nil
    }

    open func scheduleHeightUpdate() {
        if heightAnimator == nil {
            heightAnimator = .init(config: .init(
                angularFrequency: 10,
                dampingRatio: 1,
                threshold: 1,
                stopWhenHitTarget: true
            ))
        }
        let targetHeight = Double(bounds.height)
        heightAnimator?.setTarget(targetHeight)
        if subview.frame.height == 0 {
            heightAnimator?.setCurrent(targetHeight)
        }
        if !(heightAnimator?.completed ?? true) { startDisplayLinkIfNeeded() }
        animationTik()
    }

    open func animationTik(delta: TimeInterval = 0) {
        if delta > 0 { heightAnimator?.update(withDeltaTime: delta) }
        guard let height = heightAnimator?.value else { return }
        UIView.performWithoutAnimation {
            heightConstraint.constant = CGFloat(height)
            layoutIfNeeded()
        }
        stopDisplayLinkIfIdle()
    }
}

extension AnimationBlockView: DisplayLinkDelegate {
    public func synchronization(context: DisplayLinkCallbackContext) {
        animationTik(delta: context.duration)
    }
}
