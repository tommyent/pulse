import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static weak var shared: AppState?
    struct Persisted: Codable {
        var enabled: Set<AccountID> = Set(AccountID.allCases)
        var order: [AccountID] = AccountID.allCases
        var alwaysOnTop: Bool = true
        var showOverlay: Bool = true
        var lightMode: Bool?   // optional so old state.json still decodes
        var dock: DockEdge?
        var voiceHotKey: HotKeyCombo?   // nil = default ⌘⌥V
    }

    var voiceHotKey: HotKeyCombo { persisted.voiceHotKey ?? .voiceDefault }
    var voiceHotKeyBinding: Binding<HotKeyCombo> {
        Binding(get: { self.voiceHotKey }, set: { self.persisted.voiceHotKey = $0 == .voiceDefault ? nil : $0 })
    }

    var dock: DockEdge { persisted.dock ?? .right }

    var isLight: Bool { persisted.lightMode ?? false }
    var lightModeBinding: Binding<Bool> {
        Binding(get: { self.persisted.lightMode ?? false }, set: { self.persisted.lightMode = $0 })
    }

    @Published var persisted: Persisted { didSet { save() } }
    @Published var selected: AccountID = .claude
    @Published var cardVisible = false
    @Published var hoveringOverlay = false
    @Published var petVisible = false   // the Codex pet's chat/voice card (mutually exclusive with a usage card)
    @Published var snapshots: [AccountID: AccountSnapshot]
    @Published var refreshing = false
    @Published var dragging = false
    private var refreshRequested = false

    private static let dir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Pulse")
    private static let stateURL = dir.appending(path: "state.json")
    private static let snapshotsURL = dir.appending(path: "snapshots.json")

    init() {
        var saved = (try? JSONDecoder().decode(Persisted.self, from: Data(contentsOf: Self.stateURL))) ?? Persisted()
        // accounts added since state.json was written start enabled, as on a fresh install
        for id in AccountID.allCases where !saved.order.contains(id) {
            saved.order.append(id)
            saved.enabled.insert(id)
        }
        persisted = saved
        defer { Self.shared = self }
        // last run's snapshots, shown as stale until the first live fetch lands
        var cached = (try? JSONDecoder().decode([AccountID: AccountSnapshot].self,
                                                from: Data(contentsOf: Self.snapshotsURL))) ?? [:]
        for k in cached.keys where cached[k]?.health == .ok { cached[k]?.health = .stale }
        snapshots = cached
        if let first = enabledAccounts.first { selected = first }

        // ponytail: one flat 2-min poll for everything (three small GETs); per-adapter budgets if a provider ever throttles
        Task {
            while true {
                await refreshAll()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    var enabledAccounts: [AccountID] {
        persisted.order.filter { persisted.enabled.contains($0) }
    }

    func collapseOverlay() {
        guard !dragging else { return }
        if cardVisible { cardVisible = false }
        if petVisible { petVisible = false }
        if hoveringOverlay { hoveringOverlay = false }
    }

    func refreshAll() async {
        guard !refreshing else { refreshRequested = true; return }
        refreshing = true
        repeat {
            refreshRequested = false
            await withTaskGroup(of: AccountSnapshot.self) { group in
                for id in enabledAccounts { group.addTask { await fetchSnapshot(id) } }
                for await snap in group {
                    // keep last good windows for stale display instead of blanking the card
                    if snap.windows.isEmpty, let old = snapshots[snap.id], !old.windows.isEmpty,
                       snap.health == .providerError {
                        var stale = old
                        stale.health = .stale
                        snapshots[snap.id] = stale
                    } else {
                        snapshots[snap.id] = snap
                    }
                }
            }
        } while refreshRequested
        refreshing = false
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshots).write(to: Self.snapshotsURL, options: .atomic)
    }

    func isEnabled(_ id: AccountID) -> Binding<Bool> {
        Binding(
            get: { self.persisted.enabled.contains(id) },
            set: { on in
                if on { self.persisted.enabled.insert(id) } else { self.persisted.enabled.remove(id) }
                if !on, self.selected == id, let first = self.enabledAccounts.first { self.selected = first }
                if on { Task { await self.refreshAll() } }
            })
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(persisted).write(to: Self.stateURL, options: .atomic)
    }
}
