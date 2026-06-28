import Foundation
import FanCore

// Minimal command dispatch for the Phase 0 hardware spike.
//   fancurvectl status            live fan + GPU% + die temp (no sudo)
//   fancurvectl keys              dump every SMC key on this machine
//   fancurvectl temps             dump all T* temperature sensors
//   fancurvectl gpu [seconds]     stream GPU% (no sudo)
//   sudo fancurvectl spike --rpm N --seconds S [--no-ftst]
//                                 force fan to N RPM, hold, then restore auto

func arg(_ name: String, default def: Double) -> Double {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count, let v = Double(a[i + 1]) { return v }
    return def
}
func flag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

// gLoop + installFailsafes() live in Failsafe.swift (nonisolated so the C
// signal/atexit handlers can reach them under Swift 6 concurrency checking).

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "status"

func sampledGPU(intervalMs: UInt32 = 1000) -> Double {
    guard let gpu = try? IOReportGPU() else { return -1 }
    gpu.prime()
    usleep(intervalMs * 1000)
    return gpu.utilization()
}

switch command {

case "status":
    do {
        let smc = try SMC()
        let fan = SMCFan(smc: smc)
        let sensors = Sensors(smc: smc)
        let st = try fan.status()
        print("Fan")
        print("  count       \(st.fanCount)")
        print("  actual RPM  \(Int(st.actualRPM))")
        print("  min / max   \(Int(st.minRPM)) / \(Int(st.maxRPM))")
        print("  target RPM  \(Int(st.targetRPM))")
        print("  mode        \(st.mode == 1 ? "forced" : "auto") (\(st.mode))")
        print("  Ftst key    \(fan.hasFtstKey() ? "present" : "absent")")
        print("Thermals")
        print(String(format: "  die (proxy) %.1f °C", sensors.dieTemperature()))
        print("GPU")
        let g = sampledGPU()
        print(g < 0 ? "  utilization unavailable (IOReport)"
                    : String(format: "  utilization %.1f %%", g))
    } catch {
        FileHandle.standardError.write(Data("status failed: \(error)\n".utf8))
        exit(1)
    }

case "keys":
    do {
        let smc = try SMC()
        let keys = try smc.allKeys()
        print("\(keys.count) keys")
        print(keys.sorted().joined(separator: " "))
    } catch {
        FileHandle.standardError.write(Data("keys failed: \(error)\n".utf8))
        exit(1)
    }

case "temps":
    do {
        let sensors = try Sensors()
        for r in try sensors.temperatureReadings() {
            print(String(format: "  %@  %.1f °C", r.key, r.celsius))
        }
    } catch {
        FileHandle.standardError.write(Data("temps failed: \(error)\n".utf8))
        exit(1)
    }

case "gpu":
    let seconds = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 10) : 10
    guard let gpu = try? IOReportGPU() else {
        FileHandle.standardError.write(Data("IOReport unavailable\n".utf8)); exit(1)
    }
    gpu.prime()
    for _ in 0..<seconds {
        usleep(1_000_000)
        print(String(format: "GPU %.1f %%", gpu.utilization()))
    }

case "spike":
    let rpm = arg("--rpm", default: 4000)
    let seconds = arg("--seconds", default: 8)
    guard getuid() == 0 else {
        FileHandle.standardError.write(Data("spike requires root: sudo fancurvectl spike ...\n".utf8))
        exit(1)
    }
    do {
        let fan = try SMCFan()
        let before = try fan.status()
        print("before: actual \(Int(before.actualRPM)) RPM, mode \(before.mode), " +
              "range \(Int(before.minRPM))–\(Int(before.maxRPM))")
        print("forcing \(Int(rpm)) RPM for \(Int(seconds))s (Ftst unlock)…")
        try fan.setTargetRPM(rpm)
        for i in 1...Int(seconds) {
            usleep(1_000_000)
            let rpmNow = (try? fan.actualRPM()) ?? 0
            print("  t=\(i)s  actual \(Int(rpmNow)) RPM")
        }
        print("restoring automatic control…")
        try fan.restoreAuto()
        usleep(1_000_000)
        let after = try fan.status()
        print("after: actual \(Int(after.actualRPM)) RPM, mode \(after.mode) " +
              "(\(after.mode == 0 ? "auto ✓" : "still forced ✗"))")
    } catch {
        FileHandle.standardError.write(Data("spike failed: \(error)\n".utf8))
        // best-effort restore on any error
        try? SMCFan().restoreAuto()
        exit(1)
    }

case "log":
    // Characterize the STOCK fan controller: sample load + temp + RPM while
    // macOS runs the fan automatically. Emits CSV to stdout (redirect to a file).
    //   fancurvectl log [seconds]   (default: until Ctrl-C)
    let seconds = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) : nil
    do {
        let smc = try SMC()
        let fan = SMCFan(smc: smc)
        let sensors = Sensors(smc: smc)
        let cpu = CPU()
        let gpu = try? IOReportGPU()
        gpu?.prime()
        _ = cpu.utilization()   // establish CPU baseline

        FileHandle.standardError.write(Data("logging stock controller… Ctrl-C to stop\n".utf8))
        print("t_s,cpu_pct,gpu_pct,die_c,die_key,fan_rpm,fan_target,mode")
        let start = Date()
        var t = 0
        while seconds == nil || t < seconds! {
            usleep(1_000_000)
            t += 1
            let cpuPct = cpu.utilization()
            let gpuPct = gpu?.utilization() ?? -1
            let readings = (try? sensors.temperatureReadings()) ?? []
            let hottest = readings.first
            let st = try fan.status()
            let line = String(
                format: "%.0f,%.1f,%.1f,%.1f,%@,%.0f,%.0f,%.0f",
                Date().timeIntervalSince(start),
                cpuPct, gpuPct,
                hottest?.celsius ?? 0, hottest?.key ?? "?",
                st.actualRPM, st.targetRPM, st.mode)
            print(line)
            fflush(stdout)
        }
    } catch {
        FileHandle.standardError.write(Data("log failed: \(error)\n".utf8))
        exit(1)
    }

case "run":
    // Foreground control loop using max(gpuCurve, gpuTempCurve, dieTempCurve).
    // Loads the saved config if present, else calibrated defaults.
    //   sudo fancurvectl run             actively controls the fan (needs root)
    //        fancurvectl run --dry-run   observe only: shows the desired target
    //                                    next to Apple's actual RPM, no writes,
    //                                    no sudo, never enters forced mode.
    //        --calm / --responsive       override the saved ramp-dynamics profile
    //                                    for this session (A/B the wind-down feel).
    let dryRun = flag("--dry-run")
    guard dryRun || getuid() == 0 else {
        FileHandle.standardError.write(Data(
            "run requires root: sudo fancurvectl run   (or: fancurvectl run --dry-run)\n".utf8))
        exit(1)
    }
    do {
        var cfg = FileManager.default.fileExists(atPath: FanConfig.path)
            ? FanConfig.load() : FanConfig.defaults()
        cfg.enabled = true                      // running implies active control
        if flag("--calm") { cfg.profile = .calm }
        else if flag("--responsive") { cfg.profile = .responsive }
        let loop = try ControlLoop(config: cfg)
        let b = loop.bounds
        let d = cfg.dynamics
        let prof = "\(cfg.profile) (ema \(d.smoothing), slew +\(Int(d.slewUpRPMPerSec))/-\(Int(d.slewDownRPMPerSec)) rpm/s)"
        if dryRun {
            print("OBSERVE MODE — fan NOT controlled (built-in behavior). " +
                  "Ctrl-C to stop.  fan range \(Int(b.min))–\(Int(b.max)) RPM.")
            print("profile: \(prof)")
            print("  gpu%   gpuT°C  dieT°C  ->  desired  actual(builtin)")
        } else {
            gLoop = loop
            installFailsafes()
            print("control loop active (fan \(Int(b.min))–\(Int(b.max)) RPM). Ctrl-C to restore auto.")
            print("profile: \(prof)")
            print("  gpu%   gpuT°C  dieT°C  ->  target  actual")
        }
        while true {
            let t = try loop.step(dryRun: dryRun)
            print(String(format: "  %5.1f  %5.1f   %5.1f      %5.0f   %5.0f",
                         t.gpuPct, loop.smoothed.gpuTemp, t.dieTempC,
                         t.targetRPM, t.fanRPM))
            fflush(stdout)
            usleep(1_000_000)
        }
    } catch {
        gLoop?.restore()
        FileHandle.standardError.write(Data("run failed: \(error)\n".utf8))
        exit(1)
    }

case "install":
    guard getuid() == 0 else {
        FileHandle.standardError.write(Data("install requires root: sudo fancurvectl install\n".utf8))
        exit(1)
    }
    do {
        try Installer.install()
        print("installed: daemon running as \(Paths.daemonLabel). Launch the menu-bar app to control it.")
    } catch {
        FileHandle.standardError.write(Data("install failed: \(error)\n".utf8)); exit(1)
    }

case "uninstall":
    guard getuid() == 0 else {
        FileHandle.standardError.write(Data("uninstall requires root: sudo fancurvectl uninstall\n".utf8))
        exit(1)
    }
    do { try Installer.uninstall(); print("uninstalled; fan returned to automatic control.") }
    catch { FileHandle.standardError.write(Data("uninstall failed: \(error)\n".utf8)); exit(1) }

default:
    print("""
    usage:
      fancurvectl status
      fancurvectl keys
      fancurvectl temps
      fancurvectl gpu [seconds]
      fancurvectl log [seconds]      # CSV: characterize stock fan curve
      sudo fancurvectl run           # live control loop (max of 3 curves)
      fancurvectl run --dry-run      # observe only: desired vs built-in, no sudo
                  [--calm|--responsive]  # override ramp-dynamics profile
      sudo fancurvectl install       # install + start the LaunchDaemon
      sudo fancurvectl uninstall     # stop + remove the daemon
      sudo fancurvectl spike --rpm N --seconds S
    """)
}
