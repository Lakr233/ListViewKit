//
//  SoftSpring.swift
//  ListViewKit
//

import Foundation

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#else
    #error("ListViewKit requires UIKit or AppKit")
#endif

/// Box2D's soft constraint, which is the spring everything in this package
/// runs on: ``ListBouncyAnimator``'s attachments, because that is literally
/// what `UIDynamicAnimator` computes for a `UIAttachmentBehavior`, and the
/// programmatic scroll, so a scroll-to and a bounce-back are the same physics
/// as the rows chasing their slots.
///
/// The reduction to one dimension, with the anchor static and the mass
/// cancelled (the soft constraint's response is mass-free by construction,
/// which is why a frequency can be exposed instead of a stiffness):
///
///     k = ω²        d = 2ζω
///     γ = 1 / (h·(d + h·k))         β = h·k·γ
///     impulse = −(v + β·x) / (1 + γ)
///     v += impulse    x += h·v
///
/// Semi-implicit on purpose: the velocity the impulse produces is the
/// velocity the position integrates, which is the property that keeps Box2D
/// stable at any stiffness the knobs can express.
enum SoftConstraint {
    /// Advances one position/velocity pair toward `target` by one step of
    /// `deltaTime`. A zero or negative step is a frame that carries travel
    /// but no time, and moves nothing.
    static func step(
        position: inout CGFloat,
        velocity: inout CGFloat,
        towards target: CGFloat,
        angularFrequency omega: CGFloat,
        dampingRatio zeta: CGFloat,
        deltaTime: TimeInterval
    ) {
        let h = CGFloat(deltaTime)
        guard h > 0, omega > 0 else { return }
        let k = omega * omega
        let d = 2 * zeta * omega
        let gamma = 1 / (h * (d + h * k))
        let bias = h * k * gamma * (position - target)
        let impulse = -(velocity + bias) / (1 + gamma)
        velocity += impulse
        position += h * velocity
    }
}

/// One axis of a programmatic scroll: a value on a soft constraint toward a
/// retargetable destination, snapping once it is within `threshold` so the
/// animation has an end the caller can observe.
struct SoftSpring {
    /// Radians per second.
    var angularFrequency: Double
    var dampingRatio: CGFloat
    /// Inside this of the target, the value is the target.
    var threshold: CGFloat

    private(set) var value: CGFloat = 0
    private(set) var velocity: CGFloat = 0
    private(set) var target: CGFloat = 0

    /// Whether the value has arrived. Reported only after an update snapped
    /// it, so the frame that lands exactly on the target still gets drawn.
    private(set) var completed: Bool = true

    mutating func setCurrent(_ value: CGFloat, velocity: CGFloat) {
        self.value = value
        self.velocity = velocity
        completed = false
    }

    mutating func setTarget(_ target: CGFloat) {
        self.target = target
        completed = false
    }

    mutating func update(withDeltaTime deltaTime: TimeInterval) {
        SoftConstraint.step(
            position: &value,
            velocity: &velocity,
            towards: target,
            angularFrequency: CGFloat(angularFrequency),
            dampingRatio: dampingRatio,
            deltaTime: deltaTime
        )
        if abs(value - target) <= threshold {
            value = target
            velocity = 0
            completed = true
        }
    }
}

/// The pair of axes `contentOffset` needs. The call-site shape mirrors the
/// spring library this replaced, so the scrolling code reads unchanged.
struct SoftSpring2D {
    var x: SoftSpring
    var y: SoftSpring

    init(angularFrequency: Double, dampingRatio: CGFloat, threshold: CGFloat) {
        x = SoftSpring(angularFrequency: angularFrequency, dampingRatio: dampingRatio, threshold: threshold)
        y = SoftSpring(angularFrequency: angularFrequency, dampingRatio: dampingRatio, threshold: threshold)
    }

    var completed: Bool { x.completed && y.completed }

    mutating func setCurrent(_ value: CGPoint, vel: CGPoint) {
        x.setCurrent(value.x, velocity: vel.x)
        y.setCurrent(value.y, velocity: vel.y)
    }

    mutating func setTarget(_ target: CGPoint) {
        x.setTarget(target.x)
        y.setTarget(target.y)
    }

    mutating func update(withDeltaTime deltaTime: TimeInterval) {
        x.update(withDeltaTime: deltaTime)
        y.update(withDeltaTime: deltaTime)
    }
}
