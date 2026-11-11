import AppKit
import CoreGraphics
import MouseNavigateCore

/// Runs the multitouch gesture engine: streams frames from every trackpad and Magic Mouse,
/// feeds them to a recognizer per device, and carries out what the recognizers report.
///
/// Frames arrive on MultitouchSupport's own thread. Recognition happens there under a lock;
/// actions are always carried out on the main thread.
@MainActor
final class TouchMonitor {
    static let didChangeNotification = Notification.Name("com.vinhry.MouseNavigate.touchDidChange")

    /// Main thread only, apart from stopping the frames in deinit.
    nonisolated(unsafe) private let bridge = MultitouchBridge()
    private let performer: ActionPerformer
    private let strokeRecognizer = StrokeRecognizer()
    private let overlay = DrawingOverlay()

    /// Prints surfaces, contacts and recognized gestures, for tuning. Set by `--touch-debug`.
    /// Set once at launch, before any frame arrives.
    nonisolated(unsafe) var isDebugLogging = false

    var isPaused = false {
        didSet {
            if isPaused { overlay.hide() }
            reevaluate()
        }
    }

    private(set) var isRunning = false

    var isAvailable: Bool { bridge.isAvailable }

    /// Called on the main thread whenever a trackpad tap has become a gesture with an
    /// action, so the event tap can hold back the click Tap to click makes from it.
    var trackpadTapGestureHandler: (() -> Void)?
    /// Uptime when the monitor started, so debug lines can carry a time.
    private let debugStart = ProcessInfo.processInfo.systemUptime

    /// Connected surfaces, for the preferences window.
    var surfaces: [(surface: TouchSurface, name: String)] {
        bridge.devices.map { ($0.surface, $0.name) }
    }

    /// Width of the trackpad being listened to, so a spacing in surface units can be shown
    /// as a real distance.
    var trackpadWidthMillimetres: Double? {
        bridge.devices.first { $0.surface == .trackpad }?.widthMillimetres
    }

    // State shared with the MultitouchSupport thread and the event tap, only ever touched
    // with `lock` held: hence nonisolated(unsafe), which the compiler takes on trust.
    private let lock = NSLock()
    nonisolated(unsafe) private var recognizers: [UnsafeMutableRawPointer: RecognizerState] = [:]
    nonisolated(unsafe) private var lastMagicMouseContacts: [TouchContact] = []
    /// Kept up to date as frames are processed, so the event tap can ask about every scroll
    /// event without walking the recognizers.
    nonisolated(unsafe) private var suppressScroll = false
    nonisolated(unsafe) private var isLeftHanded = false
    /// The two accidental-touch guards, cached from Preferences, which only the main thread
    /// may read, so frames can ask without it.
    nonisolated(unsafe) private var ignoresTyping = true
    nonisolated(unsafe) private var ignoresMouseMoving = true
    /// Keys the app sent itself, so its own shortcuts are not taken for typing.
    nonisolated(unsafe) private var typingActivity = TypingActivity()
    /// Where the pointer has been over the last moments, fed by Magic Mouse frames.
    nonisolated(unsafe) private var pointerMotion = PointerMotion()
    /// The Magic Mouse recognizer's tuning, for the pose check the event tap makes.
    nonisolated(unsafe) private var magicMouseTuning = TouchTuning()

    private final class RecognizerState {
        var recognizer: TouchGestureRecognizer
        let aspectRatio: Double
        var lastContactCount = 0
        /// The last rejection written to the debug log, so one that repeats every frame
        /// is written once.
        var lastLoggedRejection: String?

        init(recognizer: TouchGestureRecognizer, aspectRatio: Double) {
            self.recognizer = recognizer
            self.aspectRatio = aspectRatio
        }
    }

    /// Surfaces come and go (Bluetooth, sleep), and MultitouchSupport only reports the ones
    /// present when the list was made, so the list is rebuilt whenever IOKit sees a change.
    private var deviceWatcher: IOServiceWatcher?

    init(performer: ActionPerformer) {
        self.performer = performer
    }

    deinit {
        // Only the frames matter by now; MultitouchSupport's thread must stop calling in.
        bridge.stopAll()
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
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        deviceWatcher = IOServiceWatcher(serviceClass: "AppleMultitouchDevice") { [weak self] in
            self?.rebuild()
        }
        if !bridge.isAvailable {
            Log.touch.error("MultitouchSupport could not be loaded; touch gestures are unavailable.")
        }
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
        return TouchGestureRecognizer.isMiddleClickPose(
            lastMagicMouseContacts,
            tuning: magicMouseTuning,
            isLeftHanded: isLeftHanded
        )
    }

    /// Recognizes a drawn stroke from any source, shows what it was, and runs its action.
    func handleStroke(_ points: [Vector2], in space: DrawingOverlay.Space) {
        let match = strokeRecognizer.bestMatch(points)
        let character = match.flatMap { strokeRecognizer.accepts($0) ? $0.gesture : nil }
        if isDebugLogging {
            let described = match.map { "\($0.gesture.displayName) (score \(String(format: "%.2f", $0.score)))" } ?? "nothing"
            debugLog("[touch] stroke of \(points.count) points -> \(described)\(character == nil ? ", rejected" : "")")
        }

        let binding = character.map {
            Preferences.shared.binding(for: .character($0), app: FrontmostApp.shared.bundleID)
        }
        overlay.show(points, in: space)
        overlay.finish(character: character, binding: binding)

        guard let binding else { return }
        performer.perform(binding)
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
        ignoresTyping = preferences.ignoresTouchWhileTyping
        ignoresMouseMoving = preferences.ignoresTapsWhileMouseMoves
        let drawingEnabled = preferences.isCharacterSourceEnabled(.trackpad)
        for state in recognizers.values {
            state.recognizer.isLeftHanded = isLeftHanded
            state.recognizer.isDrawingEnabled = drawingEnabled
            state.recognizer.tuning.drawSpread = preferences.characterDrawSpread
            if state.recognizer.surface == .magicMouse {
                magicMouseTuning = state.recognizer.tuning
            }
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
        ignoresTyping = preferences.ignoresTouchWhileTyping
        ignoresMouseMoving = preferences.ignoresTapsWhileMouseMoves
        pointerMotion.reset()
        recognizers.removeAll()
        for device in bridge.devices {
            var recognizer = TouchGestureRecognizer(surface: device.surface)
            recognizer.isLeftHanded = preferences.isLeftHanded
            recognizer.isDrawingEnabled = preferences.isCharacterSourceEnabled(.trackpad)
            recognizer.tuning.drawSpread = preferences.characterDrawSpread
            if device.surface == .magicMouse {
                magicMouseTuning = recognizer.tuning
            }
            recognizers[device.reference] = RecognizerState(recognizer: recognizer, aspectRatio: device.aspectRatio)
        }
        lock.unlock()

        isRunning = true
        let names = bridge.devices.map { "\($0.name) (\($0.surface.displayName))" }.joined(separator: ", ")
        Log.touch.info("Listening to \(self.bridge.devices.count) surface(s): \(names, privacy: .public)")
        if isDebugLogging {
            debugLog("[touch] started with \(bridge.devices.count) surface(s)")
            for device in bridge.devices {
                let family = device.familyID.map { "family \($0)" } ?? "family unknown"
                debugLog("[touch]   \(device.name): \(device.surface.displayName), \(family), aspect \(String(format: "%.2f", device.aspectRatio))")
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
        if isRunning {
            Log.touch.info("Stopped listening to touch surfaces.")
        }
        isRunning = false
        NotificationCenter.default.post(name: TouchMonitor.didChangeNotification, object: nil)
    }

    @objc private func handleWake() {
        deviceWatcher?.poke()
    }

    private func rebuild() {
        guard isRunning else { return }
        stopDevices()
        reevaluate()
    }

    // MARK: - Frames

    /// Called on MultitouchSupport's thread.
    private nonisolated func handleFrame(device: UnsafeMutableRawPointer, contacts reported: [TouchContact]) {
        let isButtonDown = CGEventSource.buttonState(.hidSystemState, button: .left)
        let now = ProcessInfo.processInfo.systemUptime
        // Only fingers on the surface count; the rest are hovering or on their way out.
        let contacts = reported.filter(\.isTouching)

        lock.lock()
        guard let state = recognizers[device] else {
            lock.unlock()
            return
        }
        let surface = state.recognizer.surface
        var isTyping = false
        var isPointerMoving = false
        var pointerTravel = 0.0
        if surface == .trackpad, ignoresTyping {
            // The hardware counter, but it counts the app's own keystrokes too (see
            // `TypingActivity`), which is told apart from real ones here. Modifiers alone
            // are not key-downs, so holding a key like Command while gesturing is no typing.
            let since = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
            isTyping = typingActivity.isTyping(now: now, secondsSinceKey: since)
        }
        if surface == .magicMouse, ignoresMouseMoving || isDebugLogging {
            // Documented as usable from any thread, and cheap: no event is made.
            let location = NSEvent.mouseLocation
            let isMoving = pointerMotion.record(time: now, position: Vector2(x: location.x, y: location.y))
            isPointerMoving = isMoving && ignoresMouseMoving
            pointerTravel = pointerMotion.travel
        }
        let frame = TouchFrame(
            timestamp: now,
            contacts: contacts,
            isPrimaryButtonDown: isButtonDown,
            aspectRatio: state.aspectRatio,
            isTyping: isTyping,
            isPointerMoving: isPointerMoving
        )
        let events = state.recognizer.process(frame)
        var rejectionToLog: String?
        if isDebugLogging, let rejection = state.recognizer.lastRejection, rejection != state.lastLoggedRejection {
            // The recognizer keeps a reason until another replaces it, and some are given
            // again every frame, so only a change is news.
            state.lastLoggedRejection = rejection
            rejectionToLog = rejection
        }
        let aspectRatio = state.aspectRatio
        if surface == .magicMouse {
            // Raw positions: the pose check applies left-handed mirroring itself.
            lastMagicMouseContacts = contacts
        }
        let countChanged = state.lastContactCount != reported.count
        state.lastContactCount = reported.count
        suppressScroll = recognizers.values.contains { $0.recognizer.shouldSuppressScroll }
        lock.unlock()

        if isDebugLogging && countChanged {
            // Every finger in range, with its state and size, so a finger the surface keeps
            // losing shows up as what it is: a touch that becomes a hover, or one that is gone.
            let described = reported
                .sorted { $0.position.x < $1.position.x }
                .map { String(format: "(%.2f, %.2f%@ s%d z%.1f)", $0.position.x, $0.position.y, $0.isTouching ? "" : " hover", $0.state, $0.size) }
                .joined(separator: " ")
            let travel = surface == .magicMouse ? String(format: ", pointer moved %.1f pt", pointerTravel) : ""
            debugLog("[touch \(debugTime(now))] \(surface.displayName): \(contacts.count) finger(s) \(described)\(travel)")
        }
        if let rejectionToLog {
            debugLog("[touch \(debugTime(now))] \(surface.displayName): rejected, \(rejectionToLog)")
        }

        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.handle(events, on: surface, aspectRatio: aspectRatio)
        }
    }

    /// A `--touch-debug` line, printed for whoever runs the binary from a terminal and
    /// logged for a copy started with `open --args --touch-debug`, whose output goes
    /// nowhere: `log stream --level debug --predicate 'category == "touch"'` shows it.
    private nonisolated func debugLog(_ line: String) {
        print(line)
        Log.touch.debug("\(line, privacy: .public)")
    }

    private nonisolated func debugTime(_ uptime: TimeInterval) -> String {
        String(format: "%8.3f", uptime - debugStart)
    }

    private func handle(_ events: [TouchEvent], on surface: TouchSurface, aspectRatio: Double) {
        guard isRunning else { return }

        let surfaceSpace = DrawingOverlay.Space.surface(aspectRatio: aspectRatio)

        // Whatever the events set off may send keys, and those must not count as typing.
        let startedAt = ProcessInfo.processInfo.systemUptime
        defer {
            let firesAction = events.contains { event in
                switch event {
                case .gesture, .stroke: return true
                default: return false
                }
            }
            if firesAction {
                let endedAt = ProcessInfo.processInfo.systemUptime
                lock.lock()
                typingActivity.noteOwnKeys(from: startedAt, to: endedAt)
                lock.unlock()
            }
        }

        for event in events {
            switch event {
            case .gesture(let gesture):
                let binding = Preferences.shared.binding(for: .touch(gesture), app: FrontmostApp.shared.bundleID)
                if isDebugLogging {
                    debugLog("[touch \(debugTime(ProcessInfo.processInfo.systemUptime))] \(gesture.displayName) -> \(binding.displayName)")
                }
                if surface == .trackpad, gesture.isTap, binding != .disabled {
                    trackpadTapGestureHandler?()
                }
                if binding == .builtin(.moveResizeWindow) {
                    performer.windowManager.beginDrag()
                } else {
                    performer.perform(binding)
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
