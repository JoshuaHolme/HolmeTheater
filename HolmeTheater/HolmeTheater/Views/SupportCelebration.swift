// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The thank-you after a tip: popcorn raining down over a popcorn bucket and a message naming the snack. It stays until
/// the user closes it with the X button (or Menu, on Apple TV), so it can't be missed. A stray tap elsewhere does nothing.
///
/// The particles draw nothing with Reduce Motion on, which leaves the bucket and the message.
struct SupportCelebration: View {
    let tip: SupportStore.Tip
    let dismiss: () -> Void

    /// About what a system alert's corners are on iOS (Apple doesn't publish it), and larger for the bigger Apple TV screen.
    #if os(tvOS)
    private static let cornerRadius: CGFloat = 36
    #else
    private static let cornerRadius: CGFloat = 26
    #endif

    @State private var isShowing = false
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()

            ThemeParticles(effect: .concessions, layer: .back)
            VStack(spacing: 20) {
                PopcornBucket()
                    .frame(width: 140, height: 140)
                    .scaleEffect(isShowing ? 1 : 0.3)
                Text("Thanks for the \(tip.snackName)!")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text("You're helping keep the projector running.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(36)
            .glassEffect(.regular, in: .rect(cornerRadius: Self.cornerRadius, style: .continuous))
            #if !os(tvOS)
            .overlay(alignment: .topTrailing) {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .padding(12)
                .accessibilityLabel("Close")
            }
            #endif
            .padding(40)
            ThemeParticles(effect: .concessions, layer: .front)
        }
        .opacity(isShowing ? 1 : 0)
        // Covers the screen, so taps don't reach what's underneath, and don't close it either.
        .contentShape(Rectangle())
        .onTapGesture {}
        #if os(tvOS)
        // Takes focus so nothing underneath can have it, and so Menu reaches onExitCommand instead of leaving the page.
        .focusable()
        .focused($isFocused)
        .onExitCommand(perform: dismiss)
        #else
        .sensoryFeedback(.success, trigger: isShowing)
        #endif
        .accessibilityAddTraits(.isModal)
        .onAppear {
            withAnimation(.spring(duration: 0.5)) { isShowing = true }
            #if os(tvOS)
            isFocused = true
            #endif
        }
    }
}

extension View {
    /// Shows the thank-you over the screen whenever a tip has just been bought.
    func supportCelebration() -> some View {
        modifier(SupportCelebrationModifier())
    }
}

private struct SupportCelebrationModifier: ViewModifier {
    @Environment(AppModel.self) private var appModel

    func body(content: Content) -> some View {
        content
            // Nothing underneath can be used (or focused, on Apple TV) until the thank-you is closed.
            .disabled(appModel.support.celebratedTip != nil)
            .overlay {
            if let tip = appModel.support.celebratedTip {
                SupportCelebration(tip: tip) {
                    withAnimation { appModel.support.celebratedTip = nil }
                }
                .transition(.opacity)
            }
        }
    }
}
