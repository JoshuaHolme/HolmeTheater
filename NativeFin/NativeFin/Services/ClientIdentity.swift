// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// How this app identifies itself to a Jellyfin server (shown in the server's device list).
nonisolated struct ClientIdentity: Sendable {
    /// The app's name.
    let name: String
    /// The app's marketing version.
    let version: String
    /// A human-readable name for this device, e.g. "Josh's iPhone".
    let deviceName: String
    /// Stable per install so the server doesn't accumulate duplicate devices.
    let deviceID: String

    /// The identity for the current install, generating and persisting a device ID on first use.
    ///
    /// Reads UIKit state, so it has to run on the main actor.
    @MainActor
    static func current() -> ClientIdentity {
        let defaults = UserDefaults.standard
        let deviceIDKey = "ClientIdentity.deviceID"
        let deviceID = defaults.string(forKey: deviceIDKey) ?? {
            let new = UUID().uuidString
            defaults.set(new, forKey: deviceIDKey)
            return new
        }()

        #if canImport(UIKit)
        let deviceName = UIDevice.current.name
        #else
        let deviceName = ProcessInfo.processInfo.hostName
        #endif

        return ClientIdentity(
            name: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Jellyfin Client",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            deviceName: deviceName,
            deviceID: deviceID
        )
    }
}
