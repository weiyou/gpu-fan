import Foundation

/// Reads GPU active-residency ("GPU%") via the private IOReport framework,
/// with **no root required** — the same approach macmon/asitop use.
///
/// GPU utilization is derived from the "GPU Performance States" residency
/// counters: util = (total - idle) / total, measured as a delta between two
/// samples. The framework is loaded via `dlopen` so we need no private headers.
public final class IOReportGPU {

    // MARK: dlsym'd IOReport entry points

    private typealias CopyChannelsInGroup = @convention(c)
        (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription = @convention(c)
        (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
    private typealias CreateSamples = @convention(c)
        (AnyObject, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c)
        (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Iterate = @convention(c)
        (CFDictionary, @convention(block) (CFDictionary) -> Int32) -> Void
    private typealias ChannelGetSubGroup = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateGetCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateGetNameForIndex = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateGetResidency = @convention(c) (CFDictionary, Int32) -> Int64

    private let copyChannels: CopyChannelsInGroup
    private let createSub: CreateSubscription
    private let createSamples: CreateSamples
    private let createDelta: CreateSamplesDelta
    private let iterate: Iterate
    private let getSubGroup: ChannelGetSubGroup
    private let stateCount: StateGetCount
    private let stateName: StateGetNameForIndex
    private let stateResidency: StateGetResidency

    private let subscription: AnyObject
    private var subscribedChannels: CFMutableDictionary
    private var lastSample: CFDictionary?

    public enum IOReportError: Error { case loadFailed(String) }

    public init() throws {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else {
            throw IOReportError.loadFailed("dlopen libIOReport failed")
        }
        func sym<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let p = dlsym(handle, name) else {
                throw IOReportError.loadFailed("missing symbol \(name)")
            }
            return unsafeBitCast(p, to: T.self)
        }
        copyChannels   = try sym("IOReportCopyChannelsInGroup", CopyChannelsInGroup.self)
        createSub      = try sym("IOReportCreateSubscription", CreateSubscription.self)
        createSamples  = try sym("IOReportCreateSamples", CreateSamples.self)
        createDelta    = try sym("IOReportCreateSamplesDelta", CreateSamplesDelta.self)
        iterate        = try sym("IOReportIterate", Iterate.self)
        getSubGroup    = try sym("IOReportChannelGetSubGroup", ChannelGetSubGroup.self)
        stateCount     = try sym("IOReportStateGetCount", StateGetCount.self)
        stateName      = try sym("IOReportStateGetNameForIndex", StateGetNameForIndex.self)
        stateResidency = try sym("IOReportStateGetResidency", StateGetResidency.self)

        guard let chans = copyChannels("GPU Stats" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else {
            throw IOReportError.loadFailed("no GPU Stats channels")
        }
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let sub = createSub(nil, chans, &subbed, 0, nil)?.takeRetainedValue() else {
            throw IOReportError.loadFailed("IOReportCreateSubscription failed")
        }
        subscription = sub
        subscribedChannels = subbed?.takeRetainedValue() ?? chans
    }

    /// Take the first sample so a subsequent `utilization()` has a delta baseline.
    public func prime() {
        lastSample = createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue()
    }

    /// GPU utilization in percent (0–100) since the previous sample.
    /// Call `prime()` (or a prior `utilization()`) and wait an interval first.
    public func utilization() -> Double {
        guard let cur = createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue()
        else { return 0 }
        defer { lastSample = cur }
        guard let prev = lastSample,
              let delta = createDelta(prev, cur, nil)?.takeRetainedValue()
        else { return 0 }

        var idle: Int64 = 0
        var total: Int64 = 0
        let stateCount = self.stateCount
        let stateName = self.stateName
        let stateResidency = self.stateResidency
        let getSubGroup = self.getSubGroup

        iterate(delta) { channel in
            let subgroup = getSubGroup(channel)?.takeUnretainedValue() as String? ?? ""
            guard subgroup == "GPU Performance States" else { return 0 } // kIOReportIterOk
            let n = stateCount(channel)
            for i in 0..<n {
                let name = (stateName(channel, i)?.takeUnretainedValue() as String? ?? "").uppercased()
                let res = stateResidency(channel, i)
                guard res >= 0 else { continue }
                total += res
                if name.contains("IDLE") || name.contains("OFF") || name.contains("DOWN") {
                    idle += res
                }
            }
            return 0
        }

        guard total > 0 else { return 0 }
        let util = Double(total - idle) / Double(total) * 100.0
        return max(0, min(100, util))
    }
}
