import Foundation
import Combine

/// The Panel's own state on the store, so collapsing the Panel — or switching
/// between its two columns, or a size-class change — keeps the query, the
/// results and the last action's result (N-09, A-31).
extension HomeStore {
    /// `GET /v1/catalog?q=` — the host searches the same merged catalog the
    /// tree came from. Until its answer lands the Panel matches locally over
    /// the rows it already has, so typing never shows an empty list it will
    /// then fill in.
    func searchCatalog(_ query: String) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard !term.isEmpty else { searchResults = nil; searchTask = nil; return }
        guard !profile.mock, companionConnected, let service = client else { searchResults = nil; return }
        let current = connectionGeneration
        searchTask = Task { [weak self] in
            // One keystroke is not one request.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self, self.connectionGeneration == current else { return }
            guard let catalog = try? await service.searchCatalog(term) else { return }
            guard !Task.isCancelled, self.connectionGeneration == current,
                  self.panelQuery.trimmingCharacters(in: .whitespacesAndNewlines) == term else { return }
            // The result rows are catalog entries, so they are built by the
            // same compiler as the tree and carry the same route verdicts.
            self.searchResults = HostMenu.build(from: catalog.entries).flatMap(\.all)
                .filter { $0.children.isEmpty }
        }
    }

    /// A-12. `accepted` is what the host said it took; `applied` and `failed`
    /// are what it said happened. Nothing here reports a result the host has
    /// not confirmed.
    func reportToast(_ toast: PanelToast) {
        panelToast = toast
        let id = toast.id
        toastTask?.cancel()
        // 2s, and only for a settled result: an `accepted` that never resolves
        // stays on screen rather than disappearing into nothing.
        guard toast.stage != .accepted else { return }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.panelToast?.id == id else { return }
            self.panelToast = nil
        }
    }

    func settleToast(id: UUID, stage: PanelToast.Stage, detail: String?) {
        guard var toast = panelToast, toast.id == id else { return }
        toast.stage = stage
        toast.detail = detail
        reportToast(toast)
    }
}
