import Foundation

/// Fan control for Apple Silicon, including the `Ftst` diagnostic-mode unlock
/// that M3/M4+ require before `thermalmonitord` will honor manual fan writes.
///
/// Sequence to take manual control of fan 0:
///   1. write `Ftst` = 1   (enter force/test mode)
///   2. write `F0Md` = 1   (mode -> forced)
///   3. write `F0Tg` = rpm (target)
/// To release: write `F0Md` = 0 (and `Ftst` = 0) -> Apple's controller resumes.
public final class SMCFan {

    private let smc: SMC

    // Single-fan machine (Mac mini): index 0 only.
    private let kFtst = "Ftst"     // force/test unlock
    private let kMode = "F0Md"     // 0 = auto, 1 = forced
    private let kTarget = "F0Tg"   // commanded RPM
    private let kActual = "F0Ac"   // measured RPM
    private let kMin = "F0Mn"      // min RPM for this machine
    private let kMax = "F0Mx"      // max RPM for this machine
    private let kCount = "FNum"    // number of fans

    public init(smc: SMC) {
        self.smc = smc
    }

    public convenience init() throws {
        self.init(smc: try SMC())
    }

    public struct FanStatus {
        public let fanCount: Int
        public let actualRPM: Double
        public let minRPM: Double
        public let maxRPM: Double
        public let targetRPM: Double
        public let mode: Double      // 0 auto, 1 forced (best-effort)
    }

    public func status() throws -> FanStatus {
        let count = (try? smc.readDouble(kCount)) ?? 1
        return FanStatus(
            fanCount: Int(count),
            actualRPM: (try? smc.readDouble(kActual)) ?? 0,
            minRPM: (try? smc.readDouble(kMin)) ?? 0,
            maxRPM: (try? smc.readDouble(kMax)) ?? 0,
            targetRPM: (try? smc.readDouble(kTarget)) ?? 0,
            mode: (try? smc.readDouble(kMode)) ?? 0
        )
    }

    public func actualRPM() throws -> Double { try smc.readDouble(kActual) }
    public func minRPM() throws -> Double { try smc.readDouble(kMin) }
    public func maxRPM() throws -> Double { try smc.readDouble(kMax) }

    /// Enter forced mode and command an RPM (clamped to [min, max]).
    /// Requires root.
    public func setTargetRPM(_ rpm: Double) throws {
        let lo = (try? minRPM()) ?? 0
        let hi = (try? maxRPM()) ?? rpm
        let clamped = max(lo, min(hi, rpm))

        // 1. unlock (best-effort: some machines may not expose Ftst)
        try? smc.writeUInt8(kFtst, 1)
        // 2. forced mode
        try smc.writeUInt8(kMode, 1)
        // 3. target
        try smc.writeDouble(kTarget, clamped)
    }

    /// Release manual control: revert to Apple's automatic fan controller.
    /// Safe to call repeatedly; used by the daemon's failsafe path.
    public func restoreAuto() throws {
        try? smc.writeUInt8(kMode, 0)
        try? smc.writeUInt8(kFtst, 0)
    }

    /// Probe whether `Ftst` exists on this machine (informational).
    public func hasFtstKey() -> Bool {
        (try? smc.keyInfo(kFtst)) != nil
    }
}
