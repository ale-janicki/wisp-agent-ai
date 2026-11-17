import Darwin
import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration
import WispCore

struct SystemSnapshot: Sendable {
    var cpu: CPUUsage?
    var load: [Double]
    var memory: MemoryBreakdown?
    var pressure: MemoryPressure?
    var swapUsed: UInt64
    var swapTotal: UInt64
    var volumes: [VolumeUsage]
    var temperature: TemperatureSummary
    var thermal: ThermalLevel
    var battery: BatteryStatus?
    var network: NetworkState?
    var processes: [ProcessSample]
}

struct NetworkState: Sendable {
    var interface: String
    var displayName: String?
    var address: String?
    var rate: NetworkRate?
}

actor SystemProbe {
    private let host = mach_host_self()
    private var kinds: [CoreKind?]?
    private var previousTicks: [CPUTicks]?
    private var previousCounters: (interface: String, counters: InterfaceCounters, at: Date)?
    private var interfaceNames: [String: String]?
    private var sensors: HIDTemperatureSensors?
    private var sensorsTried = false
    private var samples = 0
    private var cachedVolumes: [VolumeUsage] = []
    private var cachedBattery: BatteryStatus?
    private var cachedProcesses: [ProcessSample] = []

    private static let slowEvery = 15
    private static let processesEvery = 5

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    // MARK: Static facts

    func machine() -> MachineInfo {
        let model = Self.sysctlString("hw.model") ?? "Mac"
        let product = Self.deviceTreeData(path: "IODeviceTree:/product", key: "product-name").flatMap(MachineInfo.deviceTreeString)
        let info = ProcessInfo.processInfo
        return MachineInfo(
            name: product ?? model,
            modelIdentifier: model,
            chip: Self.sysctlString("machdep.cpu.brand_string") ?? "",
            osVersion: MachineInfo.version(info.operatingSystemVersion),
            osBuild: MachineInfo.build(fromVersionString: info.operatingSystemVersionString) ?? "",
            hostName: Self.sysctlString("kern.hostname") ?? info.hostName,
            bootTime: Self.bootTime() ?? Date().addingTimeInterval(-info.systemUptime)
        )
    }

    // MARK: Sample

    func sample() -> SystemSnapshot {
        defer { samples += 1 }
        let slow = samples % Self.slowEvery == 0
        if slow {
            cachedVolumes = Self.volumes()
            cachedBattery = Self.battery()
        }
        if samples % Self.processesEvery == 0 {
            cachedProcesses = Self.processes()
        }
        let swap = Self.swap()
        return SystemSnapshot(
            cpu: cpu(),
            load: Self.loadAverages(),
            memory: memory(),
            pressure: Self.sysctlInt32("kern.memorystatus_vm_pressure_level").flatMap(MemoryPressure.init(level:)),
            swapUsed: swap.used,
            swapTotal: swap.total,
            volumes: cachedVolumes,
            temperature: temperature(),
            thermal: ThermalLevel(rawValue: ProcessInfo.processInfo.thermalState.rawValue) ?? .nominal,
            battery: cachedBattery,
            network: network(),
            processes: cachedProcesses
        )
    }

    // MARK: CPU

    private func cpu() -> CPUUsage? {
        guard let ticks = Self.cpuTicks(host: host) else { return nil }
        if kinds == nil { kinds = Self.coreKinds(count: ticks.count) }
        defer { previousTicks = ticks }
        guard let previousTicks else { return nil }
        return CPUUsage.between(previousTicks, ticks, kinds: kinds ?? [])
    }

    private static func cpuTicks(host: host_t) -> [CPUTicks]? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { cpu in
            func tick(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[cpu * states + Int(state)]) }
            return CPUTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM), idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
        }
    }

    private static func coreKinds(count: Int) -> [CoreKind?] {
        var kinds = [CoreKind?](repeating: nil, count: count)
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return kinds }
        defer { IOObjectRelease(cpus) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return kinds }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let id = property(entry, "logical-cpu-id") as? Int, kinds.indices.contains(id),
                  let data = property(entry, "cluster-type") as? Data,
                  let type = MachineInfo.deviceTreeString(data)
            else { continue }
            kinds[id] = CoreKind(rawValue: type)
        }
        return kinds
    }

    private static func loadAverages() -> [Double] {
        var averages = [Double](repeating: 0, count: 3)
        let read = getloadavg(&averages, 3)
        return read == 3 ? averages : []
    }

    // MARK: Memory

    private func memory() -> MemoryBreakdown? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(Self.sysctlInt64("hw.pagesize") ?? 16_384)
        let counts = VMPageCounts(
            pageSize: pageSize,
            free: UInt64(stats.free_count),
            active: UInt64(stats.active_count),
            inactive: UInt64(stats.inactive_count),
            speculative: UInt64(stats.speculative_count),
            wired: UInt64(stats.wire_count),
            compressor: UInt64(stats.compressor_page_count),
            purgeable: UInt64(stats.purgeable_count),
            external: UInt64(stats.external_page_count),
            internalPages: UInt64(stats.internal_page_count)
        )
        return MemoryBreakdown(counts: counts, total: ProcessInfo.processInfo.physicalMemory)
    }

    private static func swap() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    // MARK: Disk

    private static let volumeKeys: [URLResourceKey] = [
        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey,
    ]

    private static func volumes() -> [VolumeUsage] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: volumeKeys, options: [.skipHiddenVolumes]) ?? []
        let all = urls.compactMap { url -> VolumeUsage? in
            guard let values = try? url.resourceValues(forKeys: Set(volumeKeys)),
                  values.volumeIsBrowsable ?? true,
                  let total = values.volumeTotalCapacity, total > 0
            else { return nil }
            let raw = UInt64(max(0, values.volumeAvailableCapacity ?? 0))
            return VolumeUsage(
                name: values.volumeName ?? url.lastPathComponent,
                path: url.path,
                total: UInt64(total),
                available: values.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? UInt64($0) : nil } ?? raw,
                availableRaw: raw,
                isBoot: values.volumeIsRootFileSystem ?? (url.path == "/")
            )
        }
        return VolumeUsage.ordered(all)
    }

    // MARK: Temperature

    private func temperature() -> TemperatureSummary {
        if !sensorsTried {
            sensorsTried = true
            sensors = HIDTemperatureSensors()
        }
        return TemperatureSummary(readings: sensors?.read() ?? [])
    }

    // MARK: Battery

    private static func battery() -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        let source = list.lazy
            .compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
            .first { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType }
        guard let source else { return nil }
        var registry: [String: Any] = [:]
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS {
                registry = properties?.takeRetainedValue() as? [String: Any] ?? [:]
            }
            IOObjectRelease(service)
        }
        return BatteryStatus.from(powerSource: source, registry: registry)
    }

    // MARK: Network

    private func network() -> NetworkState? {
        guard let interface = Self.primaryInterface() else {
            previousCounters = nil
            return nil
        }
        if interfaceNames == nil { interfaceNames = Self.interfaceDisplayNames() }
        let reading = Self.interfaceReading(interface)
        let now = Date()
        var rate: NetworkRate?
        if let counters = reading.counters {
            if let previous = previousCounters, previous.interface == interface {
                rate = NetworkRate.between(previous.counters, counters, seconds: now.timeIntervalSince(previous.at))
            }
            previousCounters = (interface, counters, now)
        }
        return NetworkState(interface: interface, displayName: interfaceNames?[interface], address: reading.address, rate: rate)
    }

    private static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Wisp" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return global["PrimaryInterface"] as? String
    }

    private static func interfaceDisplayNames() -> [String: String] {
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        var names: [String: String] = [:]
        for interface in interfaces {
            if let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
               let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                names[bsd] = name
            }
        }
        return names
    }

    private static func interfaceReading(_ name: String) -> (counters: InterfaceCounters?, address: String?) {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return (nil, nil) }
        defer { freeifaddrs(list) }
        var counters: InterfaceCounters?
        var address: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard String(cString: entry.ifa_name) == name, let addr = entry.ifa_addr else { continue }
            switch Int32(addr.pointee.sa_family) {
            case AF_LINK:
                if let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                    counters = InterfaceCounters(received: data.ifi_ibytes, sent: data.ifi_obytes)
                }
            case AF_INET where address == nil:
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    address = cString(host)
                }
            default:
                break
            }
        }
        return (counters, address)
    }

    // MARK: Processes

    private static func processes() -> [ProcessSample] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessTable.command[0])
        process.arguments = Array(ProcessTable.command.dropFirst())
        process.environment = ["LC_ALL": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessTable.parse(String(decoding: data, as: UTF8.self))
    }

    // MARK: sysctl / registry helpers

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let text = cString(buffer).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func cString(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    private static func sysctlInt64(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    private static func bootTime() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }

    private static func deviceTreeData(path: String, key: String) -> Data? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return property(entry, key) as? Data
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

private final class HIDTemperatureSensors {
    private typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloat = @convention(c) (AnyObject, Int32) -> Double
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?

    private static let temperatureEvent: Int64 = 15

    private let client: AnyObject
    private let copyEvent: CopyEvent
    private let getFloat: GetFloat
    private let services: [(name: String, service: AnyObject)]

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let create = symbol("IOHIDEventSystemClientCreate", as: Create.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatching.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEvent.self),
              let getFloat = symbol("IOHIDEventGetFloatValue", as: GetFloat.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }
        _ = setMatching(client, ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as CFDictionary)
        let list = copyServices(client)?.takeRetainedValue() as? [AnyObject] ?? []
        services = list.compactMap { service in
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String else { return nil }
            return (name, service)
        }
        guard !services.isEmpty else { return nil }
        self.client = client
        self.copyEvent = copyEvent
        self.getFloat = getFloat
    }

    func read() -> [SensorReading] {
        services.compactMap { name, service in
            guard let event = copyEvent(service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
            return SensorReading(name: name, celsius: getFloat(event, Int32(Self.temperatureEvent << 16)))
        }
    }
}
