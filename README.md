# GPU Fan

A menu-bar-only macOS app that drives the fan on **Apple Silicon** from **GPU
utilization** — not just temperature — so the machine stays cool and quiet
during sustained GPU work like local LLM inference.

Built and tuned on a **Mac mini M4 (Mac16,10)**, macOS 26.

---

## Why this exists

On Apple Silicon the CPU and GPU share one die, but macOS's built-in fan
controller effectively ramps off **CPU activity**, not GPU activity. Measured on
a Mac mini M4:

| Workload | GPU% | Die temp | Stock fan |
|---|---|---|---|
| ffmpeg (CPU-bound) | ~2% | 106–113 °C | ramps to **~2950 rpm** |
| local LLM (GPU-bound) | 100% | **108–115 °C** | stays pinned at **1000 rpm** |

Same die temperature, opposite fan behavior — under GPU load macOS prefers to
*throttle the GPU* rather than spin the fan, so the machine runs hot and slow.

GPU Fan fixes that: it reads GPU utilization (and temperatures) directly and runs
its own fan curve, ramping **proactively** when the GPU is busy.

## How it works

The fan target is the **maximum of three curves**, each on its own smoothed
input signal — so it's responsive to GPU load *and* never less aggressive than
macOS under any workload:

```
target_rpm = max( gpuCurve(GPU %),
                  gpuTempCurve(GPU-cluster °C),
                  dieTempCurve(die °C) )
```

- **`gpuCurve`** — the proactive feed-forward; ramps the fan as soon as the GPU
  gets busy, before the die heats up.
- **`gpuTempCurve`** — driven by the GPU cluster sensors (`Tg*`); a thermal
  backstop if the GPU genuinely gets hot.
- **`dieTempCurve`** — driven by the hottest die sensor (`TCMz`); calibrated to
  match macOS's own ramp so CPU-heavy work is never under-cooled.

The result is then EMA-smoothed, slew-rate-limited (no fan hunting), clamped to
the machine's real RPM range, and overridden to maximum above a hard temperature
ceiling. If anything goes wrong — a crash, a kill, an error — control always
reverts to macOS's automatic controller.

### Components

| Target | Role |
|---|---|
| `FanCore` | Shared library: SMC access, IOReport GPU%, sensors, curves, the control loop |
| `fancurved` | Root LaunchDaemon running the 1 Hz control loop with failsafes |
| `fancurvectl` | CLI: diagnostics, the install/uninstall, and a foreground/dry-run loop |
| `GpuFanApp` | Menu-bar app: live readout + enable toggle + draggable curve editor |

The app and daemon communicate via files in `/Library/Application Support/gpu-fan`:
the daemon publishes `telemetry.json` (read by the app) and hot-reloads
`config.json` (written by the app) whenever you edit a curve.

## Requirements

- Apple Silicon Mac (developed/tested on **Mac mini M4**)
- macOS 14+
- Xcode / Swift 6 toolchain to build

> **Note on fan control across models.** Fan SMC keys, sensor names, and the
> writable-fan unlock differ across Apple Silicon machines. On the Mac mini M4,
> writing `F0Md`/`F0Tg` works directly (no `Ftst` unlock needed) and the fan
> range is 1000–4900 rpm. On other models you may need to verify with the
> diagnostic commands below before relying on it.

## Build & install

```sh
swift build

# Install the control daemon (system LaunchDaemon, auto-starts at boot):
sudo .build/debug/fancurvectl install

# Package and run the menu-bar app:
sh scripts/package.sh
cp -R dist/GpuFan.app /Applications/
open /Applications/GpuFan.app
```

Then click the menu-bar icon and turn on **Active fan control**. Toggle
**Launch at login** to have the app return after a reboot (the daemon already
does, on its own).

To remove everything:

```sh
sudo .build/debug/fancurvectl uninstall   # stops the daemon, restores auto control
rm -rf /Applications/GpuFan.app
```

## CLI reference (`fancurvectl`)

| Command | Root? | Description |
|---|---|---|
| `status` | no | Fan RPM/range, die temp, GPU% snapshot |
| `keys` | no | Dump every SMC key on this machine |
| `temps` | no | All `T*` temperature sensors, hottest first |
| `gpu [seconds]` | no | Stream GPU utilization |
| `log [seconds]` | no | CSV of load + temp + RPM under the **stock** controller |
| `run` | yes | Live control loop in the foreground |
| `run --dry-run` | no | Observe: show desired RPM vs the built-in's actual, no writes |
| `spike --rpm N --seconds S` | yes | Force a fan speed briefly, then restore (hardware test) |
| `install` / `uninstall` | yes | Manage the LaunchDaemon |

`run --dry-run` is the safest way to preview a curve change: it computes the
target and shows it next to what macOS is actually doing, without touching the
fan or needing `sudo`.

## Tuning curves

Edit them live in the app: each tab (**GPU %**, **GPU °C**, **Die °C**) is a
draggable graph. Drag a point to reshape, double-click to add one, right-click to
delete. A dashed line and dot show where you're operating right now. Changes save
immediately and the daemon applies them within a second.

The defaults (in `Sources/FanCore/Config.swift`) were calibrated from on-device
logs to give: idle → 1000 rpm (silent), CPU load → ~2900 rpm (≈ macOS), GPU load
→ ~2450 rpm (quiet but cool). Reset to them anytime from the app.

## Safety

- The fan is never commanded below the machine's minimum or above its maximum.
- A hard die-temperature ceiling forces maximum RPM regardless of the curves.
- Output is slew-limited to avoid oscillation.
- The daemon restores macOS automatic control on **any** exit (SIGTERM from
  launchd, crash, or `Ctrl-C`), and `uninstall` does so explicitly.

## Caveats

- Uses private/undocumented interfaces (SMC fan writes, IOReport GPU metrics);
  these can change between macOS releases. They're isolated in `FanCore`.
- The app is **ad-hoc code-signed**, not notarized — first launch may need a
  right-click → Open, and it's intended for personal use.
- The shared config directory is world-writable so the unprivileged app can hand
  config to the root daemon — a deliberate, minor tradeoff for a single-user
  personal machine.

## Acknowledgements

Techniques referenced while building: the Apple Silicon SMC fan unlock research
in [agoodkind/macos-smc-fan](https://github.com/agoodkind/macos-smc-fan), GPU
metrics via IOReport as in [vladkens/macmon](https://github.com/vladkens/macmon),
and the menu-bar + daemon shape of
[ThermalForge](https://github.com/ProducerGuy/ThermalForge).

## License

MIT — see [LICENSE](LICENSE).
