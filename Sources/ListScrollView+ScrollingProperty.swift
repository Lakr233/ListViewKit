//
//  ListScrollView+ScrollingProperty.swift
//  ListViewKit
//
//  Created by 秋星桥 on 5/22/25.
//

import Foundation
import SpringInterpolation
import UIKit

extension ListScrollView {
    struct ScrollAnimationContext {
        var engine: SpringInterpolation = .init()

        var target: CGFloat {
            get { engine.context.targetPos }
            set { engine.context.targetPos = newValue }
        }

        var isFinished: Bool {
            engine.completed
        }
    }
}
