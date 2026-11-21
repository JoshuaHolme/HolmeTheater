// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import WidgetKit
import SwiftUI

/// The widget extension's entry point. Its only widget is the Live Activity that shows download progress.
@main
struct DownloadActivityBundle: WidgetBundle {
    var body: some Widget {
        DownloadActivity()
    }
}
