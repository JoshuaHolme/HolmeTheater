// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI
import UIKit

extension View {
    /// Makes a card tappable, and long-pressable for a peek and menu where tapping the peek opens the item,
    /// the same as tapping the card ("peek and pop").
    ///
    /// SwiftUI's `contextMenu(menuItems:preview:)` can show a preview, but tapping it only dismisses it, with
    /// no way to run an action. UIKit's context menu interaction can commit ("pop") on a preview tap, so this
    /// lays a transparent UIKit view over the card to drive that interaction. The card itself stays plain
    /// SwiftUI, so its layout is unaffected; the owner navigates in `onOpen`.
    ///
    /// - Parameters:
    ///   - menu: The long-press menu's entries.
    ///   - accessibilityLabel: What VoiceOver reads for the card.
    ///   - onOpen: Called when the card is tapped, or its preview is tapped.
    ///   - peek: The preview shown above the menu.
    func peekAndPop<Peek: View>(
        menu: [ItemMenuEntry],
        accessibilityLabel: String,
        onOpen: @escaping () -> Void,
        @ViewBuilder peek: () -> Peek
    ) -> some View {
        // The overlay is the one accessibility element, so VoiceOver doesn't read the card twice.
        accessibilityHidden(true)
            .overlay {
                PeekInteractionView(menu: menu, accessibilityLabel: accessibilityLabel, onOpen: onOpen, peek: peek())
            }
    }
}

/// The transparent UIKit layer behind `peekAndPop`.
private struct PeekInteractionView<Peek: View>: UIViewRepresentable {
    let menu: [ItemMenuEntry]
    let accessibilityLabel: String
    let onOpen: () -> Void
    let peek: Peek

    func makeUIView(context: Context) -> PeekUIView<Peek> {
        PeekUIView(peek: peek)
    }

    func updateUIView(_ view: PeekUIView<Peek>, context: Context) {
        view.update(peek: peek, menu: menu, accessibilityLabel: accessibilityLabel, onOpen: onOpen)
    }
}

/// A clear view with a tap and a context menu interaction. See `peekAndPop`.
private final class PeekUIView<Peek: View>: UIView, UIContextMenuInteractionDelegate {
    /// How wide a peek is; `ItemPeek` lays itself out at this width.
    private static var peekWidth: CGFloat { 320 }

    private var peek: Peek
    private var menu: [ItemMenuEntry] = []
    private var onOpen: () -> Void = {}

    init(peek: Peek) {
        self.peek = peek
        super.init(frame: .zero)

        backgroundColor = .clear
        addInteraction(UIContextMenuInteraction(delegate: self))
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Takes the latest peek, menu and actions from SwiftUI, which rebuilds them on every state change.
    func update(peek: Peek, menu: [ItemMenuEntry], accessibilityLabel: String, onOpen: @escaping () -> Void) {
        self.peek = peek
        self.menu = menu
        self.onOpen = onOpen

        self.accessibilityLabel = accessibilityLabel
        // Give VoiceOver users the menu's actions too, since it has no long-press.
        accessibilityCustomActions = menu.flattened.map { entry in
            UIAccessibilityCustomAction(name: entry.title) { _ in
                entry.perform?()
                return true
            }
        }
    }

    override func accessibilityActivate() -> Bool {
        onOpen()
        return true
    }

    @objc private func tapped() {
        onOpen()
    }

    // MARK: UIContextMenuInteractionDelegate

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(
            identifier: nil,
            previewProvider: { [weak self] in self?.makePeekController() },
            actionProvider: { [weak self] _ in
                guard let self else { return nil }
                return UIMenu(children: self.menu.map(menuElement(for:)))
            }
        )
    }

    /// Tapping the preview commits: it animates away and the item opens.
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration, animator: any UIContextMenuInteractionCommitAnimating) {
        animator.preferredCommitStyle = .pop
        animator.addCompletion { [weak self] in
            self?.onOpen()
        }
    }

    /// Lifts the card as it looks on screen. This view is clear, so the card is a snapshot of the window
    /// behind it; if that isn't available the system lifts this view, which just shows no lift.
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let window, let snapshot = window.resizableSnapshotView(
            from: convert(bounds, to: window),
            afterScreenUpdates: false,
            withCapInsets: .zero
        ) else { return nil }

        snapshot.layer.cornerRadius = 8
        snapshot.layer.masksToBounds = true

        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        let center = window.convert(CGPoint(x: bounds.midX, y: bounds.midY), from: self)
        return UITargetedPreview(view: snapshot, parameters: parameters, target: UIPreviewTarget(container: window, center: center))
    }

    private func makePeekController() -> UIViewController {
        let controller = UIHostingController(rootView: peek)
        controller.view.backgroundColor = .systemBackground
        controller.preferredContentSize = controller.sizeThatFits(
            in: CGSize(width: Self.peekWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        return controller
    }
}

/// A menu entry as UIKit's menu element: an action, or a submenu if it has children.
private func menuElement(for entry: ItemMenuEntry) -> UIMenuElement {
    let image = UIImage(systemName: entry.systemImage)
    if entry.children.isEmpty {
        return UIAction(title: entry.title, image: image) { _ in entry.perform?() }
    }
    return UIMenu(title: entry.title, image: image, children: entry.children.map(menuElement(for:)))
}

private extension Array where Element == ItemMenuEntry {
    /// The entries that do something, with submenus expanded into their items.
    var flattened: [ItemMenuEntry] {
        flatMap { $0.children.isEmpty ? [$0] : $0.children.flattened }
    }
}
#endif
