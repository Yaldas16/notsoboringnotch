# NotSoBoringNotch

NotSoBoringNotch is an unofficial fork of [Boring Notch](https://github.com/TheBoredTeam/boring.notch) that brings ChatGPT to the macOS notch. It keeps the original music controls, calendar, mirror, Shelf, notification features, and system overlays alongside a native GPT tab. This independent fork has no affiliation with or endorsement from OpenAI or The Bored Team.

[Download for Apple Silicon](https://github.com/Yaldas16/boringnotch-gpt/releases/latest)

## Features

- **ChatGPT at the notch.** Sign in through OpenAI’s official [Sign in with ChatGPT](https://developers.openai.com/siwc/token-sharing-open-source) flow. Responses stream into a native conversation view with Markdown and code blocks. Open the same conversation in a resizable window when you need more space.
- **Ask GPT from other apps.** Select text in a compatible macOS app and choose **Services → Ask GPT**. Write your own question or use an editable suggestion to explain, summarize, rewrite, or translate. Choose a default language and search for translation targets.
- **Ask about images.** Attach an image, paste it, or drop it into the expanded chat. Choose **Select Screen Area…** from the GPT toolbar or the menu bar icon to add a region of your screen to the draft. Review the attachment before sending.
- **Temporary conversations.** The app holds chats and drafts in memory and clears them when you start a new chat or quit. Sign-in credentials are stored separately in macOS Keychain.

## Install

The downloadable builds require an **Apple Silicon Mac** with **macOS 14 Sonoma or later**. **Select Screen Area** requires **macOS 15.2 or later**.

1. Download the DMG from [GitHub Releases](https://github.com/Yaldas16/boringnotch-gpt/releases/latest).
2. Open the DMG and drag **NotSoBoringNotch.app** onto **Applications**.
3. Eject the installer and open **NotSoBoringNotch** from **Applications**. The ZIP contains the same app for manual installation.
4. Open the GPT tab or **GPT Chat…** from the menu bar, then choose **Continue with ChatGPT**.

The downloadable app is ad hoc–signed and has no Apple notarization ticket. Gatekeeper may block it on first launch. Verify the download against the release’s `SHA256SUMS.txt` and follow [Apple’s guidance for opening an unnotarized app](https://support.apple.com/en-us/102445) if you choose to trust it. A managed Mac may prohibit this exception.

## Permissions and limits

- **Ask GPT** uses macOS Services and requires no Accessibility access. If the command is missing, check **System Settings → Keyboard → Keyboard Shortcuts → Services**. NotSoBoringNotch also has an app-side toggle in **Settings → GPT**.
- **Select Screen Area** requires macOS Screen Recording permission. The app captures only the area you choose. Selected text and attached images are sent to OpenAI when you submit the question.
- Optional notch features may request camera, calendar, reminders, audio, Accessibility, or Automation permissions as needed.
- ChatGPT access depends on the account, workspace, model, and OpenAI’s [preview limits](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations). Image input requires a compatible model. The app uses OpenAI’s ChatGPT plan integration with no API-key billing fallback. It keeps no local conversation history and leaves ChatGPT’s own retention policies to OpenAI.

## Build from source

Open `boringNotch.xcodeproj` in Xcode 27.3 and choose the **boringNotch** scheme. Build and test on **My Mac**. For a local Apple Silicon Release build with the project’s ad hoc signing configuration, use the invocation below. The runtime override applies to this build and lets macOS load the bundled media framework.

```bash
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData clean build \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES ENABLE_HARDENED_RUNTIME=NO \
  ENABLE_DEBUG_DYLIB=NO ENABLE_PREVIEWS=NO ENABLE_CODE_COVERAGE=NO \
  DEPLOYMENT_LOCATION=NO DEPLOYMENT_POSTPROCESSING=YES \
  STRIP_INSTALLED_PRODUCT=YES STRIP_STYLE=debugging
```

The app is written to `DerivedData/Build/Products/Release/NotSoBoringNotch.app`.

## Roadmap

NotSoBoringNotch currently focuses exclusively on ChatGPT. If the project receives positive community feedback, support for local LLMs and other AI providers such as Claude may be considered in future releases.

## Credits and license

Based on [Boring Notch](https://github.com/TheBoredTeam/boring.notch) by The Bored Team and its contributors. NotSoBoringNotch modifies the upstream project and first released these changes on November 19, 2026. The fork retains the upstream app icon by [@maxtron95](https://github.com/maxtron95) and the upstream installer artwork and layout. Thanks to [MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter) and [NotchDrop](https://github.com/Lakr233/NotchDrop) for their contributions to media controls and Shelf.

The project is licensed under the [GNU General Public License v3.0](LICENSE). See [third-party notices](THIRD_PARTY_LICENSES) for dependency licenses and additional credits.
