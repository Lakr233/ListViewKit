//
//  Created by ktiays on 2025/1/14.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import UIKit

open class ListRowView: UIView {
    public var rowKind: (any Hashable)?
    public var contentView: UIView = .init()

    // called when this row is going to be used for a different item
    open func prepareForReuse() {}

    // called when a list view is moving
    // ideal for cancel context menu if presented before via long press gestures
    open func prepareForMove() {}

    override public init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(contentView)
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override open func layoutSubviews() {
        super.layoutSubviews()

        contentView.frame = bounds
    }
}
