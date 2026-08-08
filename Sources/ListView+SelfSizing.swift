//
//  ListView+SelfSizing.swift
//  ListViewKit
//

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#else
    #error("ListViewKit requires UIKit or AppKit")
#endif

extension ListView {
    /// Measures a row from its own Auto Layout constraints, for registrations
    /// declared without a height closure.
    ///
    /// Auto Layout runs on one hidden prototype per row type, never on a
    /// displayed row. Displayed rows stay frame-driven, so the constraint
    /// solver never scales with the number of rows on screen — only with how
    /// many rows are being measured, which the slice budget already bounds.
    func selfSizingHeight(
        for item: Item,
        registrationIndex: Int,
        context: ListRowContext
    ) -> CGFloat {
        let prototype = prototype(for: registrationIndex)
        prototype.width.constant = context.width
        prototype.view.prepareForReuse()
        registration(registrationIndex).configure(prototype.view, item, context)

        #if canImport(UIKit)
            prototype.view.setNeedsLayout()
            prototype.view.layoutIfNeeded()
            return prototype.view.systemLayoutSizeFitting(
                CGSize(width: context.width, height: 0),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
        #elseif canImport(AppKit)
            prototype.view.needsLayout = true
            prototype.view.layoutSubtreeIfNeeded()
            return prototype.view.fittingSize.height
        #endif
    }
}
