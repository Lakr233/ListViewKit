//
//  Created by ktiays on 2025/1/16.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import UIKit

func withListAnimation(_ animation: @escaping () -> Void, completion: ((Bool) -> Void)? = nil) {
    UIView.animate(
        withDuration: 0.5,
        delay: 0,
        usingSpringWithDamping: 0.86,
        initialSpringVelocity: 0,
        options: .allowUserInteraction,
        animations: animation,
        completion: completion
    )
}
