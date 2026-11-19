//
//  boringNotchApp.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//

import AVFoundation
import Defaults
import KeyboardShortcuts
import SwiftUI

@main
struct DynamicNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Default(.menubarIcon) var showMenuBarIcon
    private let conversation = GPTConversation.shared

    init() {
        #if DEBUG
        OTPDetector.runSelfCheck()
        #endif
    }

    var body: some Scene {
        MenuBarExtra("NotSoBoringNotch", systemImage: "sparkle", isInserted: $showMenuBarIcon) {
            Button("Settings") {
                DispatchQueue.main.async {
                    SettingsWindowController.shared.showWindow()
                }
            }
            .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
            Button("GPT Chat…") {
                GPTChatWindowController.shared.open()
            }
            if #available(macOS 15.2, *) {
                Button("Select Screen Area…", systemImage: "viewfinder") {
                    GPTScreenAreaCapture.attach(to: conversation, showResult: { captured in
                        let pointer = NSEvent.mouseLocation
                        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
                        GPTChatWindowController.shared.open(on: screen, focusComposer: captured)
                    })
                }
                .disabled(conversation.isImportingImages)
            }
            Button("Restart NotSoBoringNotch") {
                ApplicationRelauncher.restart()
            }
            Button("Quit", role: .destructive) {
                NSApplication.shared.terminate(self)
            }
            .keyboardShortcut(KeyEquivalent("Q"), modifiers: .command)
        }
    }
}

/// App-lifecycle glue: shortcuts, onboarding, termination, observer wiring.
/// All notch-window / per-screen view-model / drag-detector lifecycle lives
/// in `NotchWindowManager` (see managers/NotchWindowManager.swift).
final class AppDelegate: NSObject, NSApplicationDelegate {
    let camera = CameraModel()
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    var quickShareService = QuickShareService.shared
    var closeNotchTask: Task<Void, Never>?
    private lazy var windowManager = NotchWindowManager(camera: camera)
    private var onboardingWindowController: NSWindowController?
    private var screenLockedObserver: Any?
    private var screenUnlockedObserver: Any?
    private var observers: [Any] = []
    private var activeDisplayObserver: NSObjectProtocol?
    private var displayModeTask: Task<Void, Never>?
    private var observedDisplayMode: DisplayMode?

    /// Kept for existing internal readers; the state itself moved to the manager.
    var windows: [String: NSWindow] { windowManager.windows }
    var viewModels: [String: BoringViewModel] { windowManager.viewModels }
    var window: NSWindow? { windowManager.window }
    var vm: BoringViewModel { windowManager.primaryViewModel }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    @MainActor
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !AskGPTWindows.shared.hasRequests {
            SettingsWindowController.shared.showWindow()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flush debounced shelf persistence to avoid losing recent changes
        ShelfStateViewModel.shared.flushSync()

        NotificationCenter.default.removeObserver(self)
        if let observer = screenLockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenLockedObserver = nil
        }
        if let observer = screenUnlockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenUnlockedObserver = nil
        }
        MainActor.assumeIsolated {
            MusicManager.shared.destroy()
            windowManager.cleanup()
        }
        BetterDisplayManager.shared.stopObserving()
        LunarManager.shared.stopListening()
        LunarManager.shared.configureLunarOSD(hide: false)
        XPCHelperClient.shared.stopMonitoringAccessibilityAuthorization()

        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()

        displayModeTask?.cancel()
        MainActor.assumeIsolated { setActiveDisplayObserver(enabled: false, reposition: false) }
    }

    @MainActor
    func onScreenLocked(_ notification: Notification) {
        windowManager.screenLocked()
    }

    @MainActor
    func onScreenUnlocked(_ notification: Notification) {
        windowManager.screenUnlocked()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = AskGPTService.shared
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AskGPTWindows.shared.applicationDidBecomeActive()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsWindowController.shared.setCamera(camera)
        migrateDisplayModeIfNeeded()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name.selectedScreenChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.windowManager.adjustWindowPosition(changeAlpha: true)
                self?.windowManager.setupDragDetectors()
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name.notchHeightChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.windowManager.adjustWindowPosition()
                self?.windowManager.setupDragDetectors()
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name.expandedDragDetectionChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.windowManager.setupDragDetectors()
            }
        })

        // Use closure-based observers for DistributedNotificationCenter and keep tokens for removal
        screenLockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenLocked(notification)
                }
        }

        screenUnlockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenUnlocked(notification)
                }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleSneakPeek) { [weak self] in
            guard let self = self else { return }
            if Defaults[.sneakPeekStyles] == .inline {
                let newStatus = !self.coordinator.expandingView.show
                self.coordinator.toggleExpandingView(status: newStatus, type: .music)
                KeyboardShortcuts.onKeyUp(for: .toggleSneakPeek) {
                    self.coordinator.toggleSneakPeek(
                        status: !self.coordinator.isAnySneakPeekShowing,
                        type: .music
                    )
                }
            } else {
                self.coordinator.toggleSneakPeek(
                    status: !self.coordinator.isAnySneakPeekShowing,
                    type: .music,
                    duration: 3.0
                )
            }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleNotchOpen) { [weak self] in
            Task { [weak self] in
                guard let self = self else { return }

                let mouseLocation = NSEvent.mouseLocation

                var viewModel = self.vm

                if Defaults[.displayMode] == .allDisplays {
                    for screen in NSScreen.screens {
                        if screen.frame.contains(mouseLocation) {
                            if let uuid = screen.displayUUID, let screenViewModel = self.viewModels[uuid] {
                                viewModel = screenViewModel
                                break
                            }
                        }
                    }
                }

                self.closeNotchTask?.cancel()
                self.closeNotchTask = nil

                switch viewModel.notchState {
                case .closed:
                    var didOpen = false
                    await MainActor.run {
                        didOpen = viewModel.open()
                    }
                    guard didOpen else { return }

                    let task = Task { [weak viewModel] in
                        do {
                            try await Task.sleep(for: .seconds(3))
                            await MainActor.run {
                                viewModel?.close()
                            }
                        } catch { }
                    }
                    self.closeNotchTask = task
                case .open:
                    await MainActor.run {
                        viewModel.close()
                    }
                }
            }
        }

        // Sync notch height with real value on app launch if mode is matchRealNotchSize
        syncNotchHeightIfNeeded()

        windowManager.prepareInitialWindows()

        displayModeTask = Task { @MainActor [weak self] in
            for await mode in Defaults.updates(.displayMode, initial: true) {
                guard let self else { return }

                let previousMode = self.observedDisplayMode
                self.observedDisplayMode = mode

                if let previousMode, (previousMode == .allDisplays) != (mode == .allDisplays) {
                    self.windowManager.cleanupWindows(shouldInvert: true)
                }

                self.setActiveDisplayObserver(enabled: mode == .activeDisplay, reposition: false)
                self.windowManager.adjustWindowPosition(changeAlpha: true)
                self.windowManager.setupDragDetectors()
            }
        }

        // Apply OSD sources after the notch windows are ready.
        coordinator.applyOSDSources()
        AskGPTWindows.shared.markReady()

        DispatchQueue.main.async {
            guard !AskGPTWindows.shared.hasRequests, !Self.isRunningTests else { return }
            if self.coordinator.firstLaunch {
                self.showOnboardingWindow()
                self.playWelcomeSound()
            } else {
                GPTIntroductionWindow.shared.showIfNeeded(firstLaunch: false)
            }
        }
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private func migrateDisplayModeIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "displayMode") == nil else { return }

        let mode: DisplayMode
        if Defaults[.showOnAllDisplays] {
            mode = .allDisplays
        } else if Defaults[.followActiveDisplay] {
            mode = .activeDisplay
        } else if Defaults[.automaticallySwitchDisplay] {
            mode = .fallbackIfPreferredUnavailable
        } else {
            mode = .preferredDisplay
        }

        Defaults[.displayMode] = mode
    }

    private static let activeDisplayDidChangeNotification =
        Notification.Name("NSWorkspaceActiveDisplayDidChangeNotification")

    @MainActor
    private func setActiveDisplayObserver(enabled: Bool, reposition: Bool = true) {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        if enabled {
            guard activeDisplayObserver == nil else { return }

            activeDisplayObserver = workspaceCenter.addObserver(
                forName: Self.activeDisplayDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.windowManager.adjustWindowPosition(changeAlpha: true)
                    self.windowManager.setupDragDetectors()
                }
            }
        } else if let observer = activeDisplayObserver {
            workspaceCenter.removeObserver(observer)
            activeDisplayObserver = nil
        }

        guard reposition else { return }

        windowManager.adjustWindowPosition(changeAlpha: true)
        windowManager.setupDragDetectors()
    }

    func playWelcomeSound() {
        let audioPlayer = AudioPlayer()
        audioPlayer.play(fileName: "boring", fileExtension: "m4a")
    }

    @objc func screenConfigurationDidChange() {
        windowManager.screenConfigurationDidChange()
    }

    @objc func togglePopover(_ sender: Any?) {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    private func showOnboardingWindow(step: OnboardingStep = .welcome) {
        if onboardingWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Welcome to NotSoBoringNotch"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.level = .floating
            window.contentView = NSHostingView(
                rootView: OnboardingView(
                    step: step,
                    onFinish: { [weak self, weak window] in
                        window?.close()
                        self?.onboardingWindowController = nil
                        GPTIntroductionWindow.shared.showIfNeeded(firstLaunch: false)
                    },
                    onOpenSettings: { [weak self, weak window] in
                        window?.close()
                        self?.onboardingWindowController = nil
                        SettingsWindowController.shared.showWindow()
                        DispatchQueue.main.async {
                            guard !AskGPTWindows.shared.hasRequests else { return }
                            GPTIntroductionWindow.shared.showIfNeeded(firstLaunch: false)
                        }
                    }
                ))
            window.isRestorable = false
            window.identifier = NSUserInterfaceItemIdentifier("OnboardingWindow")

            onboardingWindowController = NSWindowController(window: window)
        }

//        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindowController?.window?.level = .floating
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
        onboardingWindowController?.window?.orderFrontRegardless()
    }
}
