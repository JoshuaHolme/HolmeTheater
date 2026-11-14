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
    /// A human-readable name for this device: the one its owner gave it where the system shares that (e.g. "Living
    /// Room"), otherwise its model and a short tag for this install (e.g. "iPhone (3F2A)").
    let deviceName: String
    /// Stable per install so the server doesn't accumulate duplicate devices.
    let deviceID: String

    /// Returns the identity for the current install, generating and saving a device ID on first use.
    ///
    /// This reads UIKit state, so it has to run on the main actor.
    ///
    /// - Returns: The app's name and version, this device's name, and its persistent device ID.
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
        // Since iOS 16 the name the user gave the device is only readable with an entitlement Apple grants on request;
        // without it, this is just the model ("iPhone"). Every iPhone in the house would then look the same in the
        // server's list of devices, so a generic name gets the start of this install's ID to tell them apart.
        let device = UIDevice.current
        let deviceName = device.name == device.model ? "\(device.model) (\(deviceID.prefix(4)))" : device.name
        #else
        let deviceName = ProcessInfo.processInfo.hostName
        #endif

        return ClientIdentity(
            // The name people see ("Holme Theater"), which the server shows in its list of devices, rather than the
            // bundle name, which has no space.
            name: (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName")
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName")) as? String ?? "Jellyfin Client",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            deviceName: deviceName,
            deviceID: deviceID
        )
    }
}
