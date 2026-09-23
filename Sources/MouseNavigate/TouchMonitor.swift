import AppKit
import CoreGraphics
import IOKit
import MouseNavigateCore

/// Runs the multitouch gesture engine: streams frames from every trackpad and Magic Mouse,
/// feeds them to a recognizer per device, and carries out what the recognizers report.
///
/// Frames arrive on MultitouchSupport's own thread. Recognition happens there under a lock;
/// actions are always carried out on the main thread.
final class TouchMonitor {
    static let didChangeNotification = Notification.Name("com.vinhry.MouseNavigate.touchDidChange")

    private let bridge = MultitouchBridge()
    private let performer: ActionPerformer
    private let strokeRecognizer = StrokeRecognizer()
    private let overlay = DrawingOverlay()

    /// Prints surfaces, contacts and recognized gestures, for tuning. Set by `--touch-debug`.
    var isDebugLogging = false

    var isPaused = false {
        didSet {
            if isPaused { overlay.hide() }
            reevaluate()
        }
    }

    private(set) var isRunning = false

    var isAvailable: Bool { bridge.isAvailable }

    /// Connected surfaces, for the preferences window.
    var surfaces: [(surface: TouchSurface, name: String)] {
        bridge.devices.map { ($0.surface, $0.name) }
    }

    /// Width of the trackpad being listened to, so a spacing in surface units can be shown
    /// as a real distance.
    var trackpadWidthMillimetres: Double? {
        bridge.devices.first { $0.surface == .trackpad }?.widthMillimetres
    }

    // State shared with the MultitouchSupport thread and the event tap.
    private let lock = NSLock()
    private var recognizers: [UnsafeMutableRawPointer: RecognizerState] = [:]
    private var lastMagicMouseContacts: [TouchContact] = []
    /// Kept up to date as frames are processed, so the event tap can ask about every scroll
    /// event without walking the recognizers.
    private var suppressScroll = false
    private var isLeftHanded = false

    private final class RecognizerState {
        var recognizer: TouchGestureRecognizer
        let aspectRatio: Double
        var lastContactCount = 0

        init(recognizer: TouchGestureRecognizer, aspectRatio: Double) {
            self.recognizer = recognizer
            self.aspectRatio = aspectRatio
        }
    }

    private var notificationPort: IONotificationPortRef?
    private var deviceIterators: [io_iterator_t] = []
    private var pendingRebuild: DispatchWorkItem?

    init(performer: ActionPerformer) {
        self.performer = performer
    }

    deinit {
        stopDevices()
        for iterator in deviceIterators {
            IOObjectRelease(iterator)
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
        }
    }

    func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesDidChange),
            name: Preferences.didChangeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(scheduleRebuild),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        observeDeviceChanges()
        reevaluate()
    }

    // MARK: - Queries from the event tap

    /// True while a gesture is using finger movement that macOS would otherwise scroll with.
    var shouldSuppressScroll: Bool {
        lock.lock()
        defer { lock.unlock() }
        return suppressScroll
    }

    /// Whether the fingers on a Magic Mouse are in the middle-click pose right now.
    var isMagicMouseMiddleClickPose: Bool {
        guard isRunning else { return false }
        lock.lock()
        defer { lock.unlock() }
        return TouchGestureRecognizer.isMiddleClickPose(lastMagicMouseContacts, isLeftHanded: isLeftHanded)
    }

    /// Recognizes a drawn stroke from any source, shows what it was, and runs its action.
    func handleStroke(_ points: [Vector2], in space: DrawingOverlay.Space) {
        let match = strokeRecognizer.bestMatch(points)
        let character = strokeRecognizer.recognize(points)
        if isDebugLogging {
            let described = match.map { "\($0.gesture.displayName) (score \(String(format: "%.2f", $0.score)))" } ?? "nothing"
            print("[touch] stroke of \(points.count) points -> \(described)\(character == nil ? ", rejected" : "")")
        }

        let action = character.map { Preferences.shared.characterAction(for: $0) }
        overlay.show(points, in: space)
        overlay.finish(character: character, action: action)

        guard let action else { return }
        performer.perform(action)
    }

    /// Draws a stroke from a mouse-button drag while it is being made.
    func handleStrokeProgress(_ points: [Vector2], in space: DrawingOverlay.Space) {
        overlay.show(points, in: space)
    }

    func cancelStroke() {
        overlay.cancel()
    }

    // MARK: - Lifecycle

    @objc private func preferencesDidChange() {
        reevaluate()
    }

    private func reevaluate() {
        let preferences = Preferences.shared
        let shouldRun = preferences.isTouchEnabled && !isPaused && bridge.isAvailable

        overlay.isEnabled = preferences.showsDrawingOverlay

        lock.lock()
        isLeftHanded = preferences.isLeftHanded
        let drawingEnabled = preferences.isCharacterSourceEnabled(.trackpad)
        for state in recognizers.values {
            state.recognizer.isLeftHanded = isLeftHanded
            state.recognizer.isDrawingEnabled = drawingEnabled
            state.recognizer.tuning.drawSpread = preferences.characterDrawSpread
        }
        lock.unlock()

        if shouldRun && !isRunning {
            startDevices()
        } else if !shouldRun && isRunning {
            stopDevices()
        }
    }

    private func startDevices() {
        bridge.startAll { [weak self] device, contacts, _ in
            self?.handleFrame(device: device, contacts: contacts)
        }

        let preferences = Preferences.shared
        lock.lock()
        recognizers.removeAll()
        for device in bridge.devices {
            var recognizer = TouchGestureRecognizer(surface: device.surface)
            recognizer.isLeftHanded = preferences.isLeftHanded
            recognizer.isDrawingEnabled = preferences.isCharacterSourceEnabled(.trackpad)
            recognizer.tuning.drawSpread = preferences.characterDrawSpread
            recognizers[device.reference] = RecognizerState(recognizer: recognizer, aspectRatio: device.aspectRatio)
        }
        lock.unlock()

        isRunning = true
        if isDebugLogging {
            print("[touch] started with \(bridge.devices.count) surface(s)")
            for device in bridge.devices {
                print("[touch]   \(device.name): \(device.surface.displayName), aspect \(String(format: "%.2f", device.aspectRatio))")
            }
        }
        NotificationCenter.default.post(name: TouchMonitor.didChangeNotification, object: nil)
    }

    private func stopDevices() {
        bridge.stopAll()
        overlay.hide()

        lock.lock()
        recognizers.removeAll()
        lastMagicMouseContacts = []
        suppressScroll = false
        lock.unlock()

        performer.windowManager.endDrag()
        isRunning = false
        NotificationCenter.default.post(name: TouchMonitor.didChangeNotification, object: nil)
    }

    /// Surfaces come and go (Bluetooth, sleep), and MultitouchSupport only reports the ones
    /// present when the list was made, so rebuild it whenever IOKit sees a change.
    private func observeDeviceChanges() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
            .defaultMode
        )

        let callback: IOServiceMatchingCallback = { refcon, iterator in
            TouchMonitor.drain(iterator)
            guard let refcon else { return }
            Unmanaged<TouchMonitor>.fromOpaque(refcon).takeUnretainedValue().scheduleRebuild()
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(
                port,
                type,
                IOServiceMatching("AppleMultitouchDevice"),
                callback,
                refcon,
                &iterator
            )
            guard result == KERN_SUCCESS else { continue }
            // Draining arms the notification; the devices already present need no rebuild.
            TouchMonitor.drain(iterator)
            deviceIterators.append(iterator)
        }
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }

    @objc private func scheduleRebuild() {
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.stopDevices()
            self.reevaluate()
        }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - Frames

    /// Called on MultitouchSupport's thread.
    private func handleFrame(device: UnsafeMutableRawPointer, contacts: [TouchContact]) {
        let isButtonDown = CGEventSource.buttonState(.hidSystemState, button: .left)
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        guard let state = recognizers[device] else {
            lock.unlock()
            return
        }
        let frame = TouchFrame(
            timestamp: now,
            contacts: contacts,
            isPrimaryButtonDown: isButtonDown,
            aspectRatio: state.aspectRatio
        )
        let events = state.recognizer.process(frame)
        let surface = state.recognizer.surface
        let aspectRatio = state.aspectRatio
        if surface == .magicMouse {
            // Raw positions: the pose check applies left-handed mirroring itself.
            lastMagicMouseContacts = contacts
        }
        let countChanged = state.lastContactCount != contacts.count
        state.lastContactCount = contacts.count
        suppressScroll = recognizers.values.contains { $0.recognizer.shouldSuppressScroll }
        lock.unlock()

        if isDebugLogging && countChanged {
            let positions = contacts
                .sorted { $0.position.x < $1.position.x }
                .map { String(format: "(%.2f, %.2f)", $0.position.x, $0.position.y) }
                .joined(separator: " ")
            print("[touch] \(surface.displayName): \(contacts.count) finger(s) \(positions)")
        }

        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.handle(events, aspectRatio: aspectRatio)
        }
    }

    private func handle(_ events: [TouchEvent], aspectRatio: Double) {
        guard isRunning else { return }

        let surfaceSpace = DrawingOverlay.Space.surface(aspectRatio: aspectRatio)

        for event in events {
            switch event {
            case .gesture(let gesture):
                let action = Preferences.shared.touchAction(for: gesture)
                if isDebugLogging {
                    print("[touch] \(gesture.displayName) -> \(action.displayName)")
                }
                if action == .moveResizeWindow {
                    performer.windowManager.beginDrag()
                } else {
                    performer.perform(action)
                }
            case .dragToggleMode:
                performer.windowManager.toggleDragMode()
            case .dragEnded:
                performer.windowManager.endDrag()
            case .stroke(let points):
                handleStroke(points, in: surfaceSpace)
            case .strokeProgress(let points):
                overlay.show(points, in: surfaceSpace)
            case .strokeCancelled:
                overlay.cancel()
            }
        }
    }
}
