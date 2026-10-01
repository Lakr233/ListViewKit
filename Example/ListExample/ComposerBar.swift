//
//  ComposerBar.swift
//  ListExample
//

import UIKit

/// The message field at the bottom of the screen: a capsule floating over
/// the list, so rows scroll on underneath it.
final class ComposerBar: UIView {
    static let height: CGFloat = 48

    /// Called with the trimmed text when the reader sends it.
    var onSend: ((String) -> Void)?

    let textField = UITextField()
    private let sendButton = UIButton(type: .system)
    private let background = UIVisualEffectView(effect: ComposerBar.backgroundEffect())

    override init(frame: CGRect) {
        super.init(frame: frame)

        background.clipsToBounds = true
        background.layer.cornerRadius = Self.height / 2
        background.layer.cornerCurve = .continuous
        addSubview(background)

        textField.placeholder = "Message"
        textField.font = .preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.returnKeyType = .send
        textField.enablesReturnKeyAutomatically = true
        textField.delegate = self
        textField.addTarget(self, action: #selector(textDidChange), for: .editingChanged)

        let symbol = UIImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        sendButton.setImage(UIImage(systemName: "arrow.up.circle.fill", withConfiguration: symbol), for: .normal)
        sendButton.accessibilityLabel = "Send"
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        sendButton.isEnabled = false

        let content = background.contentView
        content.addSubview(textField)
        content.addSubview(sendButton)

        for view in [background, textField, sendButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),

            textField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            textField.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            textField.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),

            sendButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            sendButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 34),
            sendButton.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    private static func backgroundEffect() -> UIVisualEffect {
        if #available(iOS 26, *) {
            let glass = UIGlassEffect()
            glass.isInteractive = true
            return glass
        }
        return UIBlurEffect(style: .systemChromeMaterial)
    }

    private var trimmedText: String {
        textField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    @objc private func textDidChange() {
        sendButton.isEnabled = !trimmedText.isEmpty
    }

    @objc private func send() {
        let text = trimmedText
        guard !text.isEmpty else { return }
        textField.text = nil
        textDidChange()
        onSend?(text)
    }
}

extension ComposerBar: UITextFieldDelegate {
    /// Sends and keeps the keyboard up, so an insertion can be watched while
    /// the list is resized around it.
    func textFieldShouldReturn(_: UITextField) -> Bool {
        send()
        return false
    }
}
