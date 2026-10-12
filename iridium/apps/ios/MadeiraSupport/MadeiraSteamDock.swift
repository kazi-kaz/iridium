// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Madeira app/Madeira/MadeiraDock.swift, SteamRuntime.swift and
// AppManifestWriter.swift (willfaust/Madeira 48f976429c18). Copyright 2026 125hz;
// the install-record writer is derived from Jfishin's Madeira Steam client.
// Madeira Converter Exception: see testrepos/Madeira/LICENSE-EXCEPTION.md.
import Foundation
import Compression
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Madeira Dock for Steam games downloaded in Iridium.
///
/// dockhost.exe (testrepos/madeira-dock, built by Scripts/build_controller_runtime.sh)
/// loads Valve's own, unmodified Windows Steam client library inside the game's
/// Wine session, signs in with the account already signed in to Iridium, and asks
/// Valve's client to start the game with Valve's own LaunchApp. Valve's client
/// and servers decide sign-in, ownership and launch; the game and its DRM are not
/// changed. There is no Steam window and no Chromium helper.
///
/// Iridium's side of the contract: Valve's client components (downloaded once from
/// Valve's update CDN and pinned by size and SHA-256), the game recorded as
/// installed in that client's library, a one-use sign-in transfer file, the host's
/// environment variables, and the host's numeric report (C:\madeira-dock.txt).
enum MadeiraSteamDock {
    // MARK: When Dock starts a game

    enum Mode: String, CaseIterable, Sendable {
        case off, drm, all
        var title: String {
            switch self {
            case .off: "Off"
            case .drm: "Games with Steam DRM"
            case .all: "All Downloaded Steam Games"
            }
        }
    }

    static let modeKey = "IridiumSteamDockMode"
    static let configKey = "steam-dock"
    static let launchOptionKey = "steam-dock-launch-option"
    static var mode: Mode { Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .drm }

    enum Decision: Equatable, Sendable {
        case on(String)
        case off(String)
    }

    /// The game's iridium.cfg wins; otherwise the Settings mode. Only games Iridium
    /// downloaded from Steam qualify: Dock needs their App ID and download record.
    static func decision(gameConfig: URL?, executable: URL, mode: Mode, steamDownload: Bool) -> Decision {
        guard steamDownload else { return .off("the game was not downloaded from Steam in Iridium") }
        if let gameConfig, let value = MadeiraGameConfig.value(configKey, in: gameConfig)?.lowercased() {
            let name = gameConfig.lastPathComponent
            if ["on", "1", "yes", "true"].contains(value) { return .on("\(name) sets \(configKey) = on") }
            if ["off", "0", "no", "false"].contains(value) { return .off("\(name) sets \(configKey) = off") }
        }
        switch mode {
        case .off: return .off("Madeira Dock is off in Settings")
        case .all: return .on("Madeira Dock is on for all downloaded Steam games")
        case .drm:
            return MadeiraSteamClient.hasSteamDRM(executable)
                ? .on("the game executable is protected by Steam DRM")
                : .off("the game executable has no Steam DRM")
        }
    }

    /// `steam-dock-launch-option = N` selects Steam's Nth launch option (default 0).
    static func launchOption(gameConfig: URL?) -> UInt32 {
        guard let gameConfig, let value = MadeiraGameConfig.value(launchOptionKey, in: gameConfig),
              let option = UInt32(value), option < 64 else { return 0 }
        return option
    }

    /// Everything a Dock launch needs from the app. The token stays in memory and
    /// reaches the guest only through the one-use transfer file.
    struct Request: Sendable {
        let appID: Int
        let name: String
        let account: String
        let token: String
        let launchOption: UInt32
    }

    struct Failure: LocalizedError, Sendable {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: Valve's client components

    struct Package: Sendable {
        let file: String
        let bytes: Int
        let sha256: String
    }

    /// Valve's own update CDN, one host, HTTPS. The pins never follow a moving client
    /// manifest; the unpacked steamclient64.dll must be a build the host supports.
    static let origin = "https://client-update.akamai.steamstatic.com/"
    static let originHost = "client-update.akamai.steamstatic.com"
    static let packages = [
        Package(file: "bins_win32.zip.23e34a6d4b10596a44561a5100dac5585d2517da", bytes: 59_544_006,
                sha256: "8b712b2a3412a9066b7725f4e1c5cef9a7ca5b187b6585a5b92d25d09df0ba62"),
        Package(file: "bins_win64_win32.zip.f29d67dc38a4be027f1734802697c668621a6da1", bytes: 10_509_550,
                sha256: "345f6e4bdc19b27ae53bf752c21e2d894e0e899d94823222fb426e890d1226b5"),
        Package(file: "steam_win32.zip.3e96965d109fc2d4cc14206b2fc4ec960a746ed3", bytes: 2_307_664,
                sha256: "1369615c795b60de822876b4dc4042186cf58d0dc8f63ea1371167f667e16925"),
    ]
    static let clientSHA256 = "71b391fe9f3e2006cbc81a5c75eef3eb4186012deabfdb2c8b7e8d4850ecf640"
    static let downloadBytes = packages.reduce(0) { $0 + $1.bytes }
    static let relativeRoot = "Program Files (x86)/Steam"
    static let windowsRoot = "C:\\Program Files (x86)\\Steam"
    static let readyMarker = "iridium-dock-ready.txt"

    static func supportFolder() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SteamDock", isDirectory: true)
    }

    /// Shared, unpacked copy of the components. Each game environment gets a
    /// copy-on-write clone, so the files take space once.
    static func componentStore(support: URL? = supportFolder()) -> URL? {
        support?.appendingPathComponent("components", isDirectory: true)
    }

    static func componentsReady(store: URL? = componentStore(), client: String = clientSHA256) -> Bool {
        guard let store,
              let marker = try? String(contentsOf: store.appendingPathComponent(readyMarker), encoding: .utf8) else { return false }
        return marker.trimmingCharacters(in: .whitespacesAndNewlines) == client
            && FileManager.default.fileExists(atPath: store.appendingPathComponent("steamclient64.dll").path)
    }

    /// The built host in the app bundle, or nil when this build has none.
    static func bundledHost(resources: Bundle = .main) -> URL? {
        resources.url(forResource: "dockhost", withExtension: "exe", subdirectory: "ControllerRuntime/x64")
    }

    static func validPath(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count < 240,
              !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { $0.value < 32 }) else { return false }
        return !name.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." || $0.hasSuffix(".") || $0.hasSuffix(" ") }
    }

    /// Reads a stored ZIP: the central directory first, then each local header.
    /// ZIP64, encryption, links, unknown methods and duplicate or case-colliding
    /// names are rejected; sizes and CRC-32 must match. Called only after the whole
    /// archive's pinned SHA-256 has been checked.
    static func unpack(_ data: Data, write: (String, Data) throws -> Void) throws {
        func need(_ condition: Bool) throws { if !condition { throw Failure("Steam's components could not be verified. Try downloading them again.") } }
        try need(data.count >= 22 && data.count <= 64 * 1024 * 1024)
        let base = data.startIndex
        func u16(_ p: Int) -> Int { Int(data[base + p]) | Int(data[base + p + 1]) << 8 }
        func u32(_ p: Int) -> Int { u16(p) | u16(p + 2) << 16 }
        guard let end = stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1)
            .first(where: { u32($0) == 0x06054b50 && $0 + 22 + u16($0 + 20) == data.count }) else {
            try need(false); return
        }
        let count = u16(end + 10), central = u32(end + 16), centralSize = u32(end + 12)
        try need(u16(end + 4) == 0 && u16(end + 6) == 0 && u16(end + 8) == count && count <= 256)
        try need(central <= end && centralSize == end - central)
        var cursor = central, total = 0
        var seen = Set<String>()
        for _ in 0..<count {
            try Task.checkCancellation()
            try need(cursor + 46 <= end && u32(cursor) == 0x02014b50)
            let flags = u16(cursor + 8), method = u16(cursor + 10)
            let crc = UInt32(u32(cursor + 16)), compressed = u32(cursor + 20), size = u32(cursor + 24)
            let nameLength = u16(cursor + 28), local = u32(cursor + 42)
            let next = cursor + 46 + nameLength + u16(cursor + 30) + u16(cursor + 32)
            let kind = (u32(cursor + 38) >> 16) & 0xf000
            try need(next <= end && flags & 1 == 0 && (method == 0 || method == 8))
            try need(kind == 0 || kind == 0x8000 || kind == 0x4000)
            guard let rawName = String(data: data.subdata(in: base + cursor + 46..<base + cursor + 46 + nameLength), encoding: .utf8) else {
                try need(false); return
            }
            // Valve's Windows packages use backslashes. Normalize before every
            // traversal and duplicate check; compare local headers verbatim.
            let normalized = rawName.replacingOccurrences(of: "\\", with: "/")
            let directory = normalized.hasSuffix("/")
            let name = directory ? String(normalized.dropLast()) : normalized
            try need(validPath(name) && seen.insert(name.lowercased()).inserted)
            try need(size <= 64 * 1024 * 1024 && local + 30 <= central && u32(local) == 0x04034b50)
            try need(u16(local + 6) == flags && u16(local + 8) == method && u16(local + 26) == nameLength)
            let body = local + 30 + nameLength + u16(local + 28)
            try need(body <= central && compressed <= central - body)
            try need(data.subdata(in: base + local + 30..<base + local + 30 + nameLength) == Data(rawName.utf8))
            if flags & 8 == 0 { try need(u32(local + 18) == compressed && u32(local + 22) == size) }
            total += size
            try need(total <= 256 * 1024 * 1024)
            if directory { try need(size == 0 && compressed == 0); cursor = next; continue }
            let encoded = data.subdata(in: base + body..<base + body + compressed)
            var decoded = Data()
            if method == 0 {
                try need(compressed == size); decoded = encoded
            } else if size > 0 {
                try need(compressed > 0)
                // One spare byte: a stream that inflates past `size` fills it and fails.
                decoded = Data(count: size + 1)
                let written = decoded.withUnsafeMutableBytes { output in
                    encoded.withUnsafeBytes { input in
                        compression_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, size + 1,
                                                  input.bindMemory(to: UInt8.self).baseAddress!, compressed,
                                                  nil, COMPRESSION_ZLIB)
                    }
                }
                try need(written == size)
                decoded.count = size
            }
            try need(crc32(decoded) == crc)
            try write(name, decoded)
            cursor = next
        }
        try need(cursor == end)
    }

    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 { value = value & 1 != 0 ? 0xedb88320 ^ (value >> 1) : value >> 1 }
            table[index] = value
        }
        var crc: UInt32 = 0xffff_ffff
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xffff_ffff
    }

    static func sha256(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }

    static func sha256(file: URL) throws -> String {
        sha256(try Data(contentsOf: file, options: .mappedIfSafe))
    }

    // MARK: Prefix setup

    /// Iridium's download record (SteamGames/<appid>/<variant>/installed.json),
    /// next to the `content` folder the game runs from.
    struct Receipt: Decodable, Sendable {
        struct Depot: Decodable, Sendable {
            let depotId: UInt32
            let manifestId: String
        }
        let appId: UInt32
        let name: String
        let buildId: String?
        let depots: [Depot]?
    }

    static func receipt(gameRoot: URL) -> Receipt? {
        guard gameRoot.lastPathComponent == "content" else { return nil }
        let file = gameRoot.deletingLastPathComponent().appendingPathComponent("installed.json")
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true, (values.fileSize ?? 0) <= 1 << 20,
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Receipt.self, from: data)
    }

    /// One folder name: no separators, drive letters, parent references or control characters.
    static func validFolderName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 240 && name != "." && name != ".." &&
            !name.contains("/") && !name.contains("\\") && !name.contains(":") && !name.contains("\"") &&
            !name.unicodeScalars.contains { $0.value < 32 } && !name.hasSuffix(" ") && !name.hasSuffix(".")
    }

    /// The folder name the game gets under steamapps/common. Valve's client resolves
    /// the install path from the install record, so any valid name works.
    static func installFolder(name: String, appID: Int) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_'()&+!,"))
        let cleaned = String(String.UnicodeScalarView(name.unicodeScalars.filter { allowed.contains($0) && $0.isASCII }))
            .trimmingCharacters(in: .whitespaces)
        let folder = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
        return validFolderName(folder) ? folder : "App \(appID)"
    }

    struct Stage: Equatable, Sendable {
        let executable: String
        let command: String
        let directory: String
        let installPath: String  // the game folder Valve's client must resolve
    }

    static let hostWindowsPath = "C:\\IridiumPrerequisites\\dockhost.exe"

    /// Puts Valve's client, the install record, the game link, the client-discovery
    /// registry values and the host into this game's environment. Runs on the boot
    /// worker after game preparation and before wineserver starts.
    static func preparePrefix(prefix: URL, appID: Int, name: String, receipt: Receipt?, steamID: UInt64,
                              store: URL, host: URL, client: String = clientSHA256) throws -> Stage {
        let fm = FileManager.default
        guard (1..<Int(UInt32.max)).contains(appID) else { throw Failure("This game's Steam App ID is invalid.") }
        guard componentsReady(store: store, client: client) else {
            throw Failure("Valve's Steam client components are missing. Download them in Settings › Runtime › Steam Games.")
        }
        let drive = prefix.appendingPathComponent("drive_c", isDirectory: true)
        let game = drive.appendingPathComponent("IridiumGame", isDirectory: true)
        guard (try? game.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw Failure("The game copy is missing from this game's environment.")
        }
        let programFiles = drive.appendingPathComponent("Program Files (x86)", isDirectory: true)
        try requireUnlinkedPath(programFiles, under: prefix)
        let root = programFiles.appendingPathComponent("Steam", isDirectory: true)
        switch (try? fm.attributesOfItem(atPath: root.path))?[.type] as? FileAttributeType {
        case .typeSymbolicLink?: try fm.removeItem(at: root)   // the Steam Client mode's link to Files › SteamClient
        case .typeDirectory?, nil: break
        default: throw Failure("\(windowsRoot) in this game's environment is not a folder.")
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // Copy-on-write clones of the shared components. Files already present stay.
        guard let walker = fm.enumerator(at: store, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw Failure("Valve's Steam client components could not be read.")
        }
        let storePath = store.resolvingSymlinksInPath().standardizedFileURL.path
        for case let file as URL in walker {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw Failure("Valve's Steam client components could not be verified.") }
            guard values.isRegularFile == true, file.lastPathComponent != readyMarker else { continue }
            let path = file.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(storePath + "/") else { continue }
            let relative = String(path.dropFirst(storePath.count + 1))
            guard validPath(relative) else { continue }
            let target = root.appendingPathComponent(relative)
            try requireUnlinkedPath(target, under: prefix)
            if fm.fileExists(atPath: target.path) { continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: file, to: target)
        }
        guard try sha256(file: root.appendingPathComponent("steamclient64.dll")) == client else {
            throw Failure("This game's environment has a different Steam client build in \(windowsRoot). Madeira Dock only drives the client build it has verified. Remove that Steam folder from the game environment, or set steam-dock = off for this game.")
        }

        // Valve's client library: the install record and the game folder.
        let steamapps = root.appendingPathComponent("steamapps", isDirectory: true)
        let common = steamapps.appendingPathComponent("common", isDirectory: true)
        try requireUnlinkedPath(common, under: prefix)
        try fm.createDirectory(at: common, withIntermediateDirectories: true)
        let folder = installFolder(name: name, appID: appID)
        let link = common.appendingPathComponent(folder)
        switch (try? fm.attributesOfItem(atPath: link.path))?[.type] as? FileAttributeType {
        case .typeSymbolicLink?: try fm.removeItem(at: link)
        case nil: break
        default: throw Failure("steamapps\\common\\\(folder) in this game's environment is a real folder. Iridium links the game copy there; move that folder away first.")
        }
        // drive_c/Program Files (x86)/Steam/steamapps/common/<folder> -> drive_c/IridiumGame
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../../../../IridiumGame")
        let record = manifest(appID: appID, name: receipt?.name ?? name, installDir: folder,
                              buildID: receipt?.buildId.flatMap { UInt32($0) } ?? 0, steamID: steamID,
                              depots: receipt?.depots ?? [])
        let recordFile = steamapps.appendingPathComponent("appmanifest_\(appID).acf")
        try requireUnlinkedPath(recordFile, under: prefix)
        try Data(record.utf8).write(to: recordFile, options: .atomic)

        // Client discovery for Valve's client and the game's steam_api.
        for (file, machine) in [("system.reg", true), ("user.reg", false)] {
            let url = prefix.appendingPathComponent(file)
            try requireUnlinkedPath(url, under: prefix)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw Failure("This game's Windows registry is missing. Start the game once without Madeira Dock, then try again.")
            }
            let updated = try registry(text, machine: machine)
            if updated != text { try Data(updated.utf8).write(to: url, options: .atomic) }
        }

        let helperFolder = drive.appendingPathComponent("IridiumPrerequisites", isDirectory: true)
        try requireUnlinkedPath(helperFolder, under: prefix)
        try fm.createDirectory(at: helperFolder, withIntermediateDirectories: true)
        let hostTarget = helperFolder.appendingPathComponent("dockhost.exe")
        try Data(contentsOf: host).write(to: hostTarget, options: .atomic)
        let report = drive.appendingPathComponent("madeira-dock.txt")
        try requireUnlinkedPath(report, under: prefix)
        if fm.fileExists(atPath: report.path) { try fm.removeItem(at: report) }
        return Stage(executable: hostWindowsPath, command: "\"\(hostWindowsPath)\"", directory: "C:\\IridiumPrerequisites",
                     installPath: windowsRoot + "\\steamapps\\common\\" + folder)
    }

    /// Steam's appmanifest, in the field order and spelling Valve's client writes.
    /// `InstalledDepots` tells the client the install is complete, so it does not
    /// try to download the game again.
    static func manifest(appID: Int, name: String, installDir: String, buildID: UInt32, steamID: UInt64,
                         depots: [Receipt.Depot]) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .filter { $0 != "\n" && $0 != "\r" }
        }
        let valid = depots.filter { $0.depotId > 0 && UInt64($0.manifestId) != nil }
        var lines = ["\"AppState\"", "{",
                     "\t\"appid\"\t\t\"\(appID)\"",
                     "\t\"universe\"\t\t\"1\"",
                     "\t\"name\"\t\t\"\(escape(name))\"",
                     "\t\"StateFlags\"\t\t\"4\"",
                     "\t\"installdir\"\t\t\"\(escape(installDir))\"",
                     "\t\"LastUpdated\"\t\t\"\(Int(Date().timeIntervalSince1970))\"",
                     "\t\"LastPlayed\"\t\t\"0\"",
                     "\t\"SizeOnDisk\"\t\t\"0\"",
                     "\t\"StagingSize\"\t\t\"0\"",
                     "\t\"buildid\"\t\t\"\(buildID)\"",
                     "\t\"LastOwner\"\t\t\"\(steamID)\""]
        if !valid.isEmpty { lines.append("\t\"DownloadType\"\t\t\"1\"") }
        lines += ["\t\"UpdateResult\"\t\t\"0\"",
                  "\t\"BytesToDownload\"\t\t\"0\"",
                  "\t\"BytesDownloaded\"\t\t\"0\"",
                  "\t\"BytesToStage\"\t\t\"0\"",
                  "\t\"BytesStaged\"\t\t\"0\"",
                  "\t\"TargetBuildID\"\t\t\"\(buildID)\"",
                  "\t\"AutoUpdateBehavior\"\t\t\"0\"",
                  "\t\"AllowOtherDownloadsWhileRunning\"\t\t\"0\"",
                  "\t\"ScheduledAutoUpdate\"\t\t\"0\""]
        if !valid.isEmpty {
            lines += ["\t\"InstalledDepots\"", "\t{"]
            for depot in valid.sorted(by: { $0.depotId < $1.depotId }) {
                lines += ["\t\t\"\(depot.depotId)\"", "\t\t{", "\t\t\t\"manifest\"\t\t\"\(depot.manifestId)\"", "\t\t}"]
            }
            lines.append("\t}")
        }
        lines += ["\t\"UserConfig\"", "\t{", "\t\t\"language\"\t\t\"english\"", "\t}",
                  "\t\"MountedConfig\"", "\t{", "\t\t\"language\"\t\t\"english\"", "\t}", "}"]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Sets the fixed client-discovery values in a Wine registry file. Never writes
    /// user IDs, licences, login caches, tokens or anything asserting ownership.
    /// Values left by an earlier Steam client in this environment are replaced.
    static func registry(_ text: String, machine: Bool) throws -> String {
        guard text.hasPrefix("WINE REGISTRY Version 2") else {
            throw Failure("This game's Windows registry is not in Wine's format.")
        }
        let root = windowsRoot.replacingOccurrences(of: "\\", with: "\\\\")
        let sections: [(String, [(String, String)])] = machine
            ? [("Software\\\\Valve\\\\Steam", [("InstallPath", root)]),
               ("Software\\\\Wow6432Node\\\\Valve\\\\Steam", [("InstallPath", root)])]
            : [("Software\\\\Valve\\\\Steam", [("SteamPath", root), ("SteamExe", root + "\\\\steam.exe")]),
               ("Software\\\\Valve\\\\Steam\\\\ActiveProcess",
                [("SteamClientDll", root + "\\\\steamclient.dll"), ("SteamClientDll64", root + "\\\\steamclient64.dll")])]
        var lines = text.components(separatedBy: "\n")
        for (key, values) in sections {
            let header = "[\(key)]".lowercased()
            let starts = lines.indices.filter {
                let line = lines[$0].lowercased()
                return line == header || line.hasPrefix(header + " ")
            }
            guard starts.count <= 1 else { throw Failure("This game's Windows registry has a duplicated Steam key.") }
            if let start = starts.first {
                var end = lines[(start + 1)...].firstIndex { $0.hasPrefix("[") } ?? lines.count
                for (name, value) in values {
                    let prefix = "\"\(name)\"=".lowercased()
                    let expected = "\"\(name)\"=\"\(value)\""
                    let matches = lines[(start + 1)..<end].indices.filter { lines[$0].lowercased().hasPrefix(prefix) }
                    for index in matches.reversed() { lines.remove(at: index); end -= 1 }
                    // Values go before the blank line that ends the section.
                    var insert = end
                    while insert > start + 1, lines[insert - 1].trimmingCharacters(in: .whitespaces).isEmpty { insert -= 1 }
                    lines.insert(expected, at: insert)
                    end += 1
                }
            } else {
                if lines.last == "" { lines.removeLast() }
                lines += ["", "[\(key)]"] + values.map { "\"\($0.0)\"=\"\($0.1)\"" } + [""]
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Sign-in transfer

    static func validAppID(_ value: Int) -> Bool { value > 0 && UInt64(value) < UInt64(UInt32.max) }

    /// The bounded one-use transfer the host reads (madeira-dock src/auth.c). The
    /// payload is not an ownership claim: Valve authenticates it in the guest.
    static func envelope(account: String, token: String, steamID: UInt64, appID: Int) throws -> Data {
        let name = Array(account.utf8), secret = Array(token.utf8)
        guard (1...64).contains(name.count), (1...8192).contains(secret.count),
              name.allSatisfy({ (33...126).contains($0) }),
              secret.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }),
              steamID >> 56 == 1, (steamID >> 52) & 15 == 1, (steamID >> 32) & 0xfffff == 1,
              steamID & 0xffffffff != 0, validAppID(appID) else {
            throw Failure("Your Steam sign-in cannot be handed to Madeira Dock. Sign out of Steam in Iridium and sign in again.")
        }
        var data = Data("MDOCK001".utf8)
        func append(_ value: UInt64, bytes: Int) {
            for index in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
        }
        append(steamID, bytes: 8); append(UInt64(appID), bytes: 4)
        append(UInt64(name.count), bytes: 2); append(UInt64(secret.count), bytes: 2)
        data.append(contentsOf: name); data.append(contentsOf: secret)
        return data
    }

    /// The refresh token's JWT subject selects the account. It is not treated as
    /// authenticated identity; only Valve accepting the token establishes that.
    static func subject(_ token: String) throws -> UInt64 {
        let renew = Failure("Your Steam sign-in needs renewal. Sign out of Steam in Iridium and sign in again.")
        guard token.utf8.count <= 8192 else { throw renew }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw renew }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["sub"] as? String, let id = UInt64(text) else { throw renew }
        return id
    }

    /// Wine's Unix namespace reaches the protected file without a drive mapping.
    static func handoffGuestPath(_ url: URL) -> String {
        "\\\\?\\unix" + url.path.replacingOccurrences(of: "/", with: "\\")
    }

    static func handoffFile(support: URL? = supportFolder()) -> URL? {
        support?.appendingPathComponent("Transfer", isDirectory: true).appendingPathComponent("launch.auth")
    }

    /// Removes an unconsumed transfer (session end, launch failure, app start).
    static func cleanup(support: URL? = supportFolder()) {
        if let url = handoffFile(support: support) { try? FileManager.default.removeItem(at: url) }
    }

    /// Writes the transfer to protected Application Support storage (complete file
    /// protection, mode 0600, excluded from backups, created exclusively) and
    /// returns its guest path. The host opens it delete-on-close before sign-in.
    static func writeHandoff(_ request: Request, steamID: UInt64, support: URL? = supportFolder()) throws -> String {
        cleanup(support: support)
        guard let url = handoffFile(support: support) else { throw Failure("Madeira Dock's private transfer folder is unavailable.") }
        var data = try envelope(account: request.account, token: request.token, steamID: steamID, appID: request.appID)
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        let fm = FileManager.default
        var folder = url.deletingLastPathComponent()
        let protection: [FileAttributeKey: Any]
        #if os(iOS)
        protection = [.protectionKey: FileProtectionType.complete]
        #else
        protection = [:]
        #endif
        try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                               attributes: protection.merging([.posixPermissions: 0o700]) { current, _ in current })
        guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw Failure("Madeira Dock's transfer folder is invalid.")
        }
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure("Iridium could not create Madeira Dock's private sign-in transfer.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            if !protection.isEmpty { try fm.setAttributes(protection, ofItemAtPath: url.path) }
            try file.write(contentsOf: data)
            try file.close()
        } catch {
            try? file.close()
            cleanup(support: support)
            throw error
        }
        return handoffGuestPath(url)
    }

    // MARK: Host environment

    /// Names the host and this app read; cleared before every launch.
    static let environmentKeys = [
        "MADEIRA_STEAM_HOST_PROBE", "MADEIRA_STEAM_HOST_SESSION", "MADEIRA_STEAM_HOST_LOGIN",
        "MADEIRA_STEAM_HOST_LAUNCH", "MADEIRA_STEAM_HOST_APPID", "MADEIRA_STEAM_HOST_LAUNCH_OPTION",
        "MADEIRA_STEAM_HOST_CLIENT_DIR", "MADEIRA_STEAM_HOST_EXPECTED_INSTALL", "MADEIRA_STEAM_HOST_LOG",
        "MADEIRA_STEAM_HOST_CEG", "MADEIRA_STEAM_HOST_ACCOUNT", "MADEIRA_STEAM_HOST_STEAMID",
        "MADEIRA_DOCK_AUTH_FILE", "MADEIRA_DOCK_OFFLINE", "MADEIRA_DOCK_SESSION",
    ]

    /// The host's environment for one launch: nil unsets. No token, account name or
    /// SteamID is ever put in the environment.
    static func environment(stage: Stage, appID: Int, launchOption: UInt32, transfer: String) -> [(String, String?)] {
        var result = environmentKeys.map { ($0, String?.none) }
        func set(_ key: String, _ value: String) {
            if let index = result.firstIndex(where: { $0.0 == key }) { result[index].1 = value } else { result.append((key, value)) }
        }
        for key in ["MADEIRA_STEAM_HOST_PROBE", "MADEIRA_STEAM_HOST_SESSION", "MADEIRA_STEAM_HOST_LOGIN", "MADEIRA_STEAM_HOST_LAUNCH"] {
            set(key, "1")
        }
        set("MADEIRA_STEAM_HOST_APPID", String(appID))
        set("MADEIRA_STEAM_HOST_LAUNCH_OPTION", String(launchOption))
        set("MADEIRA_STEAM_HOST_CLIENT_DIR", windowsRoot)
        set("MADEIRA_STEAM_HOST_EXPECTED_INSTALL", stage.installPath)
        set("MADEIRA_STEAM_HOST_LOG", "C:\\madeira-dock.txt")
        set("MADEIRA_DOCK_AUTH_FILE", transfer)
        // WineProcessBridge publishes no fixed Steam game identity for a Dock
        // session: Valve's client gives the game its own.
        set("MADEIRA_DOCK_SESSION", "1")
        // Valve's client unloads DLLs while it starts, and the loader can map another
        // DLL of the same size at the same address. The engine's opt-in image-retire
        // switch gives that DLL fresh code instead of the unloaded one's translation.
        set("MADEIRA_JIT_IMAGE_RETIRE", "1")
        return result
    }

    // MARK: Report

    /// The host's report: a bounded set of numeric fields, never arbitrary guest text.
    struct Report: Equatable, Sendable {
        var fields: [String: String] = [:]
        var result: Int? { fields["probe-result"].flatMap(Int.init) }

        /// What the host is doing now, for the launch status line.
        var progress: String? {
            if fields["launch-game-running"] == "1" { return "Steam started the game. Waiting for display output…" }
            if fields["launch-request-submitted"] != nil || fields["launch-install-directory-verified"] != nil {
                return "Steam confirmed the license. Steam is starting the game…"
            }
            if fields["session-authenticated-online"] == "1" || fields["session-offline-ready"] == "1" {
                return "Signed in to Steam. Steam is checking this game's license…"
            }
            if fields["session-native-token-submitted"] != nil { return "Signing in to Steam…" }
            if fields["public-client021-present"] != nil { return "Valve's Steam client is loaded. Preparing sign-in…" }
            if fields["load-client-begin"] != nil { return "Loading Valve's Steam client. The first start can take a few minutes…" }
            if fields["probe-start-bits"] != nil { return "Madeira Dock started." }
            return nil
        }

        var failure: String? {
            guard let result, result != 0 else { return nil }
            if fields["another-client-or-process-query-error"] == "1" {
                return "Another Steam client is running in this game's environment. Restart Iridium and try again."
            }
            if fields["client-file-or-identity-error"] != nil, fields["client-sha256"] == nil {
                return "Madeira Dock could not open Valve's Steam client in this game's environment. Download the Steam components again in Settings."
            }
            if fields["launch-install-directory-mismatch"] == "1" {
                return "Steam reports a different install folder for this game than Iridium prepared. Export the log before trying again."
            }
            if result == 30 {
                if fields["session-unsupported-client"] == "1" || fields["session-user-method-mismatch"] != nil {
                    return "Madeira Dock does not support this Steam client build. The log has the client fingerprint and the failed check."
                }
                return "Madeira Dock could not initialize the Steam session (code 30). Export the log to identify the failed check."
            }
            // The host waits 90 s after sign-in for Valve's client to count the game
            // among the account's licences (madeira-dock src/session.c).
            if result == 34 {
                return fields["session-authenticated-online"] == "1"
                    ? "Steam signed in but did not confirm this game's license in time. Export the log before trying again."
                    : "Steam did not finish signing in. Check the connection and try again. If it keeps failing, sign out of Steam in Iridium and sign in again."
            }
            if result == 35 { return "Steam did not confirm a license for this game on the signed-in account." }
            if result == 50 {
                return fields["session-offline-abi"] == "0"
                    ? "There is no connection, and this Steam client build cannot be started offline by Madeira Dock. Connect to the internet and try again."
                    : "There is no connection, and Steam has nothing saved to sign this account in offline. Start a game once while online."
            }
            if result == 51 { return "There is no connection, and Steam refused to sign in offline. Connect to the internet and start the game once." }
            if result == 52 { return "Steam signed in offline, but what it has saved does not list this game. Start this game once while online." }
            if result == 37 {
                if fields["session-native-handoff-app-mismatch"] == "1" {
                    return "Madeira Dock received a sign-in transfer for a different launch. Restart Iridium and try again."
                }
                return "Madeira Dock could not read the one-use Steam sign-in transfer. Steam has not checked the login yet. Export the log before trying again."
            }
            if result == 49 {
                switch fields["ceg-result"].flatMap(Int.init) {
                case -1: return "Steam took too long to prepare this game's executable. Check the connection and try again."
                case 0: return "Steam did not start preparing this game's executable. Try again."
                case 10: return "Steam is busy with this game (updating or running). Try again in a moment."
                case -4: return "Steam's Windows service manager could not be started, so Steam could not prepare this game's executable."
                case -5: return "Steam's Windows service is not installed in this game's environment, so Steam could not prepare this game's executable."
                default: return "Steam could not prepare this game's executable for your account (code \(fields["ceg-result"] ?? "?"))."
                }
            }
            if result == 45 || result == 48, fields["launch-option-missing"] != nil || fields["launch-option-invalid"] != nil {
                return "Steam rejected this game's launch option. Remove steam-dock-launch-option from the game's iridium.cfg, or choose another option."
            }
            if result == 45 || result == 48, let error = fields["launch-client-error"].flatMap(Int.init),
               (22...23).contains(error), fields["launch-config-wait"] != nil {
                return "Steam did not finish loading this game's configuration after signing in. Wait a minute and start the game again."
            }
            if result == 45 || result == 48, fields["launch-client-error"] == "35", fields["launch-session-wait"] != nil {
                return "Steam still says this account is playing in another session. Close the game on your other device (or wait a few minutes) and start it again."
            }
            if result == 45 || result == 48, let error = fields["launch-client-error"].flatMap(Int.init),
               let reason = Self.launchRefusal(error, waited: result == 48) {
                return reason
            }
            if result == 46 { return "Steam started the game, but it ended without Steam confirming the launch. Export the log before trying again." }
            return "Madeira Dock could not complete the Steam launch (code \(result)). Export the log before trying again."
        }

        /// Valve's own launch refusal (EAppUpdateError) in words.
        static func launchRefusal(_ error: Int, waited: Bool) -> String? {
            switch error {
            case 5: return "Steam did not confirm a license for this game on the signed-in account."
            case 6, 21: return "Steam could not reach its servers to start this game. Check the connection and try again."
            case 16: return "Steam reports this game is already running. Close it, then try again."
            case 17, 19, 20:
                return waited
                    ? "Steam could not finish installing content this game needs. Try again later."
                    : "Steam needs to install or update content this game depends on before it can start. Start the game again to let Madeira Dock wait for Steam."
            case 18: return "Steam does not see this game as installed."
            case 28: return "Steam could not find the game's executable. If the game has several launch options, set steam-dock-launch-option in its iridium.cfg."
            case 29: return "Steam started this game's program, but Madeira could not load it. Export the log: it names the reason."
            case 22, 23, 24: return "Steam could not read this game's configuration. Try again."
            case 25: return "Steam says this game is not released yet."
            case 26: return "Steam says this game is not available in your region."
            case 35: return "Steam says this account is playing in another session. Close the game on your other device and start it again."
            default: return nil
            }
        }
    }

    static let reportAllowed: Set<String> = ["probe-start-bits", "client-machine", "client-pe-timestamp",
        "load-client-begin", "load-client-error", "public-client021-present", "engine005-present",
        "engine-factory-result", "session-client-adapter", "session-unsupported-client", "session-user-method-mismatch",
        "session-private-abi-verified", "session-login-disabled", "session-native-handoff-invalid",
        "session-native-handoff-app-mismatch", "session-handoff-stage", "session-handoff-error",
        "session-account-input-invalid", "session-app-input-invalid",
        "session-native-token-submitted", "session-logon-start-result", "session-connection-result",
        "session-authenticated-online", "session-requested-app-entitled", "session-subscription-count",
        "session-requested-app-listed", "session-auth-test-result",
        "session-online-subscription-count", "session-online-app-zero-query", "session-online-callback-id",
        "session-timeout-subscription-count", "session-timeout-app-listed", "session-timeout-still-online",
        "session-online-blip", "session-online-blips", "session-online-lost", "session-entitlement-source",
        "session-offline-abi", "session-offline-requested", "session-offline-can", "session-offline-logon-result",
        "session-offline-logon-retry", "session-offline-logon-state", "session-offline-callback-id",
        "session-offline-entitled", "session-offline-listed", "session-offline-timeout-state",
        "session-offline-fallback", "session-offline-ready",
        "another-probe-or-mutex-error", "invalid-client-directory", "another-client-or-process-query-error",
        "client-file-or-identity-error", "client-working-directory-error",
        "launch-option-index", "launch-option-invalid", "launch-option-missing",
        "launch-install-directory-verified", "launch-install-directory-mismatch",
        "launch-client-discovery-published", "launch-request-submitted", "launch-game-running", "launch-game-ended",
        "launch-discovery-restored", "launch-host-result", "launch-client-error",
        "launch-update-wait", "launch-update-retry", "launch-update-ready",
        "launch-config-wait", "launch-config-gave-up", "launch-session-wait", "launch-session-gave-up",
        "ceg-request", "ceg-request-result", "ceg-request-busy", "ceg-server-result", "ceg-job-result",
        "ceg-finished-jobs", "ceg-result", "ceg-disabled", "ceg-unsupported-client",
        "ceg-scm", "ceg-scm-started", "ceg-scm-error", "ceg-service-registered", "ceg-service-install", "ceg-service-stop", "ceg-scm-stopped",
        "shutdown-begin", "shutdown-complete", "probe-result"]
    /// The host's report rounds (madeira-dock src/main.c).
    static let reportRounds: Set<String> = ["ml1820", "ml1830", "ml1860", "ml1870", "ml1970", "ml1990", "ml2000",
                                            "ml2011", "ml2014", "ml2015", "ml2016"]

    static func parseReport(_ data: Data) -> Report {
        guard data.count <= 32768, let text = String(data: data, encoding: .utf8) else { return Report() }
        var report = Report()
        // A partial final line is ignored until the host completes and flushes it.
        for line in text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "[steam-host]", reportRounds.contains(String(parts[1])) else { continue }
            let field = parts[2].split(separator: "=", maxSplits: 1)
            guard field.count == 2 else { continue }
            let key = String(field[0]), value = String(field[1])
            if key == "client-sha256", value.utf8.count == 64,
               value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                report.fields[key] = value
            } else if reportAllowed.contains(key), let number = Int32(value) {
                report.fields[key] = String(number)
            }
        }
        return report
    }

    static func readReport(prefix: URL) -> Report? {
        let url = prefix.appendingPathComponent("drive_c/madeira-dock.txt")
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 32769), data.count <= 32768 else { return nil }
        return parseReport(data)
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
}

// MARK: Component download

private final class SteamDockRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let url = request.url
        let allowed = url?.scheme == "https" && url?.host == MadeiraSteamDock.originHost
            && (url?.port == nil || url?.port == 443) && url?.user == nil && url?.password == nil
        completionHandler(allowed ? request : nil)
    }
}

extension MadeiraSteamDock {
    /// Downloads the pinned packages, verifies them, unpacks them into a staging
    /// folder next to the store and replaces the store only when every file and
    /// the client fingerprint check out. Nothing runs in Wine.
    @available(iOS 15.0, macOS 12.0, *)
    static func installComponents(support: URL, progress: @Sendable (String) async -> Void) async throws {
        let fm = FileManager.default
        let invalid = Failure("Steam's components could not be verified. Try downloading them again.")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var folder = support
        try? folder.setResourceValues(values)
        guard let store = componentStore(support: support) else { throw invalid }
        let stage = support.appendingPathComponent("staging-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: configuration, delegate: SteamDockRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var names = Set<String>()
        for (index, package) in packages.enumerated() {
            try Task.checkCancellation()
            await progress("Downloading Valve's Steam components (\(index + 1) of \(packages.count), \(package.bytes / 1_000_000) MB)…")
            guard let url = URL(string: origin + package.file) else { throw invalid }
            let (temporary, response) = try await session.download(from: url)
            defer { try? fm.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url?.host == originHost, http.url?.scheme == "https",
                  (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize == package.bytes else {
                throw Failure("Valve's update server did not return the expected Steam component. Check the connection and try again.")
            }
            let archive = try Data(contentsOf: temporary, options: .mappedIfSafe)
            await progress("Verifying Valve's Steam components (\(index + 1) of \(packages.count))…")
            guard sha256(archive) == package.sha256 else { throw invalid }
            try unpack(archive) { name, bytes in
                guard names.insert(name.lowercased()).inserted else { throw invalid }
                let file = stage.appendingPathComponent(name)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: file, options: .atomic)
            }
        }
        guard names.contains("steam.exe"),
              try sha256(file: stage.appendingPathComponent("steamclient64.dll")) == clientSHA256 else { throw invalid }
        try Task.checkCancellation()
        try Data((clientSHA256 + "\n").utf8).write(to: stage.appendingPathComponent(readyMarker), options: .atomic)
        if fm.fileExists(atPath: store.path) { try fm.removeItem(at: store) }
        try fm.moveItem(at: stage, to: store)
        await progress("Valve's Steam components are ready.")
    }
}
