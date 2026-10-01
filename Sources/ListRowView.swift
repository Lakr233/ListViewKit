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
        /// Where the list's geometry says this row belongs.
        ///
        /// A row animator displaces rows on top of their layout, and on UIKit
        /// it does so through the transform, which leaves `frame` undefined.
        /// This stays the layout truth either way: it is what the list
        /// compares against to decide whether a row moved, and what the
        /// overlap assertion reads. Rows are welcome to read it; only the list
        /// writes it.
        public internal(set) var placedFrame: CGRect = .zero

        /// Vertical displacement currently shown on top of ``placedFrame``.
        var presentationOffset: CGFloat = 0

        /// Which showing of an item this is. See ``ListRowView/beginMount()``.
        var mountID = 0

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

        func layoutNow() {
            layoutIfNeeded()
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

        /// Where the list's geometry says this row belongs.
        ///
        /// A row animator displaces rows on top of their layout. Here that
        /// lands on the frame, so this is what the displacement is measured
        /// from, what the list compares against to decide whether a row moved,
        /// and what the overlap assertion reads. Rows are welcome to read it;
        /// only the list writes it.
        public internal(set) var placedFrame: CGRect = .zero

        /// Vertical displacement currently shown on top of ``placedFrame``.
        var presentationOffset: CGFloat = 0

        /// Which showing of an item this is. See ``ListRowView/beginMount()``.
        var mountID = 0

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

        func layoutNow() {
            layoutSubtreeIfNeeded()
        }
    }

#else
    #error("ListViewKit requires UIKit or AppKit")
#endif

extension ListRowView {
    private static var lastMountID = 0

    /// Gives this row a new identity for the item it is about to show.
    ///
    /// An index names a slot, and an apply hands the slot to another item;
    /// the view itself is pooled and handed to another item too. Neither can
    /// key state that belongs to one item on screen — an animator's spring
    /// keyed either way would jump rows onto each other's springs — so the
    /// list stamps each mount instead, and the stamp lasts exactly as long
    /// as that item stays on this view.
    func beginMount() {
        Self.lastMountID &+= 1
        mountID = Self.lastMountID
    }
}
