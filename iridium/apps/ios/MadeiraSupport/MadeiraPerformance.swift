import Foundation

/// Two opt-in switches for CPU-bound games. Both are off by default, so a game
/// that is not changed behaves exactly as before.
///
/// - Relaxed CPU ordering: starts the x86 translator with `FEX_TSOENABLED=0`.
///   The translator then skips the extra memory-ordering work that x86 programs
///   assume. Faster, but FEX's own documentation says it is "highly likely to
///   break any multithreaded application" when disabled, so it is for testing.
/// - Quiet diagnostics: skips the two background samplers that suspend the
///   game's threads in bursts (`MADEIRA_NO_PROBES=1`). The cheap per-250 ms
///   `[xp]` CPU line stays, because it is what shows where the time goes.
///
/// Each switch is a Settings toggle and can be overridden for one game in its
/// `iridium.cfg` (`cpu-ordering = relaxed|strict`, `quiet-diagnostics = on|off`).
enum MadeiraPerformance {
    static let relaxedOrderingKey = "IridiumRelaxedCPUOrdering"
    static let quietDiagnosticsKey = "IridiumQuietDiagnostics"
    static let cpuOrderingConfigKey = "cpu-ordering"
    static let quietDiagnosticsConfigKey = "quiet-diagnostics"

    static let relaxedOrderingEnvironment = ("FEX_TSOENABLED", "0")
    static let quietDiagnosticsEnvironment = ("MADEIRA_NO_PROBES", "1")

    struct Settings: Equatable {
        var relaxedOrdering = false
        var quietDiagnostics = false

        /// Environment variables to set for the launch. Switches that are off
        /// contribute nothing, so an environment the developer set by hand stays.
        var environment: [(name: String, value: String)] {
            var rv: [(name: String, value: String)] = []
            if relaxedOrdering {
                rv.append((MadeiraPerformance.relaxedOrderingEnvironment.0, MadeiraPerformance.relaxedOrderingEnvironment.1))
            }
            if quietDiagnostics {
                rv.append((MadeiraPerformance.quietDiagnosticsEnvironment.0, MadeiraPerformance.quietDiagnosticsEnvironment.1))
            }
            return rv
        }
    }

    /// `true` / `false` for the accepted words, nil for anything else (so an
    /// unreadable value in iridium.cfg falls back to the Settings toggle).
    static func switchValue(_ text: String?, on: Set<String>, off: Set<String>) -> Bool? {
        guard let word = text?.trimmingCharacters(in: .whitespaces).lowercased(), !word.isEmpty else { return nil }
        if on.contains(word) { return true }
        if off.contains(word) { return false }
        return nil
    }

    static func relaxedOrdering(config text: String?) -> Bool? {
        switchValue(text, on: ["relaxed", "on", "true", "yes", "1"], off: ["strict", "off", "false", "no", "0"])
    }

    static func quietDiagnostics(config text: String?) -> Bool? {
        switchValue(text, on: ["on", "true", "yes", "1"], off: ["off", "false", "no", "0"])
    }

    /// The Settings toggles, with the game's iridium.cfg winning when it has a
    /// readable value for a key.
    static func settings(defaults: UserDefaults = .standard, gameConfig: URL?) -> Settings {
        var rv = Settings(relaxedOrdering: defaults.bool(forKey: relaxedOrderingKey),
                          quietDiagnostics: defaults.bool(forKey: quietDiagnosticsKey))
        if let gameConfig {
            if let value = relaxedOrdering(config: MadeiraGameConfig.value(cpuOrderingConfigKey, in: gameConfig)) {
                rv.relaxedOrdering = value
            }
            if let value = quietDiagnostics(config: MadeiraGameConfig.value(quietDiagnosticsConfigKey, in: gameConfig)) {
                rv.quietDiagnostics = value
            }
        }
        return rv
    }

    /// Sets the environment for the launch and returns one log line saying what
    /// was chosen. Call before the Wine server and the translator start.
    @discardableResult
    static func apply(_ settings: Settings) -> String {
        for item in settings.environment { setenv(item.name, item.value, 1) }
        return logLine(for: settings)
    }

    static func logLine(for settings: Settings) -> String {
        "[Launch] Performance switches: cpu-ordering=\(settings.relaxedOrdering ? "relaxed (FEX_TSOENABLED=0)" : "strict (default)"), "
            + "quiet-diagnostics=\(settings.quietDiagnostics ? "on (samplers off)" : "off (default)")."
    }
}
