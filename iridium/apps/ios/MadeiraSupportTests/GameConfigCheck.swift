import Foundation

@main struct GameConfigCheck {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("iridium-game-config-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents")
        let game = documents.appendingPathComponent("Games/Some Game")
        let steamGame = root.appendingPathComponent("SteamGames/pseudoregalia")
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
        try fm.createDirectory(at: steamGame, withIntermediateDirectories: true)
        try fm.createDirectory(at: documents.appendingPathComponent("GameConfigs"), withIntermediateDirectories: true)

        precondition(MadeiraGameConfig.fileName == MadeiraGamePreparation.gameConfigName)

        // No file anywhere: nothing to apply.
        precondition(MadeiraGameConfig.locate(gameRoot: game, documents: documents) == nil)
        precondition(MadeiraGameConfig.jitPoolMB(in: nil) == nil)

        // Same syntax and precedence as build/madeira_cfg.h.
        let text = "\u{FEFF}# per game\r\njit-pool-mb = 256\r\nenv.WINEDLLOVERRIDES = d3d9=n,b\r\njit-pool-mb=512\r\n"
        precondition(MadeiraGameConfig.value("jit-pool-mb", in: text) == "512")
        precondition(MadeiraGameConfig.value("env.WINEDLLOVERRIDES", in: text) == "d3d9=n,b")
        precondition(MadeiraGameConfig.value("missing", in: text) == nil)
        precondition(MadeiraGameConfig.value("first", in: "\u{FEFF}first = 1\n") == "1")

        let inGame = game.appendingPathComponent("iridium.cfg")
        try Data(text.utf8).write(to: inGame)
        precondition(MadeiraGameConfig.locate(gameRoot: game, documents: documents)?.path == inGame.path)
        precondition(MadeiraGameConfig.jitPoolMB(in: inGame) == 512)

        // Only the sizes the JIT helper accepts.
        try Data("jit-pool-mb = 300\n".utf8).write(to: inGame)
        precondition(MadeiraGameConfig.jitPoolMB(in: inGame) == nil)
        try Data("jit-pool-mb = big\n".utf8).write(to: inGame)
        precondition(MadeiraGameConfig.jitPoolMB(in: inGame) == nil)

        // Shared folder by game folder name, for games outside Files.
        let shared = documents.appendingPathComponent("GameConfigs/pseudoregalia.cfg")
        try Data("jit-pool-mb = 512\n".utf8).write(to: shared)
        precondition(MadeiraGameConfig.locate(gameRoot: steamGame, documents: documents)?.path == shared.path)
        precondition(MadeiraGameConfig.jitPoolMB(in: shared) == 512)

        // The game folder's file wins over the shared folder.
        let sameName = documents.appendingPathComponent("GameConfigs/Some Game.cfg")
        try Data("jit-pool-mb = 128\n".utf8).write(to: sameName)
        precondition(MadeiraGameConfig.locate(gameRoot: game, documents: documents)?.path == inGame.path)

        print("PASS: per-game config location, syntax, and JIT pool size")
    }
}
