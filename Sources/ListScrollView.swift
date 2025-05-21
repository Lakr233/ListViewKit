//
//  Created by ktiays on 2025/2/18.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import UIKit

open class ListScrollView: UIScrollView {
    struct SpringBack {
        var lambda: Double
        var c1: Double
        var c2: Double

        init(initialVelocity velocity: Double, distance: Double) {
            lambda = 2 * .pi / 0.575
            c1 = distance
            c2 = velocity * 1e3 + lambda * distance
        }

        func velocity(at time: Double) -> Double {
            (c2 - lambda * (c1 + c2 * time)) * exp(-lambda * time) / 1e3
        }

        func value(at time: Double) -> Double? {
            let offset = (c1 + c2 * time) * exp(-lambda * time)
            let velocity = velocity(at: time)
            if abs(offset) < 0.1, abs(velocity) < 1e-2 {
                return nil
            } else {
                return offset
            }
        }
    }

    struct ScrollingProperty {
        var target: CGFloat
        var springBack: SpringBack
        let startTime = CACurrentMediaTime()

        var isFinished: Bool = false

        init?(target: CGFloat, current: CGFloat) {
            if target == current {
                return nil
            }
            self.target = target

            let distance = Double(target - current)
            springBack = .init(initialVelocity: -distance / 100, distance: distance)
        }

        mutating func value(at time: Double) -> CGFloat {
            if isFinished {
                return target
            }
            guard let value = springBack.value(at: time - startTime) else {
                isFinished = true
                return target
            }
            return target - value
        }
    }

    var scrollingDisplayLink: CADisplayLink?
    var xScrollingProperty: ScrollingProperty?
    var yScrollingProperty: ScrollingProperty?

    /// The minimum point (in content view coordinates) that the view can be scrolled.
    public var minimumContentOffset: CGPoint {
        .init(x: -adjustedContentInset.left, y: -adjustedContentInset.top)
    }

    /// The maximum point (in content view coordinates) that the view can be scrolled.
    public var maximumContentOffset: CGPoint {
        let min = minimumContentOffset
        return .init(
            x: max(min.x, contentSize.width - bounds.width + adjustedContentInset.right),
            y: max(min.y, contentSize.height - bounds.height + adjustedContentInset.bottom)
        )
    }

    /// Scrolls the position of the scroll view to the content offset you provide.
    public func scroll(to offset: CGPoint, animated: Bool = false) {
        if !animated {
            cancelCurrentScrolling()
            setContentOffset(offset, animated: false)
            return
        }

        var shouldScrolling = false
        let currentContentOffset = contentOffset
        if bounds.width > 0 {
            if var property = xScrollingProperty {
                property.target = offset.x
                xScrollingProperty = property
            } else {
                xScrollingProperty = .init(target: offset.x, current: currentContentOffset.x)
            }
            shouldScrolling = true
        }
        if bounds.height > 0 {
            if var property = yScrollingProperty {
                property.target = offset.y
                yScrollingProperty = property
            } else {
                yScrollingProperty = .init(target: offset.y, current: currentContentOffset.y)
            }
            shouldScrolling = true
        }

        if shouldScrolling, scrollingDisplayLink == nil {
            scrollingDisplayLink = CADisplayLink(target: self, selector: #selector(handleScrollingAnimation(_:)))
            if #available(iOS 15.0, macCatalyst 15.0, *) {
                scrollingDisplayLink?.preferredFrameRateRange = .init(minimum: 60, maximum: 120, preferred: 120)
            }
            scrollingDisplayLink?.add(to: .main, forMode: .common)
        }
    }

    /// Cancels any current scrolling animations.
    func cancelCurrentScrolling() {
        xScrollingProperty = nil
        yScrollingProperty = nil
        scrollingDisplayLink?.invalidate()
        scrollingDisplayLink = nil
    }

    @objc
    func handleScrollingAnimation(_ sender: CADisplayLink) {
        if isTracking || (xScrollingProperty == nil && yScrollingProperty == nil) {
            // No animation is currently in progress,
            // releasing the display link.
            sender.invalidate()
            scrollingDisplayLink = nil
            return
        }

        func clamp<T>(_ value: T, min: T, max: T, clamped: inout Bool) -> T where T: Comparable {
            clamped = value < min || value > max
            return Swift.min(Swift.max(value, min), max)
        }

        let time = CACurrentMediaTime()
        var targetContentOffset = contentOffset
        let min = minimumContentOffset
        let max = maximumContentOffset
        if var property = xScrollingProperty {
            defer {
                if property.isFinished {
                    xScrollingProperty = nil
                } else {
                    xScrollingProperty = property
                }
            }
            var x = property.value(at: time)
            var isClamped = false
            x = clamp(x, min: min.x, max: max.x, clamped: &isClamped)
            if isClamped {
                property.isFinished = true
            }
            targetContentOffset.x = x
        }
        if var property = yScrollingProperty {
            defer {
                if property.isFinished {
                    yScrollingProperty = nil
                } else {
                    yScrollingProperty = property
                }
            }
            var y = property.value(at: time)
            var isClamped = false
            y = clamp(y, min: min.y, max: max.y, clamped: &isClamped)
            if isClamped {
                property.isFinished = true
            }
            targetContentOffset.y = y
        }

        setContentOffset(targetContentOffset, animated: false)
    }
}
