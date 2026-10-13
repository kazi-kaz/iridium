import Foundation

/// A game's own configuration, layered on top of the global madeira.cfg.
///
/// Iridium looks for `iridium.cfg` in the game's folder first (Files: Iridium >
/// Games > the game). Games outside the Files-visible library, such as Steam
/// installs, can use `Documents/GameConfigs/<game folder name>.cfg` instead.
/// The file uses madeira.cfg syntax; every key it sets, including `env.` lines,
/// wins over madeira.cfg for that game only. Iridium itself reads
/// `jit-pool-mb` (128, 256, 512 or 1024), which replaces the JIT Memory Limit setting
/// for this game, and `steam-client` / `steam-client-args` (MadeiraSteamClient).
/// The native readers find the file through MADEIRA_GAME_CFG
/// (build/madeira_cfg.h). Game preparation leaves iridium.cfg out of the
/// isolated game copy, so editing it never triggers a copy update.
enum MadeiraGameConfig {
    static let fileName = "iridium.cfg"   // MadeiraGamePreparation.gameConfigName
    static let sharedFolderName = "GameConfigs"
    static let environmentKey = "MADEIRA_GAME_CFG"
    static let jitPoolKey = "jit-pool-mb"
    static let allowedJITPoolMB: Set<Int> = [128, 256, 512, 1024]

    static func locate(gameRoot: URL, documents: URL? = defaultDocuments()) -> URL? {
        let fm = FileManager.default
        let inGame = gameRoot.appendingPathComponent(fileName)
        if fm.isReadableFile(atPath: inGame.path) { return inGame }
        guard let documents else { return nil }
        let shared = documents.appendingPathComponent(sharedFolderName, isDirectory: true)
            .appendingPathComponent(gameRoot.lastPathComponent + ".cfg")
        return fm.isReadableFile(atPath: shared.path) ? shared : nil
    }

    static func defaultDocuments() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// The value of `key`, following madeira_cfg.h: '#' comments, trimmed key and
    /// value, value may contain '=', the last occurrence wins.
    static func value(_ key: String, in text: String) -> String? {
        var found: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = (raw.hasPrefix("\u{FEFF}") ? String(raw.dropFirst()) : raw)
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            guard line[..<eq].trimmingCharacters(in: .whitespaces) == key else { continue }
            found = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return found
    }

    static func value(_ key: String, in file: URL) -> String? {
        guard let data = try? Data(contentsOf: file), data.count <= 64 * 1024,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return value(key, in: text)
    }

    /// The game's JIT pool size, or nil to use the JIT Memory Limit setting.
    static func jitPoolMB(in file: URL?) -> Int? {
        guard let file, let text = value(jitPoolKey, in: file), let mb = Int(text),
              allowedJITPoolMB.contains(mb) else { return nil }
        return mb
    }
}
