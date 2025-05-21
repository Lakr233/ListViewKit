//
//  Created by ktiays on 2025/1/14.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import UIKit

open class ListRowView: UIView {
    public var rowKind: (any Hashable)?
    public var contentView: UIView = .init()

    open func prepareForReuse() {}

    override public init(frame: CGRect) {
        super.init(frame: frame)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.autoresizingMask = []
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
