// SPDX-License-Identifier: GPL-3.0-or-later
// steam.exe flags from Madeira ContentView.swift prepareSteamLaunch (ml589).
// Copyright 2026 125hz. Madeira Converter Exception: see testrepos/Madeira/LICENSE-EXCEPTION.md.
import Foundation

/// Experimental: run the player's own Windows Steam client before a game that
/// needs it, such as one protected by Steam DRM. The game's DRM then talks to a
/// running, signed-in Steam exactly as on Windows; nothing in the game changes.
///
/// Settings > Display & Memory > Steam Client turns it on for games whose
/// executable carries Steam DRM. A game's iridium.cfg can force it either way
/// with `steam-client = on` or `steam-client = off`, and add Steam arguments
/// with `steam-client-args`. The client is the player's own Windows Steam folder
/// copied to Files > Iridium > SteamClient, linked into the game environment at
/// C:\Program Files (x86)\Steam. A Steam already installed in that location of
/// the game environment is used as it is. The prerequisite helper starts it,
/// waits for sign-in, runs the game, then closes Steam.
enum MadeiraSteamClient {
    struct Launch: Equatable {
        let executable: String
        let command: String
        let directory: String
        let file: URL   // steam.exe on this device, for the launch log
    }

    enum Request: Equatable {
        case on(String)
        case off(String)
    }

    static let preferenceKey = "IridiumSteamClient"
    static let configKey = "steam-client"
    static let argumentsKey = "steam-client-args"
    static let folderName = "SteamClient"
    static let windowsDirectory = "C:\\Program Files (x86)\\Steam"
    // Madeira's Steam testing launch: no CEF sandbox or GPU in Wine, Steam's
    // console in the log, no crash monitor, fewer background Chromium services.
    static let defaultArguments = [
        "-no-cef-sandbox", "-cef-disable-gpu", "-console", "-nocrashmonitor",
        "-cef-disable-features=SegmentationPlatform,OptimizationTargetPrediction,OptimizationHints",
    ]

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: preferenceKey) }

    /// The game's own setting wins; otherwise the Settings switch applies to
    /// executables that carry Steam DRM.
    static func request(gameConfig: URL?, executable: URL, enabled: Bool) -> Request {
        if let gameConfig, let value = MadeiraGameConfig.value(configKey, in: gameConfig)?.lowercased() {
            let name = gameConfig.lastPathComponent
            if ["on", "1", "yes", "true"].contains(value) { return .on("\(name) sets \(configKey) = on") }
            if ["off", "0", "no", "false"].contains(value) { return .off("\(name) sets \(configKey) = off") }
        }
        guard enabled else { return .off("Steam Client is off in Settings") }
        return hasSteamDRM(executable)
            ? .on("the game executable is protected by Steam DRM")
            : .off("the game executable has no Steam DRM")
    }

    /// SteamStub, Steam's executable wrapper, adds a PE section named ".bind".
    static func hasSteamDRM(_ executable: URL) -> Bool {
        sectionNames(executable).contains(".bind")
    }

    static func sectionNames(_ executable: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: executable) else { return [] }
        defer { try? handle.close() }
        guard let dos = try? handle.read(upToCount: 64), dos.count == 64,
              dos[dos.startIndex] == 0x4d, dos[dos.startIndex + 1] == 0x5a else { return [] }
        let peOffset = UInt64(little32([UInt8](dos), at: 60))
        guard peOffset >= 64, peOffset <= 16 * 1024 * 1024,
              (try? handle.seek(toOffset: peOffset)) != nil,
              let header = try? handle.read(upToCount: 24), header.count == 24 else { return [] }
        let coff = [UInt8](header)
        guard coff[0] == 0x50, coff[1] == 0x45, coff[2] == 0, coff[3] == 0 else { return [] }
        let count = Int(little16(coff, at: 6)), optionalSize = UInt64(little16(coff, at: 20))
        guard (1...96).contains(count),
              (try? handle.seek(toOffset: peOffset + 24 + optionalSize)) != nil,
              let table = try? handle.read(upToCount: count * 40), table.count == count * 40 else { return [] }
        let bytes = [UInt8](table)
        return (0..<count).map { index in
            let raw = bytes[(index * 40)..<(index * 40 + 8)].prefix(while: { $0 != 0 })
            return String(decoding: raw, as: UTF8.self)
        }
    }

    /// The PE machine of `executable` (0x8664 x86-64, 0x14c x86), or nil.
    static func machine(_ executable: URL) -> UInt16? {
        guard let handle = try? FileHandle(forReadingFrom: executable) else { return nil }
        defer { try? handle.close() }
        guard let dos = try? handle.read(upToCount: 64), dos.count == 64 else { return nil }
        let peOffset = UInt64(little32([UInt8](dos), at: 60))
        guard peOffset <= 16 * 1024 * 1024, (try? handle.seek(toOffset: peOffset)) != nil,
              let header = try? handle.read(upToCount: 6), header.count == 6 else { return nil }
        let bytes = [UInt8](header)
        guard bytes[0] == 0x50, bytes[1] == 0x45, bytes[2] == 0, bytes[3] == 0 else { return nil }
        return little16(bytes, at: 4)
    }

    static func machineName(_ executable: URL) -> String {
        switch machine(executable) {
        case 0x8664?: return "x86-64"
        case 0x14c?: return "32-bit x86"
        case let other?: return "PE machine \(other)"
        case nil: return "not a Windows program"
        }
    }

    static func folder(documents: URL) -> URL {
        documents.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Creates Files > Iridium > SteamClient so the player can find it.
    static func ensureFolder(documents: URL? = MadeiraGameConfig.defaultDocuments()) {
        guard let documents else { return }
        try? FileManager.default.createDirectory(at: folder(documents: documents), withIntermediateDirectories: true)
    }

    /// The Steam folder holding steam.exe: SteamClient itself, or a Steam
    /// folder copied into it whole.
    static func locate(documents: URL? = MadeiraGameConfig.defaultDocuments()) -> URL? {
        guard let documents else { return nil }
        let root = folder(documents: documents)
        for candidate in [root, root.appendingPathComponent("Steam", isDirectory: true)] {
            if steamExecutableName(in: candidate) != nil { return candidate }
        }
        return nil
    }

    static func steamExecutableName(in folder: URL) -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              let name = names.first(where: { $0.caseInsensitiveCompare("steam.exe") == .orderedSame }) else { return nil }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return name
    }

    /// Makes Steam available at C:\Program Files (x86)\Steam in this game's
    /// environment and returns how the helper starts it. Run on the boot
    /// worker before wineserver starts.
    static func prepare(prefix: URL, gameConfig: URL?,
                        documents: URL? = MadeiraGameConfig.defaultDocuments()) throws -> Launch {
        let fm = FileManager.default
        let programFiles = prefix.appendingPathComponent("drive_c/Program Files (x86)", isDirectory: true)
        try requireUnlinkedPath(programFiles, under: prefix)
        let target = programFiles.appendingPathComponent("Steam", isDirectory: true)
        let type = (try? fm.attributesOfItem(atPath: target.path))?[.type] as? FileAttributeType
        let executableName: String
        let file: URL
        if type == .typeDirectory {
            // Installed inside this game's environment; use it as it is.
            guard let name = steamExecutableName(in: target) else {
                throw failure("\(windowsDirectory) in this game's environment has no steam.exe. Remove that folder to use Files > Iridium > SteamClient instead.")
            }
            executableName = name
            file = target.appendingPathComponent(name)
        } else {
            guard let client = locate(documents: documents), let name = steamExecutableName(in: client) else {
                ensureFolder(documents: documents)
                throw failure("Steam Client is on, but Files > Iridium > SteamClient has no steam.exe. Copy the Steam folder from a Windows PC there, or turn Steam Client off.")
            }
            if type == .typeSymbolicLink { try fm.removeItem(at: target) }   // this launch's link replaces the last one
            else if type != nil { throw failure("\(windowsDirectory) in this game's environment is not a folder.") }
            try fm.createDirectory(at: programFiles, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: target, withDestinationURL: client)
            executableName = name
            file = client.appendingPathComponent(name)
        }
        let executable = windowsDirectory + "\\" + executableName
        var command = ([MadeiraLaunchArguments.quoteWindowsArgument(executable)] + defaultArguments).joined(separator: " ")
        if let gameConfig, let extra = MadeiraGameConfig.value(argumentsKey, in: gameConfig), !extra.isEmpty {
            command += " " + extra
        }
        return Launch(executable: executable, command: command, directory: windowsDirectory, file: file)
    }

    private static func little16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func little32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }

    private static func requireUnlinkedPath(_ url: URL, under root: URL) throws {
        let root = root.standardizedFileURL
        var current = url.standardizedFileURL
        guard current.path.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadInvalidFileName) }
        while current.path != root.path {
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            current.deleteLastPathComponent()
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "IridiumSteamClient", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
