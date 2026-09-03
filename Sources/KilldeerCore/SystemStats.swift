import Foundation
import IOKit

/// One temperature sensor's current reading.
public struct SensorReading: Sendable, Equatable {
    public let name: String
    public let celsius: Double

    public init(name: String, celsius: Double) {
        self.name = name
        self.celsius = celsius
    }
}

/// Which of a machine's many sensors to put in front of the user.
public enum TemperatureSelection {
    /// Readings outside this range are hardware saying "nothing is connected
    /// here" rather than a temperature. A MacBook reports about -1.9 from
    /// several `tdev` sensors, and averaging those in drags the figure down by
    /// a few degrees.
    static let plausible: ClosedRange<Double> = 1...150

    /// The one number worth showing, or nil when the machine offers nothing
    /// usable.
    ///
    /// The die sensors are preferred and the hottest of them wins: the question
    /// behind a temperature readout in a runaway-process app is "is the chip
    /// cooking", which the hottest core answers and an average hides. Sensor
    /// names differ by machine, so anything without `tdie` falls back to the
    /// hottest plausible sensor of any kind rather than showing nothing.
    public static func representative(from readings: [SensorReading]) -> Double? {
        let usable = readings.filter { plausible.contains($0.celsius) }
        guard !usable.isEmpty else { return nil }
        let die = usable.filter { isDieSensor($0.name) }
        return (die.isEmpty ? usable : die).map(\.celsius).max()
    }

    /// Which of a machine's sensors are worth reading at all, as indices into
    /// `names`.
    ///
    /// Decided once and from names alone, because the cost is in the reading:
    /// one machine matches 39 sensors and reading all of them takes about 44ms,
    /// against about 14ms for its 16 die sensors.
    ///
    /// This is one step stronger than `representative`, which falls back to
    /// non-die sensors whenever the die ones have no usable value. Once
    /// narrowed there is nothing left to fall back to, so a moment when every
    /// die sensor reads out of range shows no temperature instead of a
    /// battery's. That is the intended trade: the figure is meant to answer
    /// "is the chip hot", and quietly putting a battery temperature in its
    /// place answers a different question without saying so.
    public static func sensorsToRead(named names: [String]) -> [Int] {
        let die = names.indices.filter { isDieSensor(names[$0]) }
        return die.isEmpty ? Array(names.indices) : die
    }

    private static func isDieSensor(_ name: String) -> Bool {
        name.lowercased().contains("tdie")
    }
}

/// A snapshot of the cumulative CPU tick counters.
public struct CPUTicks: Sendable, Equatable {
    public let busy: Double
    public let total: Double

    public init(busy: Double, total: Double) {
        self.busy = busy
        self.total = total
    }
}

public enum CPULoad {
    /// System-wide CPU use between two snapshots, or nil when no time passed.
    ///
    /// The counters only climb, so a later snapshot should not hold fewer ticks
    /// than an earlier one. They are `natural_t`, though, so each one wraps at
    /// 2^32 and comes back round; a reset would look the same. Either way a
    /// negative percentage in the menu is worse than no percentage, and the
    /// next poll recovers on its own.
    public static func percentage(from first: CPUTicks, to second: CPUTicks) -> Double? {
        let total = second.total - first.total
        let busy = second.busy - first.busy
        guard total > 0, busy >= 0 else { return nil }
        return min(100, busy / total * 100)
    }

    /// The counters as the kernel has them now.
    public static func sample() -> CPUTicks? {
        // mach_host_self hands back a send right the caller owns, and this runs
        // once a poll for the life of the app. Balanced for that reason rather
        // than to head off a failure: measured, an unbalanced count climbs to
        // 65535 and saturates there, host_statistics keeps returning
        // KERN_SUCCESS, and once saturated the count never comes back down even
        // when the rights are released.
        let host = mach_host_self()
        // mach_task_self() is a macro and does not reach Swift; mach_task_self_
        // is the variable it expands to.
        defer { mach_port_deallocate(mach_task_self_, host) }

        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride
            / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = Double(info.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3)
        return CPUTicks(busy: user + system + nice, total: user + system + nice + idle)
    }
}

/// Reads the machine's temperature sensors.
///
/// There is no public API for this. The sensors are exposed as HID services on
/// Apple's own usage page, and the functions that read them are private IOKit
/// symbols, so they are looked up with `dlsym` rather than linked: a missing
/// symbol then costs a nil reading instead of a launch failure, which is the
/// difference between the temperature line disappearing and the app not
/// starting on a macOS that moved them.
///
/// Everything here is best-effort by design. `readings()` returning empty is a
/// normal outcome, not an error: Intel Macs expose their sensors through the
/// SMC instead, and Apple is free to move these at any release. The menu then
/// shows its CPU figure without a temperature beside it.
///
/// `Sendable` because the reader is handed to a background task every poll.
/// The conformance is unchecked and so has to be earned rather than measured:
/// a read from a second thread returning the right answer would only show that
/// a hand-off works, not that two concurrent reads are safe, and this type is
/// public enough for a caller to try. `readings()` therefore takes a lock, and
/// every other stored property is written once in `init`.
///
/// Reads belong off the main thread regardless. Every sensor is its own round
/// trip, so a read costs roughly a millisecond per sensor.
public final class TemperatureReader: @unchecked Sendable {
    // Widths chosen to be safe under either reading of these undocumented
    // signatures rather than copied from an authority. On arm64 a 32-bit
    // argument leaves the top half of its register undefined, so passing Int32
    // where the callee reads an Int64 hands it a value with rubbish in the high
    // word; declaring the wider integer works either way, because a callee that
    // reads only the low word still sees the value. Measured: an event type of
    // 0x7BADBEEF00000000 | 15 still returns a temperature, so this one is read
    // as 32 bits -- which is exactly the case the wider declaration covers for
    // the ones not tested that way.
    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Void
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias EventFloat = @convention(c) (AnyObject, Int32) -> Double
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?

    // kIOHIDEventTypeTemperature, and the field identifier for its level: the
    // event type shifted into the high half-word. The macro that spells this
    // out, IOHIDEventFieldBase, is in Apple's open source IOHIDFamily and not
    // in the shipped SDK, so the shift is written out here.
    private static let temperatureEventType: Int64 = 15
    private static let temperatureField: Int32 = Int32(15) << 16
    // Apple's own HID usage page, and the usage number for a temperature
    // sensor within it.
    private static let appleVendorUsagePage = 0xff00
    private static let temperatureSensorUsage = 0x0005

    /// Held for as long as the services are. The service clients are handles
    /// into this client; releasing it at the end of `init` and keeping only the
    /// services leaves them pointing at freed memory, and the first read then
    /// aborts inside IOKit's own lock rather than returning nothing.
    private let client: AnyObject?
    private let services: [AnyObject]
    private let names: [String]
    private let copyEvent: CopyEvent?
    private let eventFloat: EventFloat?
    /// `readings()` is called from a background task, and the conformance above
    /// promises more than one caller is allowed to do that.
    private let lock = NSLock()

    /// True when the machine offered at least one sensor to read.
    public var isAvailable: Bool { !services.isEmpty }

    public init() {
        // The handle is deliberately not kept and never closed. IOKit is in the
        // shared cache and already loaded; closing it would only risk
        // invalidating function pointers this object holds for its lifetime.
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let createSymbol = dlsym(iokit, "IOHIDEventSystemClientCreate"),
              let matchingSymbol = dlsym(iokit, "IOHIDEventSystemClientSetMatching"),
              let servicesSymbol = dlsym(iokit, "IOHIDEventSystemClientCopyServices"),
              let eventSymbol = dlsym(iokit, "IOHIDServiceClientCopyEvent"),
              let floatSymbol = dlsym(iokit, "IOHIDEventGetFloatValue")
        else {
            client = nil
            services = []
            names = []
            copyEvent = nil
            eventFloat = nil
            return
        }

        let create = unsafeBitCast(createSymbol, to: CreateClient.self)
        let setMatching = unsafeBitCast(matchingSymbol, to: SetMatching.self)
        let copyServices = unsafeBitCast(servicesSymbol, to: CopyServices.self)
        copyEvent = unsafeBitCast(eventSymbol, to: CopyEvent.self)
        eventFloat = unsafeBitCast(floatSymbol, to: EventFloat.self)

        guard let created = create(kCFAllocatorDefault)?.takeRetainedValue() else {
            client = nil
            services = []
            names = []
            return
        }
        client = created
        // Declared as returning nothing because, measured, whatever it leaves in
        // the return register is not a status: it is a differently shaped
        // pointer-like value on every run, and the same shape whether the match
        // took or was given a usage page that matches nothing. A failed match
        // shows up on the next line instead, as no services.
        setMatching(created, [
            "PrimaryUsagePage": Self.appleVendorUsagePage,
            "PrimaryUsage": Self.temperatureSensorUsage,
        ] as CFDictionary)

        let matched = (copyServices(created)?.takeRetainedValue() as? [AnyObject]) ?? []

        // Names are read once. They describe the hardware, so they cannot change
        // while the app runs, and asking for them on every poll would be a round
        // trip apiece for constants.
        let copyProperty = dlsym(iokit, "IOHIDServiceClientCopyProperty")
            .map { unsafeBitCast($0, to: CopyProperty.self) }
        let allNames = matched.map { service in
            (copyProperty?(service, "Product" as CFString)?.takeRetainedValue() as? String) ?? ""
        }

        // Narrowed here rather than in the caller, because the cost is in the
        // reading rather than in the choosing. The rule and its consequences
        // live in TemperatureSelection.sensorsToRead, where they are tested.
        let kept = TemperatureSelection.sensorsToRead(named: allNames)
        services = kept.map { matched[$0] }
        names = kept.map { allNames[$0] }
    }

    /// Every sensor that answered this time round.
    public func readings() -> [SensorReading] {
        guard let copyEvent, let eventFloat else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return zip(services, names).compactMap { service, name in
            guard let event = copyEvent(service, Self.temperatureEventType, 0, 0)?.takeRetainedValue()
            else { return nil }
            return SensorReading(name: name, celsius: eventFloat(event, Self.temperatureField))
        }
    }
}
