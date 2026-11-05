// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Writes a line to the console, prefixed `FOCUSLOG` with the time to the millisecond, for finding out what the focus engine
/// does on a real Apple TV. Does nothing in a release build, or anywhere but tvOS.
///
/// To use it: run a debug build on the TV from Xcode, reproduce the problem, then filter the console for `FOCUSLOG`.
func focusLog(_ message: @autoclosure () -> String) {
    #if os(tvOS) && DEBUG
    FocusDebug.log(message())
    #endif
}

/// Starts logging every focus move the system makes (see `FocusDebug`), with `state` describing the screen on each line.
/// Does nothing in a release build, or anywhere but tvOS.
func startFocusLogging(state: @escaping () -> String) {
    #if os(tvOS)
    FocusDebug.stateProvider = state
    FocusDebug.start()
    #endif
}

#if os(tvOS)
/// Logs every focus move the system makes, and every one it fails to make, whichever view they involve, so the sequence of
/// events around the sidebar opening can be read back in order.
enum FocusDebug {
    private static var started = false

    /// Describes the screen's state (which hero is showing, what has focus) for each line the system logs. Set by the carousel.
    nonisolated(unsafe) static var stateProvider: (() -> String)?

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func log(_ message: String) {
        #if DEBUG
        print("FOCUSLOG \(formatter.string(from: Date())) \(message)")
        #endif
    }

    /// Starts logging the system's focus moves. Safe to call more than once.
    static func start() {
        #if DEBUG
        guard !started else { return }
        started = true
        log("logging started")

        NotificationCenter.default.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { note in
            guard let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext else { return }
            log("MOVED   \(heading(context.focusHeading)): \(describe(context.previouslyFocusedItem))  ->  \(describe(context.nextFocusedItem))  [\(stateProvider?() ?? "")]")
        }
        NotificationCenter.default.addObserver(forName: UIFocusSystem.movementDidFailNotification, object: nil, queue: .main) { note in
            guard let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext else { return }
            log("FAILED  \(heading(context.focusHeading)) from \(describe(context.previouslyFocusedItem))  [\(stateProvider?() ?? "")]")
        }
        #endif
    }

    static func heading(_ heading: UIFocusHeading) -> String {
        var names: [String] = []
        if heading.contains(.up) { names.append("up") }
        if heading.contains(.down) { names.append("down") }
        if heading.contains(.left) { names.append("left") }
        if heading.contains(.right) { names.append("right") }
        if heading.contains(.next) { names.append("next") }
        if heading.contains(.previous) { names.append("previous") }
        return names.isEmpty ? "none" : names.joined(separator: "+")
    }

    /// A short description of a focus item: what it is, its label if it has one, and where it is.
    static func describe(_ item: UIFocusItem?) -> String {
        guard let item else { return "nil" }
        let name = String(describing: type(of: item)).prefix(36)
        let label = (item as? NSObject)?.accessibilityLabel.map { " '\($0)'" } ?? ""
        return "\(name)\(label) \(NSCoder.string(for: item.frame))"
    }
}
#endif
