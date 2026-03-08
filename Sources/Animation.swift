//
//  Created by ktiays on 2025/1/16.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

#if canImport(UIKit)
    import UIKit

    @MainActor
    func withListAnimation(_ animation: @escaping () -> Void, completion: (@Sendable (Bool) -> Void)? = nil) {
        UIView.animate(
            withDuration: 0.5,
            delay: 0,
            usingSpringWithDamping: 0.85,
            initialSpringVelocity: 0.85,
            options: .allowUserInteraction,
            animations: animation,
            completion: completion
        )
    }

#elseif canImport(AppKit)
    import AppKit

    @MainActor
    func withListAnimation(_ animation: @escaping () -> Void, completion: (@Sendable (Bool) -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation()
        } completionHandler: {
            completion?(true)
        }
    }

#else
    #error("ListViewKit requires UIKit or AppKit")
#endif
