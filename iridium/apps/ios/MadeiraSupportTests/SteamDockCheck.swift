import Foundation

// Compiled by ci/test_steam_dock.py with MadeiraSteamDock.swift. Arguments: a work
// folder holding the fixture archives the test wrote. The sign-in envelope is
// written to <work>/envelope.bin so the test can parse it with the host's own C
// reader (testrepos/madeira-dock/src/auth.c).
@main struct SteamDockCheck {
    static func expectFailure(_ what: String, _ body: () throws -> Void) {
        do { try body(); preconditionFailure(what + " was accepted") } catch {}
    }

    static func main() throws {
        let work = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fm = FileManager.default

        // Component archives: Windows names, stored and deflated members, folders.
        var files: [String: Data] = [:]
        try MadeiraSteamDock.unpack(Data(contentsOf: work.appendingPathComponent("good.zip"))) { files[$0] = $1 }
        precondition(files.keys.sorted() == ["bin/stored.dll", "deflated.txt"], "\(files.keys.sorted())")
        precondition(files["bin/stored.dll"] == Data("stored bytes".utf8))
        precondition(files["deflated.txt"] == Data(String(repeating: "steam ", count: 400).utf8))
        for bad in ["crc.zip", "traversal.zip", "duplicate.zip", "truncated.zip"] {
            expectFailure(bad) { try MadeiraSteamDock.unpack(Data(contentsOf: work.appendingPathComponent(bad))) { _, _ in } }
        }
        precondition(MadeiraSteamDock.crc32(Data("123456789".utf8)) == 0xcbf43926)

        // Registry: fixed discovery values only, earlier values replaced, idempotent.
        let user = "WINE REGISTRY Version 2\n;; All keys relative to \\\\User\\\\S-1-5-21\n\n#arch=win64\n\n"
            + "[Software\\\\Valve\\\\Steam] 1700000000\n#time=1d\n\"Language\"=\"english\"\n\"SteamPath\"=\"c:/program files (x86)/steam\"\n\n"
            + "[Software\\\\Wine] 1700000000\n\"Version\"=\"win10\"\n"
        let edited = try MadeiraSteamDock.registry(user, machine: false)
        precondition(edited.contains("\"SteamPath\"=\"C:\\\\Program Files (x86)\\\\Steam\""))
        precondition(!edited.contains("c:/program files (x86)/steam"))
        precondition(edited.contains("\"Language\"=\"english\""))
        precondition(edited.contains("[Software\\\\Valve\\\\Steam\\\\ActiveProcess]\n\"SteamClientDll\"="))
        precondition(edited.contains("\"SteamClientDll64\"=\"C:\\\\Program Files (x86)\\\\Steam\\\\steamclient64.dll\""))
        precondition(try MadeiraSteamDock.registry(edited, machine: false) == edited, "registry edit is not idempotent")
        let machine = try MadeiraSteamDock.registry("WINE REGISTRY Version 2\n", machine: true)
        precondition(machine.contains("[Software\\\\Wow6432Node\\\\Valve\\\\Steam]\n\"InstallPath\"="))
        precondition(!machine.contains("SteamPath"))
        expectFailure("duplicate key") { _ = try MadeiraSteamDock.registry(edited + "\n[Software\\\\Valve\\\\Steam] 1\n", machine: false) }
        expectFailure("non-Wine registry") { _ = try MadeiraSteamDock.registry("REGEDIT4\n", machine: false) }

        // Install record.
        let record = MadeiraSteamDock.manifest(appID: 480, name: "Space \"War\"", installDir: "Spacewar", buildID: 77,
                                               steamID: 76561197960389184,
                                               depots: [.init(depotId: 481, manifestId: "1234567890"),
                                                        .init(depotId: 0, manifestId: "1"), .init(depotId: 482, manifestId: "bad")])
        for line in ["\t\"appid\"\t\t\"480\"", "\t\"StateFlags\"\t\t\"4\"", "\t\"installdir\"\t\t\"Spacewar\"",
                     "\t\"buildid\"\t\t\"77\"", "\t\"TargetBuildID\"\t\t\"77\"", "\t\"name\"\t\t\"Space \\\"War\\\"\"",
                     "\t\t\"481\"", "\t\t\t\"manifest\"\t\t\"1234567890\"", "\t\"DownloadType\"\t\t\"1\""] {
            precondition(record.contains(line + "\n"), line)
        }
        precondition(!record.contains("\"482\"") && !record.contains("\t\t\"0\"\n"))
        precondition(MadeiraSteamDock.installFolder(name: "Half/Life: 2", appID: 220) == "HalfLife 2")
        precondition(MadeiraSteamDock.installFolder(name: "...", appID: 220) == "App 220")

        // Decision: Steam downloads only, iridium.cfg first, then the mode.
        let plain = work.appendingPathComponent("plain.exe")
        try Data(repeating: 0, count: 8).write(to: plain)
        let config = work.appendingPathComponent("iridium.cfg")
        try Data("steam-dock = on\nsteam-dock-launch-option = 2\n".utf8).write(to: config)
        func on(_ decision: MadeiraSteamDock.Decision) -> Bool { if case .on = decision { return true }; return false }
        precondition(!on(MadeiraSteamDock.decision(gameConfig: config, executable: plain, mode: .all, steamDownload: false)))
        precondition(on(MadeiraSteamDock.decision(gameConfig: config, executable: plain, mode: .off, steamDownload: true)))
        precondition(on(MadeiraSteamDock.decision(gameConfig: nil, executable: plain, mode: .all, steamDownload: true)))
        precondition(!on(MadeiraSteamDock.decision(gameConfig: nil, executable: plain, mode: .drm, steamDownload: true)))
        precondition(MadeiraSteamDock.launchOption(gameConfig: config) == 2 && MadeiraSteamDock.launchOption(gameConfig: nil) == 0)
        try Data("steam-dock = off\n".utf8).write(to: config)
        precondition(!on(MadeiraSteamDock.decision(gameConfig: config, executable: plain, mode: .all, steamDownload: true)))

        // Sign-in: the JWT subject selects the account; the envelope is the host's format.
        let payload = Data(#"{"sub":"76561197960389184","aud":["client"]}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let token = "eyJhbGciOiJFZERTQSJ9." + payload + ".c2lnbmF0dXJl"
        let steamID = try MadeiraSteamDock.subject(token)
        precondition(steamID == 76561197960389184)
        expectFailure("token without subject") { _ = try MadeiraSteamDock.subject("a.b") }
        let request = MadeiraSteamDock.Request(appID: 480, name: "Spacewar", account: "fixture_account", token: token, launchOption: 0)
        let envelope = try MadeiraSteamDock.envelope(account: request.account, token: token, steamID: steamID, appID: 480)
        try envelope.write(to: work.appendingPathComponent("envelope.bin"))
        expectFailure("account with a space") { _ = try MadeiraSteamDock.envelope(account: "a b", token: token, steamID: steamID, appID: 480) }
        expectFailure("non-individual SteamID") { _ = try MadeiraSteamDock.envelope(account: "a", token: token, steamID: 123, appID: 480) }

        let support = work.appendingPathComponent("Support", isDirectory: true)
        let guest = try MadeiraSteamDock.writeHandoff(request, steamID: steamID, support: support)
        let transfer = MadeiraSteamDock.handoffFile(support: support)!
        precondition(guest == "\\\\?\\unix" + transfer.path.replacingOccurrences(of: "/", with: "\\"))
        precondition(try Data(contentsOf: transfer) == envelope)
        precondition((try fm.attributesOfItem(atPath: transfer.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        _ = try MadeiraSteamDock.writeHandoff(request, steamID: steamID, support: support)   // replaces, never appends
        precondition(try Data(contentsOf: transfer) == envelope)
        MadeiraSteamDock.cleanup(support: support)
        precondition(!fm.fileExists(atPath: transfer.path))

        // Environment: switches and paths only; never the token, account or SteamID.
        let stage = MadeiraSteamDock.Stage(executable: MadeiraSteamDock.hostWindowsPath, command: "\"x\"", directory: "C:\\x",
                                           installPath: "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Spacewar")
        let environment = Dictionary(MadeiraSteamDock.environment(stage: stage, appID: 480, launchOption: 3, transfer: guest),
                                     uniquingKeysWith: { _, last in last })
        precondition(environment["MADEIRA_STEAM_HOST_PROBE"] == "1" && environment["MADEIRA_STEAM_HOST_LAUNCH"] == "1")
        precondition(environment["MADEIRA_STEAM_HOST_APPID"] == "480" && environment["MADEIRA_STEAM_HOST_LAUNCH_OPTION"] == "3")
        precondition(environment["MADEIRA_STEAM_HOST_EXPECTED_INSTALL"] == stage.installPath)
        precondition(environment["MADEIRA_STEAM_HOST_CLIENT_DIR"] == MadeiraSteamDock.windowsRoot)
        precondition(environment["MADEIRA_DOCK_AUTH_FILE"] == guest && environment["MADEIRA_DOCK_SESSION"] == "1")
        precondition(environment.keys.contains("MADEIRA_STEAM_HOST_ACCOUNT") && environment["MADEIRA_STEAM_HOST_ACCOUNT"]! == nil)
        precondition(environment["MADEIRA_STEAM_HOST_STEAMID"]! == nil)
        for value in environment.values.compactMap({ $0 }) {
            precondition(!value.contains(token) && !value.contains("fixture_account") && !value.contains(String(steamID)))
        }

        // Report: numeric allow-listed fields only; partial last line ignored.
        let report = MadeiraSteamDock.parseReport(Data((
            "[steam-host] ml1830 probe-start-bits=64\n[steam-host] ml1820 client-sha256=\(String(repeating: "a", count: 64))\n"
            + "[steam-host] ml1830 session-native-token-submitted=1\n[steam-host] ml9999 probe-result=0\n"
            + "[steam-host] ml1830 session-native-token-submitted=abc\n[steam-host] ml1830 secret-field=5\n"
            + "[steam-host] ml1830 probe-result=34").utf8))
        precondition(report.fields == ["probe-start-bits": "64", "client-sha256": String(repeating: "a", count: 64),
                                       "session-native-token-submitted": "1"], "\(report.fields)")
        precondition(report.result == nil && report.failure == nil && report.progress == "Signing in to Steam…")
        var failed = MadeiraSteamDock.Report(fields: ["probe-result": "34"])
        precondition(failed.failure?.hasPrefix("Steam did not finish signing in") == true)
        failed.fields["session-authenticated-online"] = "1"
        precondition(failed.failure?.contains("license") == true)
        precondition(MadeiraSteamDock.Report(fields: ["probe-result": "45", "launch-client-error": "5"]).failure?.contains("license") == true)
        precondition(MadeiraSteamDock.Report(fields: ["probe-result": "0"]).failure == nil)
        precondition(MadeiraSteamDock.Report(fields: ["probe-result": "41", "launch-install-directory-mismatch": "1"])
            .failure?.contains("install folder") == true)

        // Prefix: clones of the components, record, link, registry and host.
        let prefix = work.appendingPathComponent("prefix", isDirectory: true)
        let drive = prefix.appendingPathComponent("drive_c", isDirectory: true)
        try fm.createDirectory(at: drive.appendingPathComponent("IridiumGame"), withIntermediateDirectories: true)
        try Data("game".utf8).write(to: drive.appendingPathComponent("IridiumGame/game.exe"))
        try Data(user.utf8).write(to: prefix.appendingPathComponent("user.reg"))
        try Data("WINE REGISTRY Version 2\n".utf8).write(to: prefix.appendingPathComponent("system.reg"))
        let store = work.appendingPathComponent("store", isDirectory: true)
        try fm.createDirectory(at: store.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data("client".utf8).write(to: store.appendingPathComponent("steamclient64.dll"))
        try Data("tier0".utf8).write(to: store.appendingPathComponent("bin/tier0_s64.dll"))
        let client = MadeiraSteamDock.sha256(Data("client".utf8))
        let host = work.appendingPathComponent("dockhost.exe")
        try Data("MZ host".utf8).write(to: host)
        expectFailure("components without a ready marker") {
            _ = try MadeiraSteamDock.preparePrefix(prefix: prefix, appID: 480, name: "Spacewar", receipt: nil, steamID: steamID,
                                                   store: store, host: host, client: client)
        }
        try Data((client + "\n").utf8).write(to: store.appendingPathComponent(MadeiraSteamDock.readyMarker))
        // The desktop Steam Client mode's link is replaced by the real folder.
        let programFiles = drive.appendingPathComponent("Program Files (x86)", isDirectory: true)
        try fm.createDirectory(at: programFiles, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: programFiles.appendingPathComponent("Steam"), withDestinationURL: work)
        let receipt = try JSONDecoder().decode(MadeiraSteamDock.Receipt.self, from: Data(
            #"{"appId":480,"name":"Spacewar","directory":"/x","executables":["game.exe"],"buildId":"77","depots":[{"depotId":481,"manifestId":"99","authorizationAppId":480}]}"#.utf8))
        for _ in 0..<2 {
            let prepared = try MadeiraSteamDock.preparePrefix(prefix: prefix, appID: 480, name: "Spacewar", receipt: receipt,
                                                              steamID: steamID, store: store, host: host, client: client)
            precondition(prepared.installPath == "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Spacewar")
            precondition(prepared.executable == "C:\\IridiumPrerequisites\\dockhost.exe")
        }
        let steam = programFiles.appendingPathComponent("Steam", isDirectory: true)
        precondition((try steam.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true)
        precondition(try Data(contentsOf: steam.appendingPathComponent("bin/tier0_s64.dll")) == Data("tier0".utf8))
        precondition(!fm.fileExists(atPath: steam.appendingPathComponent(MadeiraSteamDock.readyMarker).path))
        let link = steam.appendingPathComponent("steamapps/common/Spacewar")
        precondition(try fm.destinationOfSymbolicLink(atPath: link.path) == "../../../../IridiumGame")
        precondition(fm.fileExists(atPath: link.appendingPathComponent("game.exe").path))
        let written = try String(contentsOf: steam.appendingPathComponent("steamapps/appmanifest_480.acf"), encoding: .utf8)
        precondition(written.contains("\t\t\t\"manifest\"\t\t\"99\"") && written.contains("\t\"buildid\"\t\t\"77\""))
        precondition(try String(contentsOf: prefix.appendingPathComponent("user.reg"), encoding: .utf8) == edited)
        precondition(try String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8).contains("InstallPath"))
        precondition(try Data(contentsOf: drive.appendingPathComponent("IridiumPrerequisites/dockhost.exe")) == Data("MZ host".utf8))
        // A different client build in the environment is never driven.
        try Data("other".utf8).write(to: steam.appendingPathComponent("steamclient64.dll"))
        expectFailure("unverified client") {
            _ = try MadeiraSteamDock.preparePrefix(prefix: prefix, appID: 480, name: "Spacewar", receipt: receipt,
                                                   steamID: steamID, store: store, host: host, client: client)
        }
        // A real folder where the game link goes is kept, not replaced.
        try fm.removeItem(at: steam.appendingPathComponent("steamclient64.dll"))
        try fm.removeItem(at: link)
        try fm.createDirectory(at: link, withIntermediateDirectories: true)
        expectFailure("real game folder") {
            _ = try MadeiraSteamDock.preparePrefix(prefix: prefix, appID: 480, name: "Spacewar", receipt: receipt,
                                                   steamID: steamID, store: store, host: host, client: client)
        }
        print("PASS Madeira Dock checks")
    }
}
