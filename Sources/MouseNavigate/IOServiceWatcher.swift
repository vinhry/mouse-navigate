import Foundation
import IOKit

/// Tells its owner, on the main thread, when IOKit services of one class appear or go away.
///
/// It only learns that something changed and never opens anything, so it needs no
/// permission. Changes come in bursts — a mouse brings several HID interfaces with it, and
/// waking from sleep brings back every device at once — so they are gathered for a moment
/// and reported once.
final class IOServiceWatcher {
    private let delay: TimeInterval
    private let onChange: () -> Void
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var pending: DispatchWorkItem?

    init(serviceClass: String, delay: TimeInterval = 0.5, onChange: @escaping () -> Void) {
        self.delay = delay
        self.onChange = onChange

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        // Common modes, so a device that comes or goes while a menu is open or an alert is
        // up is still noticed.
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
            .commonModes
        )

        let callback: IOServiceMatchingCallback = { refcon, iterator in
            IOServiceWatcher.drain(iterator)
            guard let refcon else { return }
            Unmanaged<IOServiceWatcher>.fromOpaque(refcon).takeUnretainedValue().poke()
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            // Each call consumes the dictionary it is given, so each gets its own.
            let result = IOServiceAddMatchingNotification(
                port, type, IOServiceMatching(serviceClass), callback, refcon, &iterator
            )
            guard result == KERN_SUCCESS else { continue }
            // Draining arms the notification; what is already there is no change.
            IOServiceWatcher.drain(iterator)
            iterators.append(iterator)
        }
    }

    deinit {
        pending?.cancel()
        for iterator in iterators {
            IOObjectRelease(iterator)
        }
        if let port {
            IONotificationPortDestroy(port)
        }
    }

    /// Reports a change after the usual pause, as if IOKit had seen one: after waking from
    /// sleep, devices may have changed without saying so.
    func poke() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }
}
