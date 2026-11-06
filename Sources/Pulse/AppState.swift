import CryptoKit
import SwiftUI
import os

private let log = Logger(subsystem: "io.github.tommyent.pulse", category: "state")

@MainActor
final class AppState: ObservableObject {
    static weak var shared: AppState?
    struct Persisted: Codable {
        var enabled: Set<AccountID> = Set(AccountID.allCases)
        var order: [AccountID] = AccountID.allCases
        var alwaysOnTop: Bool = true
        var showOverlay: Bool = true
        var appearance: PulseAppearance = .solid
        var dock: DockEdge?
        var tucked: Bool?   // nil = out: the rail tucked into its edge, a sliver left on screen
        var tuckPeek: Bool?   // nil = off: resting the pointer on the sliver slides the rail out until it leaves
        var voiceHotKey: HotKeyCombo?   // nil = the default shortcut
        var showPet: Bool?   // nil = shown; independent of the Codex usage switch
        var showRemaining: Bool?   // nil = off: rings show what's used
        var hiddenPools: Set<String>?   // nil = none: "account.pool" for a later pool whose ring is switched off
        var limitAlerts: [String: Date]?   // "account.window" → the reset already announced near its limit

        var batterySettings: BatterySettings?   // nil = defaults
        var battery: BatterySettings {
            get { batterySettings ?? BatterySettings() }
            set { batterySettings = newValue }
        }

        var breakSettings: BreakSettings?   // nil = defaults
        var breaks: BreakSettings {
            get { breakSettings ?? BreakSettings() }
            set { breakSettings = newValue }
        }

        init() {}

        private enum LegacyKeys: String, CodingKey { case glassTint }
        /// One value this version can't read, such as a newer Pulse's account or edge, costs only that value.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let fresh = Persisted()
            func accounts(_ key: CodingKeys) -> [AccountID]? {
                guard let names = c.lenient([String].self, forKey: key, in: decoder) else { return nil }
                let known = names.compactMap(AccountID.init(rawValue:))
                if known.count != names.count { (decoder.userInfo[.decodeLosses] as? DecodeLosses)?.any = true }
                return known
            }
            enabled = accounts(.enabled).map { Set($0) } ?? fresh.enabled
            order = accounts(.order) ?? fresh.order
            alwaysOnTop = c.lenient(Bool.self, forKey: .alwaysOnTop, in: decoder) ?? fresh.alwaysOnTop
            showOverlay = c.lenient(Bool.self, forKey: .showOverlay, in: decoder) ?? fresh.showOverlay
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            appearance = c.lenient(PulseAppearance.self, forKey: .appearance, in: decoder)
                ?? ((try? legacy.decode(Bool.self, forKey: .glassTint)) == false ? .glass : .solid)
            dock = c.lenient(DockEdge.self, forKey: .dock, in: decoder)
            tucked = c.lenient(Bool.self, forKey: .tucked, in: decoder)
            tuckPeek = c.lenient(Bool.self, forKey: .tuckPeek, in: decoder)
            voiceHotKey = c.lenient(HotKeyCombo.self, forKey: .voiceHotKey, in: decoder)
            showPet = c.lenient(Bool.self, forKey: .showPet, in: decoder)
            showRemaining = c.lenient(Bool.self, forKey: .showRemaining, in: decoder)
            hiddenPools = c.lenient(Set<String>.self, forKey: .hiddenPools, in: decoder)
            limitAlerts = c.lenient([String: Date].self, forKey: .limitAlerts, in: decoder)
            batterySettings = c.lenient(BatterySettings.self, forKey: .batterySettings, in: decoder)
            breakSettings = c.lenient(BreakSettings.self, forKey: .breakSettings, in: decoder)
        }

        /// The settings at `url`, and whether a save may replace that file. Anything Pulse couldn't read first gets a copy
        /// beside it, named for its contents so each version is kept once, because the next save would otherwise erase it.
        /// With no copy, or a file that's there but can't be opened right now, saves wait: nothing is lost that way.
        static func load(from url: URL) -> (settings: Persisted, canReplace: Bool) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path) else { return (Persisted(), true) }
            guard let data = try? Data(contentsOf: url) else {
                log.error("settings can't be opened: using defaults for now, and not saving over them")
                return (Persisted(), false)
            }
            let losses = DecodeLosses(), decoder = JSONDecoder()
            decoder.userInfo[.decodeLosses] = losses
            let saved = try? decoder.decode(Persisted.self, from: data)
            guard saved == nil || losses.any else { return (saved ?? Persisted(), true) }
            let name = SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
            let aside = url.deletingLastPathComponent().appending(path: "state-unreadable-\(name).json")
            let kept = fm.fileExists(atPath: aside.path) || (try? data.write(to: aside, options: .atomic)) != nil
            log.error("settings had values Pulse can't read: \(kept ? "kept a copy as \(aside.lastPathComponent)" : "no copy could be kept, not saving over them", privacy: .public)")
            return (saved ?? Persisted(), kept)
        }
    }

    var showsPet: Bool { persisted.showPet ?? true }
    var showPetBinding: Binding<Bool> {
        Binding(get: { self.showsPet }, set: { self.persisted.showPet = $0 })
    }

    var voiceHotKey: HotKeyCombo { persisted.voiceHotKey ?? .voiceDefault }
    var voiceHotKeyBinding: Binding<HotKeyCombo> {
        Binding(get: { self.voiceHotKey }, set: { self.persisted.voiceHotKey = $0 == .voiceDefault ? nil : $0 })
    }

    var dock: DockEdge { persisted.dock ?? .right }

    /// Tucked and not peeking out: the rail rests past its edge with only a sliver on screen. Dragged out by its sliver,
    /// it shows as a rail at once; it stays tucked in `persisted` until the drop decides.
    var tuckedAway: Bool { persisted.tucked == true && !peeking && !dragging }
    var tuckedBinding: Binding<Bool> {
        Binding(get: { self.persisted.tucked == true }, set: {
            if $0 { self.collapseOverlay() }   // nothing stays open beside a rail that's going away
            self.persisted.tucked = $0 ? true : nil
            self.peeking = false
        })
    }
    var tuckPeekBinding: Binding<Bool> {
        Binding(get: { self.persisted.tuckPeek == true }, set: { self.persisted.tuckPeek = $0 ? true : nil })
    }

    var showsRemaining: Bool { persisted.showRemaining ?? false }
    var showsRemainingBinding: Binding<Bool> {
        Binding(get: { self.showsRemaining }, set: { self.persisted.showRemaining = $0 })
    }

    @Published var persisted: Persisted { didSet { save() } }
    @Published var selected: AccountID = .claude { didSet { selectedPool = 0 } }
    @Published var selectedPool = 0   // which of the selected account's rings opened the card (`[UsageWindow].pools`)
    @Published var cardVisible = false
    @Published var hoveringOverlay = false
    @Published var petVisible = false   // the Codex pet's chat/voice card (mutually exclusive with a usage card)
    @Published var snapshots: [AccountID: AccountSnapshot]
    @Published var refreshing = false
    @Published var dragging = false
    @Published var peeking = false   // a tucked rail slid out while the pointer rests on it
    var gliding = false   // the rail is moving to its edge: hover changes would move its target mid-flight
    private var refreshRequested = false
    private var agy = AgyPause()   // agy signed out or stalled: only a manual refresh runs it again
    private let fetches = ProviderFetches { await fetchSnapshot($0) }
    private var canSave = true   // false: saving now could erase settings Pulse couldn't read or keep a copy of

    private static let dir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Pulse")
    private static let stateURL = dir.appending(path: "state.json")
    private static let snapshotsURL = dir.appending(path: "snapshots.json")

    init() {
        let loaded = Persisted.load(from: Self.stateURL)
        var saved = loaded.settings
        canSave = loaded.canReplace
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
        if cached[.claude]?.source == .officialUsagePage { ClaudeWeb.connected = true }   // signed in before this was remembered
        if let first = enabledAccounts.first { selected = first }

        // ponytail: one flat 2-min poll for everything; per-adapter budgets if a provider ever throttles
        Task {
            while true {
                await refreshAll(manual: false)
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
        if peeking { peeking = false }   // a peeking rail tucks back in
    }

    func refreshAll(manual: Bool = true) async {
        if manual { agy.manualRefresh(whileRefreshing: refreshing) }
        guard !refreshing else { refreshRequested = true; return }
        refreshing = true
        repeat {
            refreshRequested = false
            agy.passStarted()
            await withTaskGroup(of: AccountSnapshot?.self) { group in
                for id in enabledAccounts where !(id == .antigravity && agy.paused) {
                    group.addTask { [fetches] in await fetches.answer(id) }
                }
                for await case let snap? in group {
                    if snap.id == .antigravity { agy.update(with: snap) }
                    // keep last good windows for stale display instead of blanking the card
                    if snap.windows.isEmpty, let old = snapshots[snap.id], !old.windows.isEmpty,
                       snap.health == .providerError {
                        snapshots[snap.id] = snap.staleKeeping(old)
                    } else {
                        snapshots[snap.id] = snap.keepingHistory(of: snapshots[snap.id])
                    }
                    announceNearLimit(snap)
                }
            }
        } while refreshRequested
        refreshing = false
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshots).write(to: Self.snapshotsURL, options: .atomic)
    }

    /// The windows that just crossed 98% go to Pulse's own alert, which stays on screen until dismissed.
    private func announceNearLimit(_ snap: AccountSnapshot) {
        let before = persisted.limitAlerts ?? [:]
        var alerted = before
        let crossed = snap.newlyNearLimit(alerted: &alerted)
        if alerted != before { persisted.limitAlerts = alerted }
        guard !crossed.isEmpty else { return }
        LimitAlert.shared.show(snap, crossed: crossed, state: self)
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

    /// A later pool's ring (`[UsageWindow].ringPools`): on until it's switched off.
    func showsPool(_ id: AccountID, _ pool: String) -> Binding<Bool> {
        let key = "\(id.rawValue).\(pool)"
        return Binding(
            get: { self.persisted.hiddenPools?.contains(key) != true },
            set: { on in
                var hidden = self.persisted.hiddenPools ?? []
                if on { hidden.remove(key) } else { hidden.insert(key) }
                self.persisted.hiddenPools = hidden.isEmpty ? nil : hidden
            })
    }

    private func save() {
        guard canSave else { return }
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(persisted).write(to: Self.stateURL, options: .atomic)
    }
}
