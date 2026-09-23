import Darwin
import Foundation
import IOKit
import MouseNavigateCore

/// Raw finger data from trackpads and Magic Mice, through Apple's private
/// MultitouchSupport framework (the same source jitouch and BetterTouchTool read).
///
/// Everything is resolved with `dlsym`, so a macOS release that drops a symbol leaves
/// `isAvailable` false instead of crashing at launch.
final class MultitouchBridge {
    struct Device {
        let reference: UnsafeMutableRawPointer
        let surface: TouchSurface
        let name: String
        let aspectRatio: Double
        /// Physical width of the touch surface, when the registry reports it.
        let widthMillimetres: Double?
    }

    typealias FrameHandler = (_ device: UnsafeMutableRawPointer, _ contacts: [TouchContact], _ timestamp: Double) -> Void

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    private typealias ContactCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
    ) -> Int32
    private typealias CreateListFn = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias RegisterFn = @convention(c) (UnsafeMutableRawPointer?, ContactCallback) -> Void
    private typealias StartFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    private typealias StopFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias IsBuiltInFn = @convention(c) (UnsafeMutableRawPointer?) -> Bool
    private typealias GetServiceFn = @convention(c) (UnsafeMutableRawPointer?) -> io_service_t

    /// Layout of MultitouchSupport's per-finger record. Offsets are read individually rather
    /// than through a mirrored struct, so Swift's layout rules can never shift them.
    private enum ContactLayout {
        static let stride = 96
        static let identifier = 16
        static let state = 20
        static let positionX = 32
        static let positionY = 36
        static let size = 48
        /// Finger states 3 and 4 are "making touch" and "touching"; the rest are hovering
        /// or lifting away.
        static let touchingStates: ClosedRange<Int32> = 3...4
        /// No hand has this many fingers. A count beyond it means the framework's record
        /// layout is not what this code expects, and walking it would read past the buffer.
        static let maximumContacts = 32
    }

    private let handle: UnsafeMutableRawPointer?
    private let createList: CreateListFn?
    private let register: RegisterFn?
    private let unregister: RegisterFn?
    private let start: StartFn?
    private let stop: StopFn?
    private let isBuiltIn: IsBuiltInFn?
    private let getService: GetServiceFn?

    /// Keeps the device objects alive while they are running.
    private var deviceList: CFArray?
    private(set) var devices: [Device] = []

    /// C callbacks carry no context pointer, so frames reach the instance through here.
    /// Written on the main thread, read on MultitouchSupport's, hence the lock.
    private static let handlerLock = NSLock()
    private static var frameHandler: FrameHandler?

    private static func currentHandler() -> FrameHandler? {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        return frameHandler
    }

    private static func setHandler(_ handler: FrameHandler?) {
        handlerLock.lock()
        frameHandler = handler
        handlerLock.unlock()
    }

    init() {
        let library = dlopen(MultitouchBridge.frameworkPath, RTLD_NOW)
        handle = library

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let library, let pointer = dlsym(library, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        createList = symbol("MTDeviceCreateList", as: CreateListFn.self)
        register = symbol("MTRegisterContactFrameCallback", as: RegisterFn.self)
        unregister = symbol("MTUnregisterContactFrameCallback", as: RegisterFn.self)
        start = symbol("MTDeviceStart", as: StartFn.self)
        stop = symbol("MTDeviceStop", as: StopFn.self)
        isBuiltIn = symbol("MTDeviceIsBuiltIn", as: IsBuiltInFn.self)
        getService = symbol("MTDeviceGetService", as: GetServiceFn.self)
    }

    deinit {
        stopAll()
        // The framework is deliberately left loaded: it runs its own callback thread, and
        // unloading the code out from under it would crash. One system framework mapped
        // for the life of the process costs nothing.
    }

    var isAvailable: Bool {
        createList != nil && register != nil && unregister != nil && start != nil && stop != nil
    }

    /// Enumerates the attached surfaces and starts streaming frames from each.
    func startAll(handler: @escaping FrameHandler) {
        stopAll()
        guard isAvailable, let createList, let register, let start,
              let listPointer = createList()
        else {
            return
        }

        let list = Unmanaged<CFArray>.fromOpaque(listPointer).takeRetainedValue()
        deviceList = list
        MultitouchBridge.setHandler(handler)

        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let reference = UnsafeMutableRawPointer(mutating: raw)
            let device = describe(reference)
            devices.append(device)

            register(reference, MultitouchBridge.contactCallback)
            _ = start(reference, 0)
        }
    }

    func stopAll() {
        if let unregister, let stop {
            for device in devices {
                _ = stop(device.reference)
                unregister(device.reference, MultitouchBridge.contactCallback)
            }
        }
        devices.removeAll()
        deviceList = nil
        // Anything still in flight now finds nothing to call.
        MultitouchBridge.setHandler(nil)
    }

    // MARK: - Device details

    private func describe(_ reference: UnsafeMutableRawPointer) -> Device {
        let service = getService?(reference) ?? 0
        let name = registryString(service, "Product") ?? "Multitouch device"
        let width = registryNumber(service, "Sensor Surface Width") ?? 0
        let height = registryNumber(service, "Sensor Surface Height") ?? 0

        let builtIn = isBuiltIn?(reference) ?? false
        let surface: TouchSurface = !builtIn && name.lowercased().contains("mouse") ? .magicMouse : .trackpad
        let aspectRatio = width > 0 && height > 0 ? width / height : (surface == .trackpad ? 1.6 : 0.55)

        return Device(
            reference: reference,
            surface: surface,
            name: name,
            aspectRatio: aspectRatio,
            // The registry reports the sensor surface in hundredths of a millimetre.
            widthMillimetres: width > 0 ? width / 100 : nil
        )
    }

    private func registryString(_ service: io_service_t, _ key: String) -> String? {
        guard service != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    private func registryNumber(_ service: io_service_t, _ key: String) -> Double? {
        guard service != 0 else { return nil }
        return (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber)?.doubleValue
    }

    // MARK: - Frames

    private static let contactCallback: ContactCallback = { device, contacts, count, timestamp, _ in
        guard let device, let handler = MultitouchBridge.currentHandler() else { return 0 }
        // Nothing here is validated by the framework, so treat the count as untrusted
        // before it is used for pointer arithmetic.
        guard count >= 0, count <= ContactLayout.maximumContacts else { return 0 }

        var parsed: [TouchContact] = []
        if let contacts, count > 0 {
            parsed.reserveCapacity(Int(count))
            for index in 0..<Int(count) {
                let record = contacts.advanced(by: index * ContactLayout.stride)
                let state = record.load(fromByteOffset: ContactLayout.state, as: Int32.self)
                guard ContactLayout.touchingStates.contains(state) else { continue }

                let x = record.load(fromByteOffset: ContactLayout.positionX, as: Float32.self)
                let y = record.load(fromByteOffset: ContactLayout.positionY, as: Float32.self)
                let size = record.load(fromByteOffset: ContactLayout.size, as: Float32.self)
                guard x.isFinite, y.isFinite else { continue }

                parsed.append(TouchContact(
                    id: Int(record.load(fromByteOffset: ContactLayout.identifier, as: Int32.self)),
                    // MultitouchSupport puts y = 0 at the edge nearest the user.
                    position: Vector2(
                        x: min(max(Double(x), 0), 1),
                        y: 1 - min(max(Double(y), 0), 1)
                    ),
                    size: size.isFinite ? Double(size) : 0
                ))
            }
        }

        handler(device, parsed, timestamp)
        return 0
    }
}
