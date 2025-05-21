//
//  ListScrollView+ScrollingProperty.swift
//  ListViewKit
//
//  Created by 秋星桥 on 5/22/25.
//

import Foundation
import UIKit

extension ListScrollView {
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
            if isFinished { return target }
            guard let value = springBack.value(at: time - startTime) else {
                isFinished = true
                return target
            }
            return target - value
        }
    }
}
