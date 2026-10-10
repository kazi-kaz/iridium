import Foundation

enum MadeiraJITPoolPolicy {
    static let preferenceKey = "IridiumJITPoolMB"
    static let automaticSafeLimitMB = 256

    static func effectiveLimitMB(requested: Int) -> Int {
        requested == 0 ? automaticSafeLimitMB : requested
    }

    /// Runs `body` with the preference holding the limit to use. `gameLimitMB` (a
    /// game's iridium.cfg jit-pool-mb) replaces the JIT Memory Limit setting;
    /// the stored setting is restored afterwards either way.
    static func withEffectiveLimit<T>(
        defaults: UserDefaults = .standard,
        gameLimitMB: Int? = nil,
        _ body: () -> T
    ) -> T {
        let stored = defaults.integer(forKey: preferenceKey)
        let effective = effectiveLimitMB(requested: gameLimitMB ?? stored)
        guard effective != stored else { return body() }

        let previous = defaults.object(forKey: preferenceKey)
        defaults.set(effective, forKey: preferenceKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: preferenceKey)
            } else {
                defaults.removeObject(forKey: preferenceKey)
            }
        }
        return body()
    }
}
