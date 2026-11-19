import AppKit
import ScreenCaptureKit

@available(macOS 15.2, *)
@MainActor
final class GPTScreenAreaCapture: NSObject {
    static let shared = GPTScreenAreaCapture()

    private var panels: [NSPanel] = []
    private var selection: CheckedContinuation<CGRect?, Never>?
    private var selectionID: UUID?

    static func attach(to conversation: GPTConversation,
                       capture: @escaping @MainActor () async -> GPTImageImport = { await shared.capture() },
                       showResult: ((Bool) -> Void)? = nil) {
        conversation.importImages(onResult: { result in
            if !result.attachments.isEmpty || result.warning != nil {
                showResult?(!result.attachments.isEmpty)
            }
        }) { _ in await capture() }
    }

    private func capture() async -> GPTImageImport {
        guard selection == nil, !Task.isCancelled else { return GPTImageImport() }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            return GPTImageImport(warning: .capturePermission)
        }

        let previousWindow = NSApp.keyWindow
        let rect = await selectRegion()
        if previousWindow?.isVisible == true, NSApp.isActive, NSApp.keyWindow?.isVisible != true {
            previousWindow?.makeKey()
        }
        guard let rect, !Task.isCancelled else { return GPTImageImport() }
        do {
            // The selection panels have been ordered out. Let WindowServer apply that change.
            try await Task.sleep(for: .milliseconds(120))
            let image = try await SCScreenshotManager.captureImage(in: rect)
            try Task.checkCancellation()
            let attachment = try await Task.detached(priority: .userInitiated) {
                try GPTImageAttachment.load(capture: image)
            }.value
            try Task.checkCancellation()
            return GPTImageImport(attachments: [attachment])
        } catch is CancellationError {
            return GPTImageImport()
        } catch {
            return GPTImageImport(warning: .captureFailed)
        }
    }

    private func selectRegion() async -> CGRect? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, selection == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                selection = continuation
                selectionID = id
                presentOverlays()
            }
        } onCancel: {
            Task { @MainActor in
                if self.selectionID == id { self.finish(nil) }
            }
        }
    }

    private func presentOverlays() {
        for screen in NSScreen.screens {
            guard let displayID = screen.cgDisplayID else { continue }
            let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.animationBehavior = .none
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.contentView = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size)) { [weak self] rect in
                guard let rect else { self?.finish(nil); return }
                let quartz = CGDisplayBounds(displayID)
                self?.finish(Self.quartzRect(from: rect, display: quartz))
            }
            panel.setFrame(screen.frame, display: false)
            panels.append(panel)
        }

        guard !panels.isEmpty else { finish(nil); return }
        NotificationCenter.default.addObserver(self, selector: #selector(focusSelection),
                                               name: NSApplication.didBecomeActiveNotification, object: NSApp)
        NotificationCenter.default.addObserver(self, selector: #selector(cancel),
                                               name: NSApplication.didResignActiveNotification, object: NSApp)
        NotificationCenter.default.addObserver(self, selector: #selector(cancel),
                                               name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        for panel in panels { panel.orderFrontRegardless() }
        if NSApp.isActive { focusSelection() }
        else { NSApp.activate() }
    }

    @objc private func focusSelection() {
        let pointer = NSEvent.mouseLocation
        guard let panel = panels.first(where: { $0.frame.contains(pointer) }) ?? panels.first else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
    }

    // SelectionView uses a lower-left origin. ScreenCaptureKit uses upper-left display coordinates.
    static func quartzRect(from localRect: CGRect, display: CGRect) -> CGRect {
        CGRect(x: display.minX + localRect.minX, y: display.maxY - localRect.maxY,
               width: localRect.width, height: localRect.height)
    }

    @objc private func cancel() { finish(nil) }

    private func finish(_ region: CGRect?) {
        guard let continuation = selection else { return }
        selection = nil
        selectionID = nil
        NotificationCenter.default.removeObserver(self)
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels.removeAll()
        continuation.resume(returning: region)
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class SelectionView: NSView {
    private var start: CGPoint?
    private var rectangle: CGRect = .zero
    private let finish: (CGRect?) -> Void

    init(frame: CGRect, finish: @escaping (CGRect?) -> Void) {
        self.finish = finish
        super.init(frame: frame)
        setAccessibilityLabel(String(localized: "Drag to select a screen area. Press Escape to cancel."))
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        rectangle = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        rectangle = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                           width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        let area = rectangle.integral.intersection(bounds)
        finish(area.width >= 8 && area.height >= 8 ? area : nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(nil) }
        else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.24).setFill()
        bounds.fill()
        guard !rectangle.isEmpty, !rectangle.isNull else {
            let title = String(localized: "Drag to select an area · Esc to cancel") as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = title.size(withAttributes: attributes)
            let label = CGRect(x: bounds.midX - size.width / 2, y: bounds.maxY - 76,
                               width: size.width, height: size.height)
            NSColor.black.withAlphaComponent(0.65).setFill()
            NSBezierPath(roundedRect: label.insetBy(dx: -12, dy: -7), xRadius: 8, yRadius: 8).fill()
            title.draw(in: label, withAttributes: attributes)
            return
        }
        NSColor.clear.setFill()
        rectangle.fill(using: .copy)
        NSColor.white.setStroke()
        let outline = NSBezierPath(rect: rectangle)
        outline.lineWidth = 1
        outline.stroke()
    }
}
