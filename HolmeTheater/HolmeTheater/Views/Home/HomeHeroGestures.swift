// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// The platform input the Home hero carousel relies on: a sideways swipe on iPhone and iPad, and, on Apple TV, the
// invisible focus targets that turn the page back when the remote moves left from the hero's buttons.

#if !os(tvOS)
/// A sideways pan that only begins if the finger moves more across than up or down, and then runs alongside the page's
/// own scrolling. SwiftUI's drag gesture claims every drag that starts on it, vertical ones too, which would stop the
/// page from scrolling when a finger starts on the carousel.
struct HorizontalPan: UIGestureRecognizerRepresentable {
    /// Called with how far the finger has moved sideways, as it moves.
    let onChanged: (CGFloat) -> Void

    /// Called when the finger lifts, with how far it moved sideways and how fast it was moving, in points per second.
    let onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> HorizontalPanGestureRecognizer {
        let recognizer = HorizontalPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: HorizontalPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            onChanged(translation)
        case .ended:
            onEnded(translation, recognizer.velocity(in: recognizer.view).x)
        case .cancelled, .failed:
            onEnded(0, 0)
        default:
            break
        }
    }

    /// Lets the pan run at the same time as the page's scrolling.
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

/// A pan that gives up if the finger starts moving more up or down than across.
final class HorizontalPanGestureRecognizer: UIPanGestureRecognizer {
    private var start: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        start = touches.first?.location(in: view)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible, let start, let point = touches.first?.location(in: view) {
            let across = abs(point.x - start.x)
            let down = abs(point.y - start.y)
            // Decided once the finger has moved a little: a mostly vertical start is a scroll, not a swipe.
            if across + down > 8 {
                if down > across {
                    state = .failed
                    return
                }
            }
        }
        super.touchesMoved(touches, with: event)
    }
}
#endif

#if os(tvOS)
/// Two invisible focus targets just left of the carousel's buttons, which turn the page back when the remote moves left from
/// them, as the Apple TV app does, instead of letting focus fall through to the sidebar.
///
/// What a real Siri Remote does, which a simulated one doesn't: one swipe left is more than one move. Another follows 100 to
/// 300ms later. From a target with nothing to its left that move fails, and the tab view answers a failed move left by
/// sending focus to the sidebar, which is the flash. (UIKit doesn't ask anyone's permission for that: there's no
/// `shouldUpdateFocus` call to refuse.) Getting focus back to Play before the follow-on takes about 400ms, too slow.
///
/// So focus stays on the strip, and there is always a target to its left. Whichever target has focus is moved to the right
/// and the other to the left of it, so every move left succeeds, however many arrive. A move that lands on a target turns
/// the page back, but not twice within a short while, so a swipe's follow-on doesn't skip a page. Once the moves stop,
/// focus goes back to Play (right moves it there at once too).
///
/// At the first hero there's nothing to go back to, so the targets stop being focusable, after a moment's grace for the last
/// swipe's follow-on, and the next move goes on to the sidebar.
struct BackStandIn: UIViewRepresentable {
    let canGoBack: () -> Bool
    let onBack: () -> Void
    let onReturnFocus: () -> Void

    func makeUIView(context: Context) -> StandInStrip {
        StandInStrip()
    }

    func updateUIView(_ strip: StandInStrip, context: Context) {
        strip.configure(canGoBack: canGoBack, onBack: onBack, onReturnFocus: onReturnFocus)
    }

    /// What the targets share: the closures, and when things last happened.
    final class Shared {
        var canGoBack: () -> Bool = { false }
        var onBack: () -> Void = {}
        var onReturnFocus: () -> Void = {}
        var holdsFocus: () -> Bool = { false }
        var promote: (StandInView) -> Void = { _ in }
        var lastTurn = Date.distantPast
        var graceUntil = Date.distantPast
        var idleToken = 0
    }

    final class StandInStrip: UIView {
        private let shared = Shared()
        private let targets: [StandInView]

        /// The target on the right, which has focus or had it last; the other is to its left.
        private var front: StandInView

        override init(frame: CGRect) {
            let shared = shared
            let targets = [StandInView(shared: shared), StandInView(shared: shared)]
            self.targets = targets
            front = targets[0]
            super.init(frame: frame)
            targets.forEach(addSubview)
            shared.holdsFocus = { [weak self] in self?.targets.contains { $0.isFocused } ?? false }
            shared.promote = { [weak self] target in
                self?.front = target
                self?.setNeedsLayout()
                self?.layoutIfNeeded()
            }
        }

        required init?(coder: NSCoder) { nil }

        func configure(canGoBack: @escaping () -> Bool, onBack: @escaping () -> Void, onReturnFocus: @escaping () -> Void) {
            shared.canGoBack = canGoBack
            shared.onBack = onBack
            shared.onReturnFocus = onReturnFocus
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let width = bounds.width / 2
            for target in targets {
                let slot: CGFloat = target === front ? 1 : 0
                target.frame = CGRect(x: slot * width, y: 0, width: width, height: bounds.height)
            }
        }
    }

    final class StandInView: UIView {
        private let shared: Shared

        /// How long after the page turns that another move onto a target is taken for the same swipe's follow-on rather than
        /// another press.
        private static var swipeFollowOn: TimeInterval { 0.25 }

        /// How long after the last move onto a target focus goes back to Play, and how long a target stays focusable at the
        /// first hero (longer, so it's still there when this runs).
        private static var idleDelay: TimeInterval { 0.6 }
        private static var grace: TimeInterval { 0.9 }

        init(shared: Shared) {
            self.shared = shared
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        /// While there's an earlier hero to go back to, and just after the last move onto a target.
        override var canBecomeFocused: Bool { shared.canGoBack() || Date() < shared.graceUntil }

        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            guard context.nextFocusedItem === self else { return }

            let movedLeft = context.focusHeading.contains(.left)
            guard movedLeft else {
                // From the sidebar or a shelf, say: not where focus should rest. Straight to Play.
                Task { [shared] in shared.onReturnFocus() }
                return
            }

            shared.promote(self)
            shared.graceUntil = Date().addingTimeInterval(Self.grace)
            let now = Date()
            if now.timeIntervalSince(shared.lastTurn) > Self.swipeFollowOn {
                shared.lastTurn = now
                shared.onBack()
            }

            // Once the moves stop, focus goes back to Play.
            shared.idleToken += 1
            let token = shared.idleToken
            Task { [shared] in
                try? await Task.sleep(for: .seconds(Self.idleDelay))
                guard shared.idleToken == token, shared.holdsFocus() else { return }
                shared.onReturnFocus()
            }
        }
    }
}
#endif
