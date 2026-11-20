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
        var appearance: PulseAppearance = .solid   // the person's Classic, Glass or Solid: a slot's fallback theme
        var skin: String?   // before Settings › Appearance (read only, for the move): nil = Classic, "groove", "groove-black"
        var mode: AppearanceMode?   // nil = not chosen yet: see `themeChoice`
        var lightTheme: String?     // a theme's id: a built-in's or a theme file's name (`ThemeStore`)
        var darkTheme: String?
        var glassLevel: GlassLevel?   // prototype, nil = off: `GlassLevels.swift`
        var wallpaperLight: String? { didSet { if wallpaperLight != oldValue { railFocusLight = nil; railZoomLight = nil } } }
        var wallpaperDark: String? { didSet { if wallpaperDark != oldValue { railFocusDark = nil; railZoomDark = nil } } }
        var railFocusLight: CGPoint?
        var railZoomLight: CGFloat?
        var railFocusDark: CGPoint?
        var railZoomDark: CGFloat?

        /// Settings › Appearance. Until it's first chosen, it's what Pulse drew before: Classic (Glass or Solid) in both
        /// modes, or for Groove, Groove White in light and Groove in dark (Groove Black: Groove Black in light), in Auto.
        var themeChoice: ThemeChoice {
            get {
                let classic = appearance == .glass ? "classic-glass" : "classic-solid"
                let before: (light: String, dark: String) = switch skin {
                case "groove": ("groove-white", "groove")
                case "groove-black": ("groove-black", "groove")
                default: (classic, classic)
                }
                return ThemeChoice(mode: mode ?? .auto, light: lightTheme ?? before.light, dark: darkTheme ?? before.dark, classic: classic)
            }
            set {
                mode = newValue.mode
                lightTheme = newValue.light
                darkTheme = newValue.dark
                appearance = newValue.classic == "classic-glass" ? .glass : .solid
            }
        }
        var dock: DockEdge?
        var tucked: Bool?   // nil = out: the rail tucked into its edge, a sliver left on screen
        var tuckPeek: Bool?   // nil = off: resting the pointer on the sliver slides the rail out until it leaves
        var voiceHotKey: HotKeyCombo?   // nil = the default shortcut
        var agentsHotKey: HotKeyCombo?   // nil = the default shortcut; `HotKeyCombo.none` = cleared
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

        var agentSettings: AgentSettings?   // nil = defaults
        var agyHold: AgyPause.Hold?   // nil = none: Antigravity polling held back by a sign-out or failed runs
        var agents: AgentSettings {
            get { agentSettings ?? AgentSettings() }
            set { agentSettings = newValue }
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
            skin = c.lenient(String.self, forKey: .skin, in: decoder)
            mode = c.lenient(AppearanceMode.self, forKey: .mode, in: decoder)
            lightTheme = c.lenient(String.self, forKey: .lightTheme, in: decoder)
            darkTheme = c.lenient(String.self, forKey: .darkTheme, in: decoder)
            glassLevel = c.lenient(GlassLevel.self, forKey: .glassLevel, in: decoder)
            wallpaperLight = c.lenient(String.self, forKey: .wallpaperLight, in: decoder)
            wallpaperDark = c.lenient(String.self, forKey: .wallpaperDark, in: decoder)
            railFocusLight = c.lenient(CGPoint.self, forKey: .railFocusLight, in: decoder)
            railZoomLight = c.lenient(CGFloat.self, forKey: .railZoomLight, in: decoder)
            railFocusDark = c.lenient(CGPoint.self, forKey: .railFocusDark, in: decoder)
            railZoomDark = c.lenient(CGFloat.self, forKey: .railZoomDark, in: decoder)
            dock = c.lenient(DockEdge.self, forKey: .dock, in: decoder)
            tucked = c.lenient(Bool.self, forKey: .tucked, in: decoder)
            tuckPeek = c.lenient(Bool.self, forKey: .tuckPeek, in: decoder)
            voiceHotKey = c.lenient(HotKeyCombo.self, forKey: .voiceHotKey, in: decoder)
            agentsHotKey = c.lenient(HotKeyCombo.self, forKey: .agentsHotKey, in: decoder)
            showPet = c.lenient(Bool.self, forKey: .showPet, in: decoder)
            showRemaining = c.lenient(Bool.self, forKey: .showRemaining, in: decoder)
            hiddenPools = c.lenient(Set<String>.self, forKey: .hiddenPools, in: decoder)
            limitAlerts = c.lenient([String: Date].self, forKey: .limitAlerts, in: decoder)
            batterySettings = c.lenient(BatterySettings.self, forKey: .batterySettings, in: decoder)
            breakSettings = c.lenient(BreakSettings.self, forKey: .breakSettings, in: decoder)
            agentSettings = c.lenient(AgentSettings.self, forKey: .agentSettings, in: decoder)
            agyHold = c.lenient(AgyPause.Hold.self, forKey: .agyHold, in: decoder)
        }

        /// The shortcut to hold for the agents card and, when the chosen one can't be used, why. None is held while
        /// the agents ring isn't on the rail, so the combination stays free for other apps, or once it was cleared.
        func agentsShortcut(rexFound: Bool) -> (combo: HotKeyCombo?, note: String?) {
            let combo = agentsHotKey ?? .agentsDefault
            guard showOverlay, agents.onRail(rexFound: rexFound), combo != .none else { return (nil, nil) }
            if showPet != false, combo == voiceHotKey ?? .voiceDefault {
                return (nil, "\(combo.label) is the Codex pet's voice shortcut. Choose another one here.")
            }
            return (combo, nil)
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

    var agentsHotKeyBinding: Binding<HotKeyCombo> {
        Binding(get: { self.persisted.agentsHotKey ?? .agentsDefault }, set: { self.persisted.agentsHotKey = $0 == .agentsDefault ? nil : $0 })
    }

    var measuredRailSize: CGSize = .zero
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
    @Published var cardVisible = false { didSet { if !cardVisible, agentsByKeyboard { agentsByKeyboard = false } } }
    /// "battery" or "agents": the open card is that ring's, not the selected account's.
    @Published var sideCard: String? { didSet { if sideCard != "agents", agentsByKeyboard { agentsByKeyboard = false } } }
    /// The agents card was opened by its shortcut and holds the keyboard (↑ ↓ Return Esc) until it closes. Like the
    /// pet's card it then stays open when the pointer passes over it and leaves.
    @Published private(set) var agentsByKeyboard = false
    @Published var hoveringOverlay = false
    @Published var petVisible = false   // the Codex pet's chat/voice card (mutually exclusive with a usage card)
    @Published var snapshots: [AccountID: AccountSnapshot]
    @Published var refreshing = false
    @Published var dragging = false
    @Published var peeking = false   // a tucked rail slid out while the pointer rests on it
    var gliding = false   // the rail is moving to its edge: hover changes would move its target mid-flight
    // the break cup's menu is up: the pointer leaves the rail to reach it, which mustn't close it; tooltips hide meanwhile
    @Published var menuOpen = false
    @Published var settingsTab = SettingsPane.appearance   // the pane Settings shows, kept while Pulse runs; Break settings… opens Breaks
    private var refreshRequested = false
    private var agy = AgyPause() { didSet { if persisted.agyHold != agy.hold { persisted.agyHold = agy.hold } } }
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
        // a sign-out or failed runs from before the quit hold agy back after the launch too
        agy = AgyPause(restoring: saved.agyHold, marker: AntigravityAdapter.sessionMarker())
        if cached[.claude]?.source == .officialUsagePage { ClaudeWeb.connected = true }   // signed in before this was remembered
        if let first = enabledAccounts.first { selected = first }

        // shortcut: one flat 2-min poll for everything; per-adapter budgets if a provider ever throttles
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

    /// The battery's card or the agents': a second click on the same ring closes it.
    func toggleSide(_ card: String) {
        guard !dragging else { return }
        petVisible = false
        if cardVisible, sideCard == card {
            cardVisible = false
        } else {
            sideCard = card
            cardVisible = true
        }
    }

    /// The agents shortcut: opens the agents card with the keyboard in it, its first row selected, or closes that
    /// card if it's the one open. A tucked rail comes out for it, as for any card.
    func toggleAgentsCard() {
        guard !dragging else { return }
        guard AgentCardSelection.shortcutOpens(cardVisible: cardVisible, sideCard: sideCard) else { return collapseOverlay() }
        petVisible = false
        sideCard = "agents"
        cardVisible = true
        AgentsMonitor.shared.resetSelection()
        agentsByKeyboard = true
    }

    func collapseOverlay() {
        guard !dragging, !menuOpen else { return }
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
            agy.passStarted(marker: AntigravityAdapter.sessionMarker())
            await withTaskGroup(of: AccountSnapshot?.self) { group in
                for id in enabledAccounts where !(id == .antigravity && agy.paused) {
                    group.addTask { [fetches] in await fetches.answer(id) }
                }
                for await case let snap? in group {
                    if snap.id == .antigravity { agy.update(with: snap, marker: AntigravityAdapter.sessionMarker()) }
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
