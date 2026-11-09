import AppKit
import CoreGraphics

private final class LoupePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Allow the lens to cross display boundaries while dragging.
        frameRect
    }
}

private final class LoupeView: NSView {
    var onMove: ((NSPoint) -> Void)?
    var onPickUp: (() -> Void)?
    var onPutDown: ((CGFloat) -> Void)?
    var onAppearanceChange: ((Bool) -> Void)?
    var contextMenu: NSMenu?
    private var dragOffset = NSPoint.zero
    private var dragSample: (x: CGFloat, time: TimeInterval)?
    private var horizontalVelocity: CGFloat = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let dx = local.x - bounds.midX
        let dy = local.y - bounds.midY
        guard hypot(dx, dy) <= bounds.width * LoupeRenderer.radiusFraction else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard let frame = window?.frame else { return }
        let mouse = NSEvent.mouseLocation
        dragOffset = NSPoint(x: mouse.x - frame.midX, y: mouse.y - frame.midY)
        dragSample = (mouse.x, event.timestamp)
        horizontalVelocity = 0
        onPickUp?()
    }

    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        if let sample = dragSample, event.timestamp > sample.time {
            horizontalVelocity = (mouse.x - sample.x) / (event.timestamp - sample.time)
        }
        dragSample = (mouse.x, event.timestamp)
        onMove?(NSPoint(x: mouse.x - dragOffset.x, y: mouse.y - dragOffset.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard let sample = dragSample else { return }
        dragSample = nil
        onPutDown?(event.timestamp - sample.time <= 0.1 ? horizontalVelocity : 0)
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?(effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }
}

@MainActor
private final class LoupeSizeSettings: NSWindowController {
    private let slider: NSSlider
    private let valueLabel = NSTextField(labelWithString: "")
    private let onChange: (Int) -> Void

    init(diameter: Int, range: ClosedRange<Int>, onChange: @escaping (Int) -> Void) {
        slider = NSSlider(value: Double(diameter), minValue: Double(range.lowerBound),
                          maxValue: Double(range.upperBound), target: nil, action: nil)
        self.onChange = onChange
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 312, height: 96),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "观片镜大小"
        window.level = .statusBar
        window.isReleasedWhenClosed = false
        window.center()

        slider.target = self
        slider.action = #selector(diameterChanged)
        slider.isContinuous = true
        slider.setAccessibilityLabel("观片镜直径")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.stringValue = "\(diameter) pt"

        let heading = NSStackView(views: [NSTextField(labelWithString: "直径"), valueLabel])
        heading.distribution = .equalSpacing
        let controls = NSStackView(views: [heading, slider])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        guard let content = window.contentView else { return }
        content.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            controls.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            heading.widthAnchor.constraint(equalTo: controls.widthAnchor),
            slider.widthAnchor.constraint(equalTo: controls.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    @objc private func diameterChanged() {
        let diameter = Int(slider.doubleValue.rounded())
        valueLabel.stringValue = "\(diameter) pt"
        onChange(diameter)
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private static let previewBundleID = "com.apple.Preview"
    private static let showWithPreviewKey = "ShowWithPreview"
    private static let diameterKey = "LoupeDiameter"
    private static let diameterRange = 100...260
    private static let defaultDiameter = 160

    private let capture = DisplayCapture()
    private var statusItem: NSStatusItem?
    private var showItem: NSMenuItem?
    private var previewItem: NSMenuItem?
    private var panel: LoupePanel?
    private var renderer: LoupeRenderer?
    private var sizeSettings: LoupeSizeSettings?
    private var showing = false
    private var previewIsActive = false

    private var showWithPreview: Bool {
        get { UserDefaults.standard.bool(forKey: Self.showWithPreviewKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.showWithPreviewKey) }
    }

    private var diameter: Int {
        let saved = UserDefaults.standard.object(forKey: Self.diameterKey) as? Int ?? Self.defaultDiameter
        return min(max(saved, Self.diameterRange.lowerBound), Self.diameterRange.upperBound)
    }

    private var panelSide: CGFloat {
        LoupeRenderer.panelSide(forDiameter: CGFloat(diameter))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "magnifyingglass.circle",
                                           accessibilityDescription: "macOS Loupe")
        statusItem.button?.toolTip = "macOS Loupe"

        let menu = NSMenu(title: "macOS Loupe")
        menu.delegate = self
        let show = item("显示观片镜", #selector(toggleLoupe))
        let size = item("观片镜大小…", #selector(showSizeSettings))
        let preview = item("打开「预览」时显示", #selector(toggleShowWithPreview))
        let quit = NSMenuItem(title: "退出 macOS Loupe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.items = [show, size, preview, .separator(), quit]
        statusItem.menu = menu
        self.statusItem = statusItem
        showItem = show
        previewItem = preview

        capture.onFrame = { [weak self] buffer, displayFrame in
            self?.renderer?.update(buffer, displayFrame: displayFrame)
        }
        capture.onFailure = { [weak self] error in self?.captureFailed(error) }

        let workspace = NSWorkspace.shared
        workspace.notificationCenter.addObserver(self, selector: #selector(frontmostApplicationChanged),
                                                 name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenConfigurationChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        updatePreviewActivation(for: workspace.frontmostApplication?.bundleIdentifier)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLoupe()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeLoupe()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        showItem?.title = showing ? "移除观片镜" : "显示观片镜"
        previewItem?.state = showWithPreview ? .on : .off
    }

    @objc private func toggleShowWithPreview() {
        showWithPreview.toggle()
        if showWithPreview && previewIsActive { showLoupe() }
    }

    @objc private func frontmostApplicationChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        updatePreviewActivation(for: app.bundleIdentifier)
    }

    private func updatePreviewActivation(for bundleID: String?) {
        guard bundleID != Bundle.main.bundleIdentifier else { return }
        let isPreview = bundleID == Self.previewBundleID
        let enteredPreview = isPreview && !previewIsActive
        previewIsActive = isPreview
        if enteredPreview && showWithPreview { showLoupe() }
    }

    @objc private func toggleLoupe() {
        if showing { removeLoupe() } else { showLoupe() }
    }

    @objc private func showSizeSettings() {
        if sizeSettings == nil {
            sizeSettings = LoupeSizeSettings(diameter: diameter, range: Self.diameterRange) { [weak self] diameter in
                self?.setDiameter(diameter)
            }
        }
        NSApp.activate()
        sizeSettings?.showWindow(nil)
    }

    private func setDiameter(_ diameter: Int) {
        guard self.diameter != diameter else { return }
        UserDefaults.standard.set(diameter, forKey: Self.diameterKey)
        guard let panel else { return }
        let side = panelSide
        let origin = NSPoint(x: panel.frame.midX - side / 2, y: panel.frame.midY - side / 2)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: side, height: side)), display: showing)
        updateRendererPosition()
    }

    private func showLoupe() {
        guard !showing else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            showError("macOS Loupe 需要屏幕录制权限",
                      detail: "请在系统设置中允许 macOS Loupe 录制屏幕，然后再次显示观片镜。", settings: true)
            return
        }

        do {
            let panel = try preparePanel()
            let mouse = NSEvent.mouseLocation
            guard let screen = screen(at: mouse) else { return }
            let center = fitOnScreen(mouse, screen: screen)
            showing = true
            renderer?.putDown(onLeft: center.x < screen.frame.midX, animated: false)
            moveLoupe(to: center)
            panel.orderFrontRegardless()
        } catch {
            showError("无法显示观片镜", detail: error.localizedDescription)
        }
    }

    private func preparePanel() throws -> LoupePanel {
        if let panel { return panel }
        guard let packageURL = Bundle.main.url(forResource: "LandingUI-Loupe", withExtension: "ca") else {
            throw LoupeError("找不到原版观片镜资源，请运行 Scripts/import-loupe.sh 后重新构建。")
        }

        let side = panelSide
        let frame = NSRect(x: 0, y: 0, width: side, height: side)
        let view = LoupeView(frame: frame)
        view.setAccessibilityLabel("桌面观片镜")
        let renderer = try LoupeRenderer(packageURL: packageURL, view: view)

        let panel = LoupePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.title = "macOS Loupe"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.contentView = view
        panel.delegate = self

        let context = NSMenu(title: "观片镜")
        context.addItem(item("移除观片镜", #selector(removeLoupe)))
        view.contextMenu = context
        view.onMove = { [weak self] center in self?.moveLoupe(to: center) }
        view.onPickUp = { [weak renderer] in renderer?.pickUp() }
        view.onPutDown = { [weak self] velocity in self?.putDownLoupe(horizontalVelocity: velocity) }
        view.onAppearanceChange = { [weak renderer] dark in renderer?.setDarkAppearance(dark) }
        view.viewDidChangeEffectiveAppearance()

        self.panel = panel
        self.renderer = renderer
        return panel
    }

    @objc private func removeLoupe() {
        showing = false
        panel?.orderOut(nil)
        capture.stop()
        renderer?.reset()
    }

    private func screen(at point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? panel?.screen ?? NSScreen.main
    }

    private func fitOnScreen(_ point: NSPoint, screen: NSScreen) -> NSPoint {
        let inset = panelSide / 2
        let safe = screen.visibleFrame.insetBy(dx: inset, dy: inset)
        guard !safe.isEmpty else { return point }
        return NSPoint(x: min(max(point.x, safe.minX), safe.maxX),
                       y: min(max(point.y, safe.minY), safe.maxY))
    }

    private func moveLoupe(to center: NSPoint) {
        guard showing, let panel, let screen = screen(at: center) else { return }
        panel.setFrameOrigin(NSPoint(x: center.x - panel.frame.width / 2,
                                    y: center.y - panel.frame.height / 2))
        updateRendererPosition()
        capture.capture(screen)
    }

    private func updateRendererPosition() {
        guard let panel else { return }
        renderer?.updateViewport(center: NSPoint(x: panel.frame.midX, y: panel.frame.midY),
                                 side: panel.frame.width, scale: panel.backingScaleFactor)
    }

    private func putDownLoupe(horizontalVelocity: CGFloat) {
        guard showing, let panel else { return }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        guard let screen = screen(at: center) else { return }
        // Preview chooses a resting side using the projected horizontal release position.
        let projectedX = center.x + horizontalVelocity * 0.499
        renderer?.putDown(onLeft: projectedX < screen.frame.midX, animated: true)
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        if showing { updateRendererPosition() }
    }

    @objc private func screenConfigurationChanged() {
        guard showing, let panel else { return }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        capture.stop()
        if let screen = screen(at: center) {
            moveLoupe(to: screen.frame.contains(center) ? center : fitOnScreen(center, screen: screen))
        } else {
            removeLoupe()
        }
    }

    private func captureFailed(_ error: Error) {
        guard showing else { return }
        removeLoupe()
        showError("屏幕采集已停止", detail: error.localizedDescription, settings: !CGPreflightScreenCaptureAccess())
    }

    private func showError(_ title: String, detail: String, settings: Bool = false) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: settings ? "打开系统设置" : "好")
        if settings { alert.addButton(withTitle: "稍后") }
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn && settings,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

@main
enum MacOSLoupe {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let controller = AppController()
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}
