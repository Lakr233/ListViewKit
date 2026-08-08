//
//  Created by ktiays on 2025/1/14.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

#if canImport(UIKit)
    import UIKit

    /// Base class for a row.
    ///
    /// The list owns a row's frame and never reads its intrinsic size, so a
    /// row does not need Auto Layout. Using it inside the row is fine — the
    /// list hands over a definite `bounds` to lay out within. A row type
    /// registered without a height closure is measured from those constraints
    /// instead, on a hidden prototype.
    open class ListRowView: UIView {
        /// Called before this row is filled in, including the first time and
        /// including a row already on screen. Clear transient state here:
        /// text, images, menus, callbacks, in-flight requests. Must be
        /// idempotent.
        open func prepareForReuse() {}

        /// Runs `block` with the same animation the list uses.
        open func withAnimation(_ block: @escaping () -> Void) {
            withListAnimation(block)
        }

        override public init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
        }

        @available(*, unavailable)
        public required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func requestLayout() {
            setNeedsLayout()
        }
    }

#elseif canImport(AppKit)
    import AppKit

    /// Base class for a row.
    ///
    /// The list owns a row's frame and never reads its intrinsic size, so a
    /// row does not need Auto Layout. Using it inside the row is fine — the
    /// list hands over a definite `bounds` to lay out within. A row type
    /// registered without a height closure is measured from those constraints
    /// instead, on a hidden prototype.
    open class ListRowView: NSView {
        override open var isFlipped: Bool {
            true
        }

        /// Called before this row is filled in, including the first time and
        /// including a row already on screen. Clear transient state here:
        /// text, images, menus, callbacks, in-flight requests. Must be
        /// idempotent.
        override open func prepareForReuse() {
            super.prepareForReuse()
        }

        /// Runs `block` with the same animation the list uses.
        open func withAnimation(_ block: @escaping () -> Void) {
            withListAnimation(block)
        }

        override public init(frame: CGRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
        }

        @available(*, unavailable)
        public required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func requestLayout() {
            needsLayout = true
        }
    }

#else
    #error("ListViewKit requires UIKit or AppKit")
#endif
