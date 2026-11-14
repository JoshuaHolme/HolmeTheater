// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// One of the hero's round icon buttons. On tvOS it grows into a pill showing its name while it has focus; elsewhere it
/// stays a round icon, with the name for VoiceOver.
struct FocusExpandingIconButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let font: Font
    var iconColor: Color?
    let action: () -> Void

    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    init(_ title: LocalizedStringKey, systemImage: String, font: Font, iconColor: Color? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.font = font
        self.iconColor = iconColor
        self.action = action
    }

    var body: some View {
        #if os(tvOS)
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(font)
                    .foregroundStyle(iconColor.map(AnyShapeStyle.init) ?? AnyShapeStyle(.foreground))
                if isFocused {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .buttonStyle(.bordered)
        // A circle at rest, a pill once there's a name beside the icon.
        .buttonBorderShape(isFocused ? .capsule : .circle)
        .focused($isFocused)
        .animation(.easeOut(duration: 0.2), value: isFocused)
        .accessibilityLabel(title)
        #else
        Button(action: action) {
            Image(systemName: systemImage)
                .font(font)
                .foregroundStyle(iconColor.map(AnyShapeStyle.init) ?? AnyShapeStyle(.foreground))
        }
        .heroCircleButton()
        .accessibilityLabel(title)
        #endif
    }
}

extension View {
    /// The look of the hero's round icon buttons: Liquid Glass on iOS, and the standard bordered circle on tvOS, where
    /// a glass button is drawn all the time rather than only when it has focus.
    @ViewBuilder
    func heroCircleButton() -> some View {
        #if os(tvOS)
        buttonStyle(.bordered)
            .buttonBorderShape(.circle)
        #else
        buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
        #endif
    }
}
