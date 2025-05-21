//
//  ListScrollView+SpringBack.swift
//  ListViewKit
//
//  Created by 秋星桥 on 5/22/25.
//

import Foundation

extension ListScrollView {
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
}
