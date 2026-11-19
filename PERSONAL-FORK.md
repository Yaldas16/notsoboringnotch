# Boring Notch Personal

The fork starts at Boring Notch `v2.8-rc.2` (`1fa326d56b6ae7165afea934282449892e0b8164`) and retains the upstream GPL-3.0 license and third-party notices. The source Xcode marketing version at that tag is `2.8-beta.0`. Upstream stamps release versions in its publication pipeline.

## Build and install

Push the personal branch under `personal-fork/` to trigger **Build Boring Notch Personal**. The workflow uses an arm64 macOS 26 runner, Xcode 26.6 and the Swift package lockfile. It builds the Release app, verifies the extracted ZIP and runs the existing hosted macOS tests in Debug. Artifacts expire after 14 days and are accessible to signed-in users with read access to the repository.

1. Open the run for the desired commit in the fork's [Actions tab](../../actions), then download **Boring-Notch-Personal-arm64** from its Artifacts section. Extract the Actions download and open the inner `Boring-Notch-Personal-arm64.zip`.
2. Quit any running Boring Notch instance during testing, then drag **Boring Notch Personal.app** to Applications. Open it through Finder and complete onboarding. The official app can stay installed under its own name.
3. The CI build uses ad-hoc signing. If macOS blocks this trusted build, use the app-specific **Open Anyway** option in **System Settings → Privacy & Security** if available. A Mac with a policy that disallows this exception needs a build signed and notarized with appropriate Apple credentials.

## Real Mac checks

On the MacBook Air, finish onboarding, open Home and Shelf, and confirm a Shelf item and a changed preference survive a quit and relaunch. Confirm the official app's Shelf and preferences are still separate. Test media playback and controls with an installed player, calendar display, an incoming notification and brightness or volume controls after granting any requested permissions. Check Settings, the menu-bar restart command, login on next sign-in if enabled, and notch animations. Confirm About, onboarding and the menu bar offer no upstream updater controls.

The baseline uses an app sandbox, a separate accessibility/notification/OSD XPC helper, and the upstream prebuilt MediaRemote adapter. The adapter has arm64 and x86_64 slices. Signature and architecture checks establish bundle integrity. Permissions, MediaRemote loading, launch at login, and Gatekeeper behavior depend on the target Mac.

## Upstream updates

Fetch a specific upstream tag and integrate it on a new `personal-fork/` branch based on the current personal branch. Review the Xcode project, package lock, app and helper IDs, Shelf storage, relaunch and migration, and the personal workflow before pushing. Keep the official updater code, feeds and signing keys out of the app target and preserve the upstream-only workflow guards. Build and download the new artifact, then repeat the Mac checks before replacing the personal app in Applications. Keep the previous working ZIP for rollback.

## Integration notes

`BoringViewCoordinator.currentView` and `TabSelectionView` own tab selection. `ContentView` switches the open notch content and computes its height, while `BoringViewModel` and `NotchWindowManager` handle behavior and per-display windows. The next phase can add a mock GPT view through these points before adding any account or network code.
