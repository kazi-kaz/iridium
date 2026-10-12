#if MADEIRA_RUNTIME
import SwiftUI

/// Downloads Valve's Steam client components for Madeira Dock once, off the UI
/// thread, and reports what happened. The pinned packages are verified before
/// anything replaces the stored copy (MadeiraSteamDock.installComponents).
@MainActor
final class SteamDockComponentsModel: ObservableObject {
    static let shared = SteamDockComponentsModel()
    @Published private(set) var ready = MadeiraSteamDock.componentsReady()
    @Published private(set) var status: String?
    @Published private(set) var running = false
    private var work: Task<Result<Void, Error>, Never>?

    func download() {
        guard !running, let support = MadeiraSteamDock.supportFolder() else { return }
        running = true
        status = "Connecting to Valve's update server…"
        RuntimeLogCapture.writeLine("[SteamDock] components download=started")
        let work = Task.detached(priority: .userInitiated) { () async -> Result<Void, Error> in
            do {
                try await MadeiraSteamDock.installComponents(support: support) { text in
                    await MainActor.run { SteamDockComponentsModel.shared.status = text }
                }
                return .success(())
            } catch { return .failure(error) }
        }
        self.work = work
        Task { [weak self] in
            let outcome = await work.value
            guard let self else { return }
            running = false
            ready = MadeiraSteamDock.componentsReady()
            switch outcome {
            case .success:
                status = "Valve's Steam components are ready."
                RuntimeLogCapture.writeLine("[SteamDock] components download=ready")
            case .failure(let error):
                status = error is CancellationError ? "Download cancelled." : error.localizedDescription
                RuntimeLogCapture.writeLine("[SteamDock] components download=failed")
            }
            self.work = nil
        }
    }

    func cancel() { work?.cancel() }

    func remove() {
        guard !running, let store = MadeiraSteamDock.componentStore() else { return }
        do {
            if FileManager.default.fileExists(atPath: store.path) { try FileManager.default.removeItem(at: store) }
            status = "Removed. Games that already used Madeira Dock keep their own copy until their environment is reset."
        } catch {
            status = "The components could not be removed: \(error.localizedDescription)"
        }
        ready = MadeiraSteamDock.componentsReady()
    }
}

struct SteamDockSettingsView: View {
    @AppStorage(MadeiraSteamDock.modeKey) private var mode = MadeiraSteamDock.Mode.drm.rawValue
    @ObservedObject private var components = SteamDockComponentsModel.shared
    @ObservedObject private var steam = SteamLibraryModel.shared

    var body: some View {
        List {
            Section("Start Steam Games with Madeira Dock") {
                ForEach(MadeiraSteamDock.Mode.allCases, id: \.rawValue) { option in
                    MenuButton { mode = option.rawValue } label: {
                        HStack {
                            Text(option.title)
                            Spacer()
                            if mode == option.rawValue { Image(systemName: "checkmark") }
                        }
                    }
                }
                Text("Madeira Dock runs Valve's own Steam client without its window. It signs in with the Steam account you use in Iridium, Steam checks that you own the game, and Steam starts it. The game's Steam calls, such as its DRM check, go to that client as on Windows. Experimental. It applies to games downloaded with Iridium's Steam tab. steam-dock = on or off in a game's iridium.cfg overrides this setting for that game.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Valve's Steam Client Components") {
                MenuValue("Status", value: components.ready ? "Ready" : components.running ? "Downloading" : "Not downloaded")
                if components.running {
                    MenuButton("Cancel Download", role: .destructive) { components.cancel() }
                } else if components.ready {
                    MenuButton("Download Again") { components.download() }
                    MenuButton("Remove Components", role: .destructive) { components.remove() }
                } else {
                    MenuButton("Download (\(MadeiraSteamDock.downloadBytes / 1_000_000) MB)", systemImage: "arrow.down.circle") {
                        components.download()
                    }
                }
                if let status = components.status {
                    Text(status).font(.footnote)
                }
                Text("Downloaded once from Valve's update server and checked against the exact client build Madeira Dock supports. Nothing is downloaded from anywhere else.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Steam Account") {
                MenuValue("Iridium Sign-In", value: steam.account.map { "Signed in as \($0)" } ?? "Not signed in")
                Text("Madeira Dock hands your saved Iridium Steam sign-in to Valve's client through a one-use private file that is deleted as soon as it is read. While a game runs through Madeira Dock, Iridium's own Steam connection is closed; restart Iridium to download again.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Steam Games")
        .navigationBarTitleDisplayMode(.inline)
        .iridiumListChrome()
    }
}

#endif
