import Foundation

@main struct PerformanceSwitchCheck {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("iridium-performance-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let suite = "iridium-performance-check-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Everything is off by default and contributes no environment.
        let off = MadeiraPerformance.settings(defaults: defaults, gameConfig: nil)
        precondition(off == MadeiraPerformance.Settings())
        precondition(!off.relaxedOrdering && !off.quietDiagnostics)
        precondition(off.environment.isEmpty)

        // The Settings toggles.
        defaults.set(true, forKey: MadeiraPerformance.relaxedOrderingKey)
        var on = MadeiraPerformance.settings(defaults: defaults, gameConfig: nil)
        precondition(on.relaxedOrdering && !on.quietDiagnostics)
        precondition(on.environment.map { $0.name } == ["FEX_TSOENABLED"])
        precondition(on.environment.map { $0.value } == ["0"])
        defaults.set(true, forKey: MadeiraPerformance.quietDiagnosticsKey)
        on = MadeiraPerformance.settings(defaults: defaults, gameConfig: nil)
        precondition(on.environment.map { $0.name } == ["FEX_TSOENABLED", "MADEIRA_NO_PROBES"])
        precondition(on.environment.map { $0.value } == ["0", "1"])

        // The game's iridium.cfg wins, in either direction.
        let cfg = root.appendingPathComponent("iridium.cfg")
        try Data("# per game\ncpu-ordering = strict\nquiet-diagnostics = off\n".utf8).write(to: cfg)
        let strict = MadeiraPerformance.settings(defaults: defaults, gameConfig: cfg)
        precondition(!strict.relaxedOrdering && !strict.quietDiagnostics)
        defaults.removeObject(forKey: MadeiraPerformance.relaxedOrderingKey)
        defaults.removeObject(forKey: MadeiraPerformance.quietDiagnosticsKey)
        try Data("cpu-ordering = relaxed\nquiet-diagnostics = on\n".utf8).write(to: cfg)
        let forced = MadeiraPerformance.settings(defaults: defaults, gameConfig: cfg)
        precondition(forced.relaxedOrdering && forced.quietDiagnostics)

        // An unreadable or missing value falls back to the Settings toggle.
        defaults.set(true, forKey: MadeiraPerformance.relaxedOrderingKey)
        try Data("cpu-ordering = maybe\nquiet-diagnostics =\n".utf8).write(to: cfg)
        let fallback = MadeiraPerformance.settings(defaults: defaults, gameConfig: cfg)
        precondition(fallback.relaxedOrdering && !fallback.quietDiagnostics)
        precondition(MadeiraPerformance.relaxedOrdering(config: " Relaxed ") == true)
        precondition(MadeiraPerformance.relaxedOrdering(config: "STRICT") == false)
        precondition(MadeiraPerformance.relaxedOrdering(config: nil) == nil)
        precondition(MadeiraPerformance.quietDiagnostics(config: "yes") == true)
        precondition(MadeiraPerformance.quietDiagnostics(config: "relaxed") == nil)

        // apply() sets only what is on and leaves a hand-set environment alone.
        unsetenv("FEX_TSOENABLED"); unsetenv("MADEIRA_NO_PROBES")
        let none = MadeiraPerformance.apply(MadeiraPerformance.Settings())
        precondition(getenv("FEX_TSOENABLED") == nil && getenv("MADEIRA_NO_PROBES") == nil)
        precondition(none.contains("strict (default)") && none.contains("quiet-diagnostics=off"))
        setenv("FEX_TSOENABLED", "1", 1)
        _ = MadeiraPerformance.apply(MadeiraPerformance.Settings())
        precondition(String(cString: getenv("FEX_TSOENABLED")) == "1")
        let line = MadeiraPerformance.apply(MadeiraPerformance.Settings(relaxedOrdering: true, quietDiagnostics: true))
        precondition(String(cString: getenv("FEX_TSOENABLED")) == "0")
        precondition(String(cString: getenv("MADEIRA_NO_PROBES")) == "1")
        precondition(line.contains("relaxed (FEX_TSOENABLED=0)") && line.contains("samplers off"))
        unsetenv("FEX_TSOENABLED"); unsetenv("MADEIRA_NO_PROBES")

        // The status line.
        precondition(MadeiraStatusLine.thermalName(.nominal) == "nominal")
        precondition(MadeiraStatusLine.thermalName(.serious) == "serious")
        precondition(MadeiraStatusLine.format(thermal: "fair", lowPower: true, usedBytes: 2_147_483_648,
                                              availableBytes: nil, seconds: 12.4)
                     == "[Status] +12s thermal=fair lowPower=on footprint=2048MB available=n/a")
        precondition(MadeiraStatusLine.format(thermal: "nominal", lowPower: false, usedBytes: nil,
                                              availableBytes: 3_791_000_000, seconds: 5)
                     == "[Status] +5s thermal=nominal lowPower=off footprint=n/a available=3615MB")
        print("Performance switch checks passed")
    }
}
