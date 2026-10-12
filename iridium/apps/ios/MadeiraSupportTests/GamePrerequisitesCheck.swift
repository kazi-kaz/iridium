import Foundation

@main struct GamePrerequisitesCheck {
    static func main() throws {
        let script = Data(#"""
        // Repeated Run Process sections must not replace each other.
        "InstallScript" {
          "Run Process" { "Runtime" {
            "HasRunKey" "HKLM\\Software\\Example"
            "MinimumHasRunValue" "3"
            "Process 2" "%INSTALLDIR%/redist/Second.msi"
            "Command 2" "/quiet"
            "Process 1" "%INSTALLDIR%\\redist\\First.exe"
            "Command 1" "/path \"%INSTALLDIR%\""
          } }
          "Run Process" { "Runtime" {
            "HasRunKey" "HKLM\\Software\\Example"
            "MinimumHasRunValue" "3"
            "Process 10" "%INSTALLDIR%\\redist\\Third.exe"
          } }
          "Run Process" { "User" {
            "HasRunKey" "HKEY_CURRENT_USER\\Software\\Example"
            "Process 1" "%INSTALLDIR%\\redist\\First.exe"
          } }
        }
        """#.utf8)
        let processes = try IridiumSteamInstallScript.processes(script: script, installDir: "C:\\IridiumGame", appID: 42)
        precondition(processes.count == 4)
        precondition(processes[0].executable.hasSuffix("First.exe"))
        precondition(processes[1].executable.hasSuffix("Second.msi"))
        precondition(processes[2].executable.hasSuffix("Third.exe"))
        precondition(processes[0].arguments == "/path \"C:\\IridiumGame\"")
        precondition(processes[0].run.value == 3)
        precondition(IridiumSteamInstallScript.keys(processes[0].run) == ["Software\\Example", "Software\\Wow6432Node\\Example"])
        precondition(processes[3].run.hive == .user && IridiumSteamInstallScript.keys(processes[3].run).count == 1)
        var explicit = processes[0].run
        explicit.key = "Software\\Wow6432Node\\Example"
        precondition(IridiumSteamInstallScript.keys(explicit).count == 1)
        let old = "[Software\\\\Wow6432Node\\\\Example] 1\n\"runtime\"=dword:00000002\n"
        let done = old.replacingOccurrences(of: "00000002", with: "00000003")
        precondition(!IridiumSteamInstallScript.marked(processes[0].run, in: old))
        precondition(IridiumSteamInstallScript.marked(processes[0].run, in: done))
        let noKey = Data(#"""
        "InstallScript" { "Run Process" { "Custom" { "Process 1" "%INSTALLDIR%\\Setup.exe" } } }
        """#.utf8)
        let manual = try IridiumSteamInstallScript.processes(script: noKey, installDir: "C:\\IridiumGame")
        precondition(manual.count == 1 && manual[0].run.key == "Software\\Iridium\\Prerequisites")
        let native = try IridiumSteamInstallScript.processes(script: noKey, installDir: "C:\\IridiumGame", appID: 42)
        precondition(native[0].run.key == "Software\\Valve\\Steam\\Apps\\42")
        for bad in [
            String(decoding: noKey, as: UTF8.self).dropLast(),
            Substring(String(decoding: noKey, as: UTF8.self).replacingOccurrences(of: "Setup.exe", with: "Setup.bat")),
            Substring(String(decoding: script, as: UTF8.self).replacingOccurrences(of: "Second.msi", with: "Second.cmd")),
            Substring(String(decoding: script, as: UTF8.self).replacingOccurrences(of: "MinimumHasRunValue\" \"3", with: "MinimumHasRunValue\" \"invalid")),
        ] {
            do {
                _ = try IridiumSteamInstallScript.processes(script: Data(bad.utf8), installDir: "C:\\IridiumGame")
                preconditionFailure("An incomplete or invalid installer group was accepted")
            } catch { }
        }
        let completedUnsupported = try IridiumSteamInstallScript.processes(
            script: Data(String(decoding: noKey, as: UTF8.self).replacingOccurrences(of: "Setup.exe", with: "Setup.bat").utf8),
            installDir: "C:\\IridiumGame", completed: { _ in true })
        precondition(completedUnsupported.isEmpty)
        // KeyValues conditionals: a value for another platform is dropped, not misread as a key.
        let conditional = Data(#"""
        "InstallScript" { "Run Process" { "Cond" [$WIN32] {
          "Process 1" "%INSTALLDIR%\\Setup.exe" [$WIN32]
          "Command 1" "/quiet"
          "Command 1" "/mac" [$OSX]
          "Process 2" "%INSTALLDIR%\\Mac.exe" [$OSX||$LINUX]
        } } }
        """#.utf8)
        let conditioned = try IridiumSteamInstallScript.processes(script: conditional, installDir: "C:\\IridiumGame", appID: 42)
        precondition(conditioned.count == 1 && conditioned[0].executable.hasSuffix("Setup.exe") && conditioned[0].arguments == "/quiet")
        precondition(IridiumSteamInstallScript.windowsCondition("[!$X360]") && !IridiumSteamInstallScript.windowsCondition("[$WIN64&&$OSX]"))
        do {
            _ = try IridiumSteamInstallScript.processes(script: Data(String(decoding: noKey, as: UTF8.self)
                .replacingOccurrences(of: "Setup.exe", with: "Setup.bat").utf8), installDir: "C:\\IridiumGame")
            preconditionFailure("A batch file was accepted")
        } catch {
            precondition(error.localizedDescription.contains("Setup.bat"), "the failure names what was rejected")
        }
        let text = try IridiumGamePrerequisites.configuration(processes, executable: "C:\\IridiumGame\\Game.exe",
            arguments: ["", "two words", "quote\"here", "C:\\end\\", "&not-a-shell", "雪"])
        precondition(text.contains("runs=2\r\n") && text.contains("processes=3\r\n"))
        precondition(text.contains("executable=xC:\\windows\\system32\\msiexec.exex\r\n"))
        precondition(text.contains(" /i \"C:\\IridiumGame\\redist\\Second.msi\" /quiet"))
        precondition(MadeiraLaunchArguments.quoteWindowsArgument("C:\\end\\") == "\"C:\\end\\\\\"")
        var invalid = processes[0]
        invalid.run.name = "bad\n[game]"
        do { _ = try IridiumGamePrerequisites.configuration([invalid], executable: "C:\\Game.exe", arguments: []); preconditionFailure("INI injection accepted") }
        catch { }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let prefix = root.appendingPathComponent("prefix")
        let game = prefix.appendingPathComponent("drive_c/IridiumGame")
        let resourcesURL = root.appendingPathComponent("Resources.bundle")
        for path in ["ControllerRuntime/aarch64/iridium-prerequisites.exe", "i386-windows/ntdll.dll", "i386-windows/fusion.dll", "fonts/tahoma.ttf"] {
            let file = resourcesURL.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("MZfixture".utf8).write(to: file)
        }
        let resources = Bundle(path: resourcesURL.path)!
        try IridiumGamePrerequisites.installFonts(prefix: prefix, resources: resources)
        let font = prefix.appendingPathComponent("drive_c/windows/fonts/tahoma.ttf")
        let installedFont = try Data(contentsOf: font)
        precondition(installedFont == Data("MZfixture".utf8))
        try Data("custom font".utf8).write(to: font)
        try IridiumGamePrerequisites.installFonts(prefix: prefix, resources: resources)
        let preservedFont = try Data(contentsOf: font)
        precondition(preservedFont == Data("custom font".utf8))
        try fm.createDirectory(at: prefix.appendingPathComponent("drive_c/windows/system32"), withIntermediateDirectories: true)
        try Data("MZfixture".utf8).write(to: prefix.appendingPathComponent("drive_c/windows/system32/msiexec.exe"))
        try fm.createDirectory(at: game.appendingPathComponent("redist"), withIntermediateDirectories: true)
        for name in ["system.reg", "user.reg"] { try Data("WINE REGISTRY Version 2\n".utf8).write(to: prefix.appendingPathComponent(name)) }
        let save = game.appendingPathComponent("save.dat")
        try Data("keep my save".utf8).write(to: save)
        let ordinary = try IridiumGamePrerequisites.prepare(prefix: prefix, executable: "C:\\IridiumGame\\Game.exe",
            arguments: [], appID: nil, resources: resources)
        precondition(ordinary == nil)
        try script.write(to: game.appendingPathComponent("installscript.vdf"))
        for name in ["First.exe", "Second.msi", "Third.exe"] { try Data("MZfixture".utf8).write(to: game.appendingPathComponent("redist/" + name)) }
        let launch = try IridiumGamePrerequisites.prepare(prefix: prefix, executable: "C:\\IridiumGame\\Game.exe",
            arguments: ["two words"], appID: 42, resources: resources)!
        let statusFile = prefix.appendingPathComponent("drive_c/IridiumPrerequisites/status.txt")
        precondition(IridiumGamePrerequisites.status(prefix: prefix) == nil)
        for (state, expected) in [("services", "Starting Windows installer services…"),
                                   ("game", "Starting the game. Waiting for display output…")] {
            try Data(state.utf8).write(to: statusFile)
            precondition(IridiumGamePrerequisites.status(prefix: prefix) == expected)
        }
        try Data("installer 1 2 3 4".utf8).write(to: statusFile)
        precondition(IridiumGamePrerequisites.status(prefix: prefix)?.contains("1 of 2, step 3 of 4") == true)
        for invalid in ["installer 0 2 3 4", "installer 3 2 3 4", "installer 1 65 3 4", "installer 1 2 5 4", "incomplete", String(repeating: "x", count: 256)] {
            try Data(invalid.utf8).write(to: statusFile)
            precondition(IridiumGamePrerequisites.status(prefix: prefix) == nil)
        }
        precondition(launch.installerCount == 2)
        let encoded = try Data(contentsOf: prefix.appendingPathComponent("drive_c/IridiumPrerequisites/installers.ini"))
        precondition(encoded.starts(with: [0xff, 0xfe]))
        let savedData = try Data(contentsOf: save)
        precondition(savedData == Data("keep my save".utf8))
        let fusion = prefix.appendingPathComponent("drive_c/windows/Microsoft.NET/Framework/v2.0.50727/fusion.dll")
        try Data("custom fusion".utf8).write(to: fusion)
        _ = try IridiumGamePrerequisites.prepare(prefix: prefix, executable: "C:\\IridiumGame\\Game.exe",
            arguments: [], appID: 42, resources: resources)
        let customFusion = try Data(contentsOf: fusion)
        precondition(customFusion == Data("custom fusion".utf8))
        try IridiumGamePrerequisites.cancel(prefix: prefix)
        precondition(fm.fileExists(atPath: prefix.appendingPathComponent("drive_c/IridiumPrerequisites/cancel.flag").path))
        try Data(done.utf8).write(to: prefix.appendingPathComponent("system.reg"))
        try Data("[Software\\\\Example] 1\n\"user\"=dword:00000001\n".utf8).write(to: prefix.appendingPathComponent("user.reg"))
        let recorded = try IridiumGamePrerequisites.prepare(prefix: prefix, executable: "C:\\IridiumGame\\Game.exe",
            arguments: [], appID: 42, resources: resources)
        precondition(recorded == nil)
        let shared = root.appendingPathComponent("SteamGames/228980/default/content")
        try fm.createDirectory(at: shared.appendingPathComponent("_CommonRedist"), withIntermediateDirectories: true)
        try noKey.write(to: shared.appendingPathComponent("_CommonRedist/installscript.vdf"))
        try Data("MZfixture".utf8).write(to: shared.appendingPathComponent("Setup.exe"))
        precondition(IridiumGamePrerequisites.sharedRoots(gameRoot: game, nativeSteamInstall: false,
            steamGamesRoot: root.appendingPathComponent("SteamGames")).isEmpty)
        let sharedRoots = IridiumGamePrerequisites.sharedRoots(gameRoot: game, nativeSteamInstall: true,
            steamGamesRoot: root.appendingPathComponent("SteamGames"))
        precondition(sharedRoots.map { $0.resolvingSymlinksInPath().path } == [shared.resolvingSymlinksInPath().path])
        let sharedLaunch = try IridiumGamePrerequisites.prepare(prefix: prefix, executable: "C:\\IridiumGame\\Game.exe",
            arguments: [], appID: 42, sharedRoots: sharedRoots, resources: resources)
        precondition(sharedLaunch?.installerCount == 1)
        // An unreadable shared script skips its own installers and is reported; the launch goes on.
        let badShared = shared.appendingPathComponent("_CommonRedist/Other/installscript.vdf")
        try fm.createDirectory(at: badShared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(String(decoding: noKey, as: UTF8.self).replacingOccurrences(of: "Setup.exe", with: "Setup.bat").utf8).write(to: badShared)
        var skippedScripts: [String] = []
        let partialLaunch = try IridiumGamePrerequisites.prepare(prefix: prefix, executable: "C:\\IridiumGame\\Game.exe",
            arguments: [], appID: 42, sharedRoots: sharedRoots, resources: resources,
            skipped: { name, _ in skippedScripts.append(name) })
        precondition(partialLaunch?.installerCount == 1)
        precondition(skippedScripts == ["Steamworks Shared: _CommonRedist/Other/installscript.vdf"], "\(skippedScripts)")
        try fm.removeItem(at: badShared)
        // Steam's DirectX redistributable is skipped and reported; Wine provides DirectX.
        let directX = shared.appendingPathComponent("_CommonRedist/DirectX/Jun2010")
        try fm.createDirectory(at: directX, withIntermediateDirectories: true)
        try Data(#"""
        "InstallScript" { "Run Process" { "DirectX" {
          "HasRunKey" "HKEY_LOCAL_MACHINE\\Software\\Valve\\Steam\\Apps\\CommonRedist\\DirectX\\Jun2010"
          "process 1" "%INSTALLDIR%\\_CommonRedist\\DirectX\\Jun2010\\DXSETUP.exe"
          "command 1" "/silent"
        } } }
        """#.utf8).write(to: directX.appendingPathComponent("installscript.vdf"))
        skippedScripts = []
        let directXLaunch = try IridiumGamePrerequisites.prepare(prefix: prefix, executable: "C:\\IridiumGame\\Game.exe",
            arguments: [], appID: 42, sharedRoots: sharedRoots, resources: resources,
            skipped: { name, _ in skippedScripts.append(name) })
        precondition(directXLaunch?.installerCount == 1)
        precondition(skippedScripts == ["Steamworks Shared: _CommonRedist/DirectX/Jun2010/installscript.vdf"], "\(skippedScripts)")
        precondition(IridiumGamePrerequisites.isDirectXSetup("C:\\IridiumGame\\_CommonRedist\\DirectX\\Jun2010\\DXSETUP.exe"))
        precondition(!IridiumGamePrerequisites.isDirectXSetup("C:\\IridiumGame\\redist\\Setup.exe"))
        try fm.removeItem(at: directX)
        precondition(IridiumGamePrerequisites.resolve("C:\\IridiumPrerequisites\\shared1\\setup.EXE", drive: prefix.appendingPathComponent("drive_c")) != nil)
        precondition(IridiumGamePrerequisites.resolve("C:\\..\\save.dat", drive: prefix.appendingPathComponent("drive_c")) == nil)

        // A file chosen in Game Options must survive prefix creation and JIT relaunch.
        let manualPrefix = root.appendingPathComponent("manual-prefix")
        var pe = Data(repeating: 0, count: 68)
        pe[0] = 0x4d; pe[1] = 0x5a; pe[60] = 64; pe[64] = 0x50; pe[65] = 0x45
        let installer = root.appendingPathComponent("A \"quoted\" installer.EXE")
        try pe.write(to: installer)
        try IridiumGamePrerequisites.queueInstaller(installer, prefix: manualPrefix)
        precondition(!fm.fileExists(atPath: manualPrefix.appendingPathComponent("drive_c").path))
        let manualRoot = manualPrefix.appendingPathComponent("ManualInstaller")
        let manualScript = manualRoot.appendingPathComponent("installscript.vdf")
        let firstPlan = try Data(contentsOf: manualScript)
        let runs = try IridiumSteamInstallScript.processes(script: firstPlan, installDir: "C:\\IridiumPrerequisites\\shared1")
        precondition(runs.count == 1 && runs[0].arguments.isEmpty)
        let badInstaller = root.appendingPathComponent("bad.exe")
        for bad in [Data("Not an executable".utf8), Data("MZfixture".utf8), Data(repeating: 0x4d, count: 68)] {
            try bad.write(to: badInstaller)
            do { try IridiumGamePrerequisites.queueInstaller(badInstaller, prefix: manualPrefix); preconditionFailure("Invalid executable accepted") }
            catch { }
            let retained = try Data(contentsOf: manualScript)
            precondition(retained == firstPlan)
        }
        let link = root.appendingPathComponent("linked.exe")
        try fm.createSymbolicLink(at: link, withDestinationURL: installer)
        do { try IridiumGamePrerequisites.queueInstaller(link, prefix: manualPrefix); preconditionFailure("Linked installer accepted") }
        catch { }
        try fm.createDirectory(at: manualPrefix.appendingPathComponent("drive_c/IridiumGame"), withIntermediateDirectories: true)
        let profileSave = manualPrefix.appendingPathComponent("drive_c/save.dat")
        try Data("unchanged save".utf8).write(to: profileSave)
        let selected = try IridiumGamePrerequisites.prepare(prefix: manualPrefix, executable: "C:\\IridiumGame\\Game.exe",
            arguments: [], appID: nil, resources: resources)
        precondition(selected?.installerCount == 1)
        let copied = IridiumGamePrerequisites.resolve(runs[0].executable, drive: manualPrefix.appendingPathComponent("drive_c"))!
        let copiedBytes = try Data(contentsOf: copied)
        precondition(copiedBytes == pe)
        let recordedKey = "[Software\\\\Iridium\\\\ManualInstallers] 1\n\"\(runs[0].run.name)\"=dword:00000001\n"
        try Data(recordedKey.utf8).write(to: manualPrefix.appendingPathComponent("system.reg"))
        let afterInstall = try IridiumGamePrerequisites.prepare(prefix: manualPrefix, executable: "C:\\IridiumGame\\Game.exe",
            arguments: [], appID: nil, resources: resources)
        precondition(afterInstall == nil)
        let msi = root.appendingPathComponent("setup.msi")
        try pe.write(to: msi)
        do { try IridiumGamePrerequisites.queueInstaller(msi, prefix: manualPrefix); preconditionFailure("Invalid MSI accepted") }
        catch { }
        try Data([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1] + [UInt8](repeating: 0, count: 56)).write(to: msi)
        try IridiumGamePrerequisites.queueInstaller(msi, prefix: manualPrefix)
        let remaining = try fm.contentsOfDirectory(at: manualRoot, includingPropertiesForKeys: nil).filter { UUID(uuidString: $0.lastPathComponent) != nil }
        precondition(remaining.count == 1)
        try fm.createDirectory(at: manualPrefix.appendingPathComponent("drive_c/windows/system32"), withIntermediateDirectories: true)
        try Data("MZfixture".utf8).write(to: manualPrefix.appendingPathComponent("drive_c/windows/system32/msiexec.exe"))
        let msiLaunch = try IridiumGamePrerequisites.prepare(prefix: manualPrefix, executable: "C:\\IridiumGame\\Game.exe",
            arguments: [], appID: nil, resources: resources)
        precondition(msiLaunch?.installerCount == 1)
        let msiPlan = try String(contentsOf: manualPrefix.appendingPathComponent("drive_c/IridiumPrerequisites/installers.ini"), encoding: .utf16)
        precondition(msiPlan.contains("msiexec.exe") && msiPlan.contains(" /i ") && msiPlan.contains("setup.msi"))
        let keptSave = try Data(contentsOf: profileSave)
        let keptSource = try Data(contentsOf: installer)
        precondition(keptSave == Data("unchanged save".utf8) && keptSource == pe)
        try steamClientChecks(root: root, resources: resources)
        print("PASS: scripts, registry, shared redist, manual EXE/MSI selection and retry, prefix creation, relaunch, argv, fusion, cancellation, save preservation and Steam client mode")
    }

    static func steamClientChecks(root: URL, resources: Bundle) throws {
        let fm = FileManager.default
        func pe(_ sections: [String]) -> Data {
            var bytes = [UInt8](repeating: 0, count: 64)
            bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 64
            bytes += [0x50, 0x45, 0, 0, 0x64, 0x86, UInt8(sections.count), 0]
            bytes += [UInt8](repeating: 0, count: 12) + [16, 0, 0, 0] + [UInt8](repeating: 0, count: 16)
            for name in sections {
                let entry = Array(name.utf8.prefix(8))
                bytes += entry + [UInt8](repeating: 0, count: 40 - entry.count)
            }
            return Data(bytes)
        }
        let steamRoot = root.appendingPathComponent("steam-client")
        try fm.createDirectory(at: steamRoot, withIntermediateDirectories: true)
        let drm = steamRoot.appendingPathComponent("Protected.exe")
        let plain = steamRoot.appendingPathComponent("Plain.exe")
        try pe([".text", ".rdata", ".bind"]).write(to: drm)
        try pe([".text", ".rdata"]).write(to: plain)
        precondition(MadeiraSteamClient.sectionNames(drm) == [".text", ".rdata", ".bind"])
        precondition(MadeiraSteamClient.hasSteamDRM(drm) && !MadeiraSteamClient.hasSteamDRM(plain))
        precondition(MadeiraSteamClient.machine(drm) == 0x8664)
        let truncated = steamRoot.appendingPathComponent("Truncated.exe")
        try pe([".bind"]).prefix(100).write(to: truncated)
        precondition(!MadeiraSteamClient.hasSteamDRM(truncated))
        precondition(MadeiraSteamClient.sectionNames(steamRoot.appendingPathComponent("missing.exe")).isEmpty)

        // The game's iridium.cfg wins; the Settings switch only selects DRM-wrapped games.
        let config = steamRoot.appendingPathComponent("iridium.cfg")
        func request(_ text: String?, _ exe: URL, _ enabled: Bool) throws -> Bool {
            if let text { try Data(text.utf8).write(to: config) }
            if case .on = MadeiraSteamClient.request(gameConfig: text == nil ? nil : config, executable: exe, enabled: enabled) { return true }
            return false
        }
        let decisions = [try request(nil, drm, false), try request(nil, drm, true), try request(nil, plain, true),
                         try request("steam-client = on\n", plain, false),
                         try request("# off for this game\nsteam-client = off\n", drm, true),
                         try request("steam-client = maybe\n", drm, true)]
        precondition(decisions == [false, true, false, true, false, true])

        // Steam comes from Files > Iridium > SteamClient through a link in the game environment.
        let documents = steamRoot.appendingPathComponent("Documents")
        let prefix = steamRoot.appendingPathComponent("prefix")
        try fm.createDirectory(at: prefix.appendingPathComponent("drive_c/IridiumGame"), withIntermediateDirectories: true)
        do { _ = try MadeiraSteamClient.prepare(prefix: prefix, gameConfig: nil, documents: documents); preconditionFailure("Missing Steam accepted") }
        catch { precondition(error.localizedDescription.contains("SteamClient")) }
        precondition(fm.fileExists(atPath: documents.appendingPathComponent("SteamClient").path))
        let client = documents.appendingPathComponent("SteamClient/Steam")
        try fm.createDirectory(at: client, withIntermediateDirectories: true)
        try pe([".text"]).write(to: client.appendingPathComponent("Steam.exe"))
        precondition(MadeiraSteamClient.locate(documents: documents)?.standardizedFileURL == client.standardizedFileURL)
        try Data("steam-client-args = -silent\n".utf8).write(to: config)
        let launch = try MadeiraSteamClient.prepare(prefix: prefix, gameConfig: config, documents: documents)
        let installed = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        let linked = try fm.destinationOfSymbolicLink(atPath: installed.path)
        precondition(linked == client.path)
        precondition(launch.executable == "C:\\Program Files (x86)\\Steam\\Steam.exe")
        precondition(launch.directory == "C:\\Program Files (x86)\\Steam")
        precondition(launch.command.hasPrefix("\"C:\\Program Files (x86)\\Steam\\Steam.exe\" -no-cef-sandbox -cef-disable-gpu"))
        precondition(launch.command.hasSuffix(" -silent"))
        let again = try MadeiraSteamClient.prepare(prefix: prefix, gameConfig: nil, documents: documents)
        let relinked = try fm.destinationOfSymbolicLink(atPath: installed.path)
        precondition(relinked == client.path && !again.command.hasSuffix(" -silent"))

        // A Steam installed inside the game environment is used as it is.
        let ownPrefix = steamRoot.appendingPathComponent("own-prefix")
        let own = ownPrefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        try fm.createDirectory(at: own, withIntermediateDirectories: true)
        do { _ = try MadeiraSteamClient.prepare(prefix: ownPrefix, gameConfig: nil, documents: documents); preconditionFailure("Empty Steam folder accepted") }
        catch { }
        try pe([".text"]).write(to: own.appendingPathComponent("steam.exe"))
        let ownLaunch = try MadeiraSteamClient.prepare(prefix: ownPrefix, gameConfig: nil, documents: documents)
        precondition(ownLaunch.executable.hasSuffix("\\steam.exe"))
        precondition((try? fm.destinationOfSymbolicLink(atPath: own.path)) == nil)

        // The helper plan gains a [steam] stage, with or without installers.
        let text = try IridiumGamePrerequisites.configuration([], executable: "C:\\IridiumGame\\Game.exe", arguments: [], steam: launch)
        precondition(text.contains("runs=0\r\nsteam=1\r\n") && text.contains("[steam]\r\n"))
        precondition(text.contains("command=x" + launch.command + "x\r\n"))
        let ordinary = try IridiumGamePrerequisites.configuration([], executable: "C:\\IridiumGame\\Game.exe", arguments: [])
        precondition(ordinary.contains("steam=0\r\n") && !ordinary.contains("[steam]"))
        for name in ["system.reg", "user.reg"] { try Data("WINE REGISTRY Version 2\n".utf8).write(to: prefix.appendingPathComponent(name)) }
        let withoutSteam = try IridiumGamePrerequisites.prepare(prefix: prefix, executable: "C:\\IridiumGame\\Game.exe",
            arguments: [], appID: nil, resources: resources)
        precondition(withoutSteam == nil)
        let steamOnly = try IridiumGamePrerequisites.prepare(prefix: prefix, executable: "C:\\IridiumGame\\Game.exe",
            arguments: [], appID: nil, steam: launch, resources: resources)!
        precondition(steamOnly.steamClient && steamOnly.installerCount == 0)
        let plan = try String(contentsOf: prefix.appendingPathComponent("drive_c/IridiumPrerequisites/installers.ini"), encoding: .utf16)
        precondition(plan.contains("steam=1") && plan.contains("-no-cef-sandbox"))
        let statusFile = prefix.appendingPathComponent("drive_c/IridiumPrerequisites/status.txt")
        for state in ["steam", "steam-login", "steam-exit"] {
            try Data(state.utf8).write(to: statusFile)
            precondition(IridiumGamePrerequisites.status(prefix: prefix)?.contains("Steam") == true)
        }
    }
}
