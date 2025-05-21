//
//  Created by ktiays on 2025/1/14.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import UIKit

/// The visual representation of a single row in a list view.
open class ListRowView: UIView {
    /// A Hashable for identifying a reusable row.
    public internal(set) var rowKind: (any Hashable)?

    /// The content view of the row view.
    public private(set) var contentView: UIView = .init()

    /// Prepares a reusable row for reuse by the list view's delegate.
    open func prepareForReuse() {}

    var _contextMenuInteractionCallback: ((UIContextMenuInteraction, CGPoint) -> Void)?

    override public init(frame: CGRect) {
        super.init(frame: frame)

        let contextMenuInteraction = UIContextMenuInteraction(delegate: self)
        contentView.addInteraction(contextMenuInteraction)
        addSubview(contentView)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPress.minimumPressDuration = 0.25
        longPress.allowableMovement = 8
        contentView.addGestureRecognizer(longPress)
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override open func layoutSubviews() {
        super.layoutSubviews()

        contentView.frame = bounds
    }

    public func withAnimation(_ animation: @escaping () -> Void, completion: ((Bool) -> Void)? = nil) {
        guard window != nil, frame != .zero else {
            animation()
            completion?(true)
            return
        }
        withListAnimation(animation, completion: completion)
    }

    @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let location = gesture.location(in: contentView)
        _contextMenuInteractionCallback?(.init(delegate: self), location)
    }
}

extension ListRowView: UIContextMenuInteractionDelegate {
    public func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        _contextMenuInteractionCallback?(interaction, location)
        return nil
    }
}
