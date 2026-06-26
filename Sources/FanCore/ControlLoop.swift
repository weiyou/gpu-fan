import Foundation

/// The fan control loop: reads GPU% / GPU-temp / die-temp each tick, smooths
/// them, evaluates `max(gpuCurve, gpuTempCurve, dieTempCurve)`, slew-limits the
/// result, and writes it to the fan in forced mode. Shared by `fancurvectl run`
/// (foreground testing) and the `fancurved` daemon.
///
/// Safety is structural: `restore()` reverts to Apple's automatic controller and
/// is invoked on stop, on error, and from the caller's signal/atexit handlers —
/// so a crash can never strand the fan at a fixed speed.
public final class ControlLoop {

    private let smc: SMC
    private let fan: SMCFan
    private let sensors: Sensors
    private let cpu: CPU
    private let gpu: IOReportGPU?

    public private(set) var config: FanConfig
    private let minRPM: Double
    private let maxRPM: Double

    // EMA state for each input signal
    private var emaGpuPct = 0.0
    private var emaGpuTemp = 0.0
    private var emaDieTemp = 0.0
    private var primed = false

    private var lastTarget: Double

    public init(config: FanConfig) throws {
        self.smc = try SMC()
        self.fan = SMCFan(smc: smc)
        self.sensors = Sensors(smc: smc)
        self.cpu = CPU()
        self.gpu = try? IOReportGPU()
        self.config = config

        let st = try fan.status()
        self.minRPM = st.minRPM > 0 ? st.minRPM : 1000
        self.maxRPM = st.maxRPM > 0 ? st.maxRPM : 4900
        self.lastTarget = minRPM

        gpu?.prime()
        _ = cpu.utilization()   // CPU baseline
    }

    public func update(config: FanConfig) {
        self.config = config
    }

    private func ema(_ prev: Double, _ x: Double) -> Double {
        let a = config.smoothing
        return prev + a * (x - prev)
    }

    /// Run one iteration. Returns telemetry for display/logging.
    /// Assumes ~1s between calls (slew limit is per-tick == per-second).
    ///
    /// When `dryRun` is true the desired target is computed and returned but the
    /// fan is **never written** — so you can observe Apple's built-in controller
    /// (the reported `fanRPM`) alongside what we would command. Dry-run requires
    /// no root and never enters forced mode.
    @discardableResult
    public func step(dryRun: Bool = false) throws -> Telemetry {
        // --- read raw signals ---
        let rawGpuPct = gpu?.utilization() ?? 0
        let cpuPct = cpu.utilization()           // for telemetry/observability
        let temps = sensors.snapshot()

        // --- smooth (seed on first tick to avoid a slow ramp from zero) ---
        if !primed {
            emaGpuPct = rawGpuPct; emaGpuTemp = temps.gpu; emaDieTemp = temps.die
            primed = true
        } else {
            emaGpuPct = ema(emaGpuPct, rawGpuPct)
            emaGpuTemp = ema(emaGpuTemp, temps.gpu)
            emaDieTemp = ema(emaDieTemp, temps.die)
        }

        // --- compute desired target from the three curves (always) ---
        let rpmGpu = config.gpuCurve.rpm(for: emaGpuPct)
        let rpmGpuTemp = config.gpuTempCurve.rpm(for: emaGpuTemp)
        let rpmDie = config.dieTempCurve.rpm(for: emaDieTemp)

        var target: Double
        var driver: String
        if emaDieTemp >= config.hardCeilingDieC {
            target = maxRPM; driver = "ceiling"               // safety override
        } else {
            target = max(rpmGpu, rpmGpuTemp, rpmDie)
            driver = target == rpmGpu ? "gpu%" : (target == rpmGpuTemp ? "gpuT" : "die")
        }
        target = min(maxRPM, max(minRPM, target))

        // --- slew limit ---
        let maxStep = config.maxSlewRPMPerSec
        if target > lastTarget + maxStep { target = lastTarget + maxStep }
        else if target < lastTarget - maxStep { target = lastTarget - maxStep }
        lastTarget = target

        let actual = (try? fan.actualRPM()) ?? 0
        _ = cpuPct  // available if we later expose CPU% in telemetry

        func telemetry(target: Double, forced: Bool, driver: String) -> Telemetry {
            Telemetry(gpuPct: emaGpuPct, gpuTempC: emaGpuTemp, dieTempC: emaDieTemp,
                      fanRPM: actual, targetRPM: target, forced: forced, driver: driver,
                      fanMinRPM: minRPM, fanMaxRPM: maxRPM)
        }

        // --- apply (unless observing) ---
        if dryRun {
            return telemetry(target: target, forced: false, driver: driver)
        }
        if !config.enabled {
            try fan.restoreAuto()
            return telemetry(target: 0, forced: false, driver: "off")
        }
        try fan.setTargetRPM(target)
        return telemetry(target: target, forced: true, driver: driver)
    }

    /// Revert to Apple's automatic fan control. Idempotent; safe in handlers.
    public func restore() {
        try? fan.restoreAuto()
    }

    public var bounds: (min: Double, max: Double) { (minRPM, maxRPM) }
    public var smoothed: (gpuPct: Double, gpuTemp: Double, dieTemp: Double) {
        (emaGpuPct, emaGpuTemp, emaDieTemp)
    }
}
