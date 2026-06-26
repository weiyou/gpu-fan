import Foundation

/// Temperature sensor access. Apple Silicon does not standardize SMC temp key
/// names across models, so we discover the machine's `T*` float keys at runtime
/// and let the caller pick which represent the die/GPU. For the die-temp signal
/// we use the hottest plausible sensor as a conservative proxy.
public final class Sensors {

    private let smc: SMC

    public init(smc: SMC) { self.smc = smc }

    public convenience init() throws { self.init(smc: try SMC()) }

    public struct Reading {
        public let key: String
        public let celsius: Double
    }

    /// All temperature-like sensors: `T`-prefixed keys decoding to a sane
    /// Celsius range. Returned sorted hottest-first.
    public func temperatureReadings() throws -> [Reading] {
        let keys = try smc.allKeys()
        var out: [Reading] = []
        for k in keys where k.hasPrefix("T") {
            guard let v = try? smc.readDouble(k) else { continue }
            // plausible on-die temperature window
            if v > 1, v < 130 { out.append(Reading(key: k, celsius: v)) }
        }
        return out.sorted { $0.celsius > $1.celsius }
    }

    /// Conservative die-temperature proxy: the hottest plausible sensor
    /// (on Mac16,10 this is typically `TCMz`/`Tp*`). Noisy — smooth before use.
    public func dieTemperature() -> Double {
        ((try? temperatureReadings())?.first?.celsius) ?? 0
    }

    /// GPU-cluster temperature: mean of the hottest few `Tg*` sensors.
    /// Empirically these are the GPU die sensors on Mac16,10 (~92°C under GPU
    /// load vs ~82°C under CPU load), making this the cleanest GPU thermal
    /// signal — far better than the overall hottest sensor.
    public func gpuTemperature(topK: Int = 4) -> Double {
        let tg = ((try? temperatureReadings()) ?? [])
            .filter { $0.key.hasPrefix("Tg") }
            .prefix(topK)
            .map(\.celsius)
        guard !tg.isEmpty else { return 0 }
        return tg.reduce(0, +) / Double(tg.count)
    }

    /// One pass over the SMC key table returning every reading, so a single
    /// scan can feed both `dieTemperature` and `gpuTemperature` per tick.
    public func snapshot() -> (die: Double, gpu: Double) {
        let readings = (try? temperatureReadings()) ?? []
        let die = readings.first?.celsius ?? 0
        let tg = readings.filter { $0.key.hasPrefix("Tg") }.prefix(4).map(\.celsius)
        let gpu = tg.isEmpty ? 0 : tg.reduce(0, +) / Double(tg.count)
        return (die, gpu)
    }
}
