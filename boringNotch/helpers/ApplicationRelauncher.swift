//
//  ApplicationRelauncher.swift
//  boringNotch
//
//  Created by Corentin132 on 03/10/2025.
//

import AppKit

@MainActor
enum ApplicationRelauncher {
    static func restart() {
        let workspace = NSWorkspace.shared
        let applicationURL = Bundle.main.bundleURL

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        workspace.openApplication(at: applicationURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    NSLog("Failed to relaunch NotSoBoringNotch at %@: %@", applicationURL.path, error.localizedDescription)
                    return
                }

                NSApplication.shared.terminate(nil)
            }
        }
    }
}
