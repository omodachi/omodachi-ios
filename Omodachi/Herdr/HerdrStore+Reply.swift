import Foundation
import UIKit

/// HERDR-11 on the Herdr surface: what the New workspace card starts, the
/// starred folders, and a mirror that says when it is not current. (The
/// agent's latest reply over the mirror went in HERDR-12: on a phone it took
/// too much of the screen.)
extension HerdrStore {
    // MARK: - §1 Folders and launchers

    func applyFolders(_ value: HerdrFoldersDTO) {
        recentFolders = value.recent ?? []
        commonFolders = value.common ?? []
        favouritesSupported = value.favourites != nil
        favouriteFolders = value.favourites ?? []
        launchers = value.launchers ?? []
        // A launcher remembered from another host, or one this host dropped,
        // falls back to a plain shell rather than to something else.
        if let chosen = chosenLauncher, !launchers.contains(where: { $0.command == chosen }) { chosenLauncher = nil }
        loadingFolders = false
    }

    /// The Start row: a plain shell (nil) or one of the host's launchers.
    func chooseLauncher(_ command: String?) {
        chosenLauncher = command
        HerdrLauncherPreference(defaults: home.defaults).launcher = command
    }

    func isFavourite(_ folder: HerdrFolderDTO) -> Bool {
        favouriteFolders.contains { $0.path == folder.path }
    }

    /// A star on a folder row. The host keeps the list for all its devices
    /// and answers with the folders document, which the card redraws from.
    func toggleFavourite(_ folder: HerdrFolderDTO) {
        let on = !isFavourite(folder)
        if demoData != nil, HERDR11Fixture.folders != nil {
            favouriteFolders = on ? favouriteFolders + [folder] : favouriteFolders.filter { $0.path != folder.path }
            fixtureSent.append("favourite \(folder.display) \(on)") // non-copy: a test line
            return
        }
        guard favouritesSupported else { return }
        // Drawn at once; the host's answer replaces it.
        favouriteFolders = on ? favouriteFolders + [folder] : favouriteFolders.filter { $0.path != folder.path }
        Task { [weak self] in
            guard let self else { return }
            do {
                let client = try self.home.chatClient(for: self.home.profile.companionURL)
                let value = try await client.herdrFavourite(path: folder.path, on: on)
                guard self.newWorkspaceOpen else { return }
                self.applyFolders(value)
            } catch {
                guard self.newWorkspaceOpen else { return }
                self.favouriteFolders = on ? self.favouriteFolders.filter { $0.path != folder.path }
                    : self.favouriteFolders + [folder]
                self.newWorkspaceError = Self.message(error)
            }
        }
    }

    // MARK: - §3 A mirror that says when it is not current

    func mirrorSeen() {
        mirrorSeenAt = Date()
        if mirrorStale { recomputeStale() }
    }

    func startStaleWatch() {
        staleTask?.cancel()
        networkReturnsSeen = home.networkReturns
        staleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.recomputeStale()
            }
        }
    }

    func recomputeStale(now: Date = Date()) {
        // The network came back: the mirror reconnects now, not after its backoff.
        if home.networkReturns != networkReturnsSeen {
            networkReturnsSeen = home.networkReturns
            if selected != nil, demoData == nil, !connection.isLive || mirrorStale { restartStream() }
        }
        // The demo's mirror is text the app carries: it is never stale, but
        // for the UI fixture that holds the clock in one state.
        guard selected != nil, demoData == nil || ConnectionHealthFixture.forced != nil, let seen = mirrorSeenAt else {
            if mirrorStale { mirrorStale = false }
            return
        }
        let silence = now.timeIntervalSince(seen)
        let stale = !home.health.isLive || silence >= ConnectionHealth.troubleAfter
            || ConnectionHealthFixture.forced != nil
        if stale != mirrorStale { mirrorStale = stale }
        // A watching socket that has not answered for the red interval is a
        // socket whose path died: it is replaced (at most every 15 s).
        if silence >= ConnectionHealth.lostAfter, connection.isLive,
           now.timeIntervalSince(lastStaleRestart) >= ConnectionHealth.lostAfter {
            lastStaleRestart = now
            restartStream()
        }
    }

    /// The "Last update 14:32" words on a stale mirror.
    var mirrorStaleLabel: String? {
        guard mirrorStale, let seen = mirrorSeenAt else { return nil }
        return Strings.herdrMirrorLastUpdate(seen.formatted(date: .omitted, time: .shortened))
    }
}

/// HERDR-11: which launcher the New workspace card starts, remembered on
/// this device.
struct HerdrLauncherPreference {
    let defaults: UserDefaults
    private static let launcherKey = "omodachi.herdr.launcher.v1" // non-copy: a defaults key

    var launcher: String? {
        get { defaults.string(forKey: Self.launcherKey) }
        nonmutating set {
            if let newValue { defaults.set(newValue, forKey: Self.launcherKey) }
            else { defaults.removeObject(forKey: Self.launcherKey) }
        }
    }
}
