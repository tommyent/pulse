import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension AppState.Persisted {
    func glass(for theme: PulseTheme, slot: ColorScheme) -> GlassSetting? {
        guard theme.id != "classic-solid", let glassLevel else { return nil }
        let focus = slot == .light ? railFocusLight : railFocusDark
        let zoom = slot == .light ? railZoomLight : railZoomDark
        let rotated = slot == .light ? railRotatedLight : railRotatedDark
        return GlassSetting(level: glassLevel, wallpaper: slot == .light ? wallpaperLight : wallpaperDark,
                            wallpaperCrop: WallpaperCrop(focus: focus ?? WallpaperCrop.middle, zoom: zoom ?? 1, rotated: rotated ?? false), light: slot == .light)
    }

    mutating func setRailCrop(_ crop: WallpaperCrop, light: Bool) {
        let focus = crop.focus == WallpaperCrop.middle ? nil : crop.focus
        let zoom = crop.zoom == 1 ? nil : crop.zoom
        if light {
            railFocusLight = focus
            railZoomLight = zoom
            railRotatedLight = crop.rotated ? true : nil
        } else {
            railFocusDark = focus
            railZoomDark = zoom
            railRotatedDark = crop.rotated ? true : nil
        }
    }
}

struct AppearanceSettings: View {
    @Binding var saved: AppState.Persisted
    @ObservedObject var themes: ThemeStore
    var railSize: () -> CGSize = { .zero }
    @Environment(\.colorScheme) private var windowScheme
    @State private var crop: CropSelection?
    @ObservedObject private var results = SettingsResults.shared
    @State private var editing: ColorScheme?
    @State private var browsesThemes = false
    @State private var managesThemes = false
    @State private var pictureError: String?
    @State private var isDropTarget = false

    // Native segments choose their label ink from the tint before blending it with the theme.
    private var selectionTint: Color {
        windowScheme == .dark ? Color(white: 0.34).opacity(0.55) : .white.opacity(0.02)
    }
    private var active: ColorScheme { themes.mode(saved.themeChoice) }
    private var slot: ColorScheme { editing ?? active }
    private var light: Bool { slot == .light }
    private var name: String { light ? "Light" : "Dark" }
    private var theme: PulseTheme { themes.theme(for: slot, in: saved.themeChoice) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mode").font(.headline)
                        if saved.themeChoice.mode == .auto {
                            Text(active == .light ? "Following macOS · Light" : "Following macOS · Dark")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Picker("Appearance mode", selection: $saved.themeChoice.mode) {
                        Text("Auto").tag(AppearanceMode.auto)
                        Text("Light").tag(AppearanceMode.light)
                        Text("Dark").tag(AppearanceMode.dark)
                    }
                    .labelsHidden().pickerStyle(.segmented).tint(selectionTint).frame(width: 184)
                    .accessibilityLabel("Appearance mode")
                }
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Text(name + " look").font(.title2.bold())
                    if slot != active {
                        Text("Saved for " + name.lowercased() + " mode").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(light ? "Edit dark look" : "Edit light look") {
                        let other: ColorScheme = light ? .dark : .light
                        editing = other == active ? nil : other
                    }
                    .buttonStyle(.link)
                }
                LookPreview(theme: theme, slot: slot, saved: saved)
                VStack(spacing: 0) {
                    HStack {
                        Text("Theme")
                        Spacer()
                        Button {
                            browsesThemes = true
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(theme.file.look.accent(.codex)).frame(width: 10, height: 10)
                                Text(theme.file.name)
                                Image(systemName: "chevron.right").font(.caption2)
                            }
                        }
                        .accessibilityLabel("Preview " + name.lowercased() + " themes")
                        .accessibilityValue(theme.file.name)
                        .help("Browse and preview themes")
                    }
                    .padding(.vertical, 10)
                    Divider()
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Finish")
                        if theme.id == "classic-solid" {
                            Text("Classic Solid is opaque. Choose another theme to use a wallpaper.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Picker("Finish for both looks", selection: $saved.glassLevel) {
                                Text("Default").tag(GlassLevel?.none)
                                ForEach(GlassLevel.allCases, id: \.self) { Text($0.name).tag(Optional($0)) }
                            }
                            .pickerStyle(.segmented).tint(selectionTint).labelsHidden().accessibilityLabel("Finish for both looks")
                            .frame(maxWidth: .infinity)
                            Text(saved.glassLevel == nil ? "Both looks use their theme’s finish." : "Applies to light and dark looks.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                    if let glass = saved.glass(for: theme, slot: slot) {
                        Divider()
                        wallpaperRow(glass).padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, 14)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                if let pictureError { Text(pictureError).foregroundStyle(.red) }
                HStack {
                    Button("Manage Themes…") { managesThemes = true }
                    Spacer()
                }
                if let message = results.themeImport { Text(message).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                if !themes.problems.isEmpty || !themes.warnings.isEmpty || themes.notice != nil {
                    Label("Some themes need attention in Manage Themes.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .overlay { if isDropTarget { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false) } }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls { themes.importTheme(url) { results.themeImport = $0 } }
            return !urls.isEmpty
        } isTargeted: { isDropTarget = $0 }
        .sheet(isPresented: $browsesThemes) {
            ThemeBrowser(slot: slot, current: theme.id, saved: saved, themes: themes, apply: selectTheme)
        }
        .sheet(isPresented: $managesThemes) { ThemeManagement(choice: saved.themeChoice, themes: themes) }
        .sheet(item: $crop) { selection in
            WallpaperCropEditor(selection: selection) { saved.setRailCrop($0, light: selection.setting.light) }
        }
        .onChange(of: saved.themeChoice.mode) { editing = nil }
        .onChange(of: active) { editing = nil }
        .onChange(of: slot) { pictureError = nil; browsesThemes = false }
    }

    private func selectTheme(_ id: String) {
        if light { saved.themeChoice.light = id } else { saved.themeChoice.dark = id }
        if ThemeStore.classicIDs.contains(id) { saved.themeChoice.classic = id }
    }

    private func wallpaperRow(_ setting: GlassSetting) -> some View {
        let picture = Wallpaper.picture(setting)
        let bundled = picture?.key.hasPrefix(Bundle.pulseResources.bundlePath + "/") == true
        let source = switch setting.wallpaper {
        case nil: bundled ? "Automatic · Pulse picture" : "Automatic · Desktop picture"
        case "pulse": "Pulse picture"
        default: bundled ? "Pulse picture · Custom file unavailable" : "Custom picture"
        }
        return HStack(spacing: 10) {
            if let image = picture?.image {
                Button {
                    let measured = railSize()
                    let vertical = (saved.dock ?? .right).isVertical
                    let fallback = vertical ? CGSize(width: 44, height: 94) : CGSize(width: 94, height: 44)
                    crop = CropSelection(image: image, setting: setting, theme: theme,
                                         rail: measured.width > 0 && measured.height > 0 ? measured : fallback)
                } label: {
                    VStack(spacing: 3) {
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                            .frame(width: 54, height: 36).clipShape(RoundedRectangle(cornerRadius: 6))
                        Text("Adjust crop…").font(.caption2)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Adjust " + name.lowercased() + " wallpaper crop")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Wallpaper")
                Text(picture == nil ? "Picture unavailable" : source).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Change…") {
                Button("Automatic") { setWallpaper(nil, light: setting.light) }
                Button("Pulse Picture") { setWallpaper("pulse", light: setting.light) }
                Divider()
                Button("Choose Picture…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image]
                    NSApp.activate()
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    do { setWallpaper(try Wallpaper.copyIn(url, light: setting.light), light: setting.light) }
                    catch { pictureError = error.localizedDescription }
                }
            }
            .fixedSize().accessibilityLabel("Change " + name.lowercased() + " wallpaper").accessibilityValue(source)
        }
    }

    private func setWallpaper(_ value: String?, light: Bool) {
        if light { saved.wallpaperLight = value } else { saved.wallpaperDark = value }
        pictureError = nil
    }
}

private struct ThemeBrowser: View {
    let slot: ColorScheme
    let current: String
    let saved: AppState.Persisted
    @ObservedObject var themes: ThemeStore
    let apply: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection = ""

    var body: some View {
        let choices = themes.choices(for: slot)
        let candidate = choices.first { $0.id == selection }
        VStack(alignment: .leading, spacing: 14) {
            Text(slot == .light ? "Preview light themes" : "Preview dark themes").font(.title2.bold())
            HStack(spacing: 12) {
                ScrollViewReader { reader in
                    ScrollView {
                        SettingsChoiceList(items: choices, selection: $selection, title: { item in
                            item.file.name + (item.id == current ? ", current theme" : "")
                                + (themes.problems[item.id] != nil || themes.warnings[item.id] != nil ? ", theme warning" : "")
                        }) { item in
                            HStack(spacing: 6) {
                                Circle().fill(item.file.look.accent(.codex)).frame(width: 9, height: 9)
                                Text(item.file.name)
                                if item.id == current {
                                    Image(systemName: "checkmark").font(.caption)
                                }
                                if themes.problems[item.id] != nil || themes.warnings[item.id] != nil {
                                    Image(systemName: "exclamationmark.triangle")
                                }
                            }
                        }
                        .padding(.vertical, 4).accessibilityLabel("Themes")
                    }
                    .onChange(of: selection) { _, id in reader.scrollTo(id) }
                }
                .frame(width: 174)
                if let candidate {
                    LookPreview(theme: candidate, slot: slot, saved: saved)
                } else {
                    Text("Select a theme to preview").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    if let candidate { apply(candidate.id); dismiss() }
                }
                .keyboardShortcut(.defaultAction).disabled(candidate == nil)
            }
        }
        .padding(20).frame(width: 630, height: 320)
        .onAppear { selection = current }
    }
}

private struct LookPreview: View {
    let theme: PulseTheme
    let slot: ColorScheme
    let saved: AppState.Persisted
    private static let sample = AccountSnapshot(id: .codex, displayName: "Codex", planLabel: "Sample",
        health: .ok, windows: [UsageWindow(id: "weekly", label: "Weekly", percentUsed: 7, resetsAt: Calendar.current.startOfDay(for: .now).addingTimeInterval(2 * 86400))],
        fetchedAt: .now, source: .mock)

    var body: some View {
        let vertical = (saved.dock ?? .right).isVertical
        let panels = vertical ? AnyLayout(HStackLayout(spacing: 3)) : AnyLayout(VStackLayout(spacing: 3))
        let rings = vertical ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        return panels {
            rings {
                RingView(account: .codex, percent: 7, size: 28, showPercent: false)
                RingView(account: .claude, percent: 62, size: 28, showPercent: false)
            }
            .padding(8).pulseSurface(in: Capsule())
            UsageCard(snapshot: Self.sample, windows: Self.sample.windows, tailEdge: vertical ? .leading : .top,
                      tailAt: vertical ? 30 : nil)
        }
        .modifier(PanelLook(theme: theme, slot: slot, saved: saved))
        .environment(\.showsRemaining, saved.showRemaining ?? false)
        .environment(\.colorScheme, theme.file.scheme)
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, minHeight: 132)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rail and usage card preview")
        .accessibilityValue(theme.file.name + ", " + (saved.glass(for: theme, slot: slot)?.level.name ?? "theme default"))
    }
}

private struct ThemeManagement: View {
    let choice: ThemeChoice
    @ObservedObject var themes: ThemeStore
    @ObservedObject private var results = SettingsResults.shared
    @Environment(\.dismiss) private var dismiss
    @State private var agentName = ""
    @State private var promptCopied = false
    @State private var justCopied = false   // the button's "✓ Copied", for CopyPromptButton.shown
    @State private var copies = 0           // each copy restarts that time

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Manage Themes").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("Import Theme…", action: importPanel)
                        Menu("Export Theme…") {
                            ForEach([ColorScheme.light, .dark], id: \.self) { slot in
                                let theme = themes.theme(for: slot, in: choice)
                                Button("\(slot == .light ? "Light" : "Dark") · \(theme.file.name)…") { export(theme) }
                            }
                        }
                        .fixedSize()
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([themes.folder]) }
                    }
                    Text("Import a theme file or drop it here.").foregroundStyle(.secondary)
                    if let message = results.themeImport { Text(message) }
                    let ids = themes.problems.keys.sorted()
                    ForEach(ids.prefix(5), id: \.self) { id in
                        let first = themes.problems[id]?.split(separator: "\n").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "- ")) } ?? ""
                        Text("⚠︎ \(id).json can't be used: \(first) (more in \(id).error)").foregroundStyle(alert)
                            .help(themes.problems[id] ?? "")
                    }
                    if ids.count > 5 { Text("⚠︎ and \(ids.count - 5) more theme files that can't be used").foregroundStyle(alert) }
                    let hard = themes.warnings.keys.sorted()
                    ForEach(hard.prefix(max(0, 5 - ids.count)), id: \.self) { id in
                        let first = themes.warnings[id]?.split(separator: "\n").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "- ")) } ?? ""
                        Text("⚠︎ \(id).json is hard to read in places: \(first)").foregroundStyle(alert)
                            .help(themes.warnings[id] ?? "")
                    }
                    if hard.count > max(0, 5 - ids.count) { Text("⚠︎ and \(hard.count - max(0, 5 - ids.count)) more themes that are hard to read in places").foregroundStyle(alert) }
                    if let notice = themes.notice { Text("⚠︎ \(notice)").foregroundStyle(alert) }
                    Link("Browse the theme collection", destination: URL(string: "https://github.com/tommyent/pulse/tree/main/themes")!)
                    Divider().padding(.vertical, 4)
                    Text("Create a theme").font(.headline)
                    Text("The prompt directs your agent to the format guide in the Themes folder.")
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("Theme name", text: $agentName, prompt: Text("Theme name"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)   // a grouped form's plain field reads as a label
                            .multilineTextAlignment(.leading)
                            .frame(width: 140)
                            .accessibilityLabel("Name for the agent's theme")
                            .onChange(of: agentName) { promptCopied = false }
                        CopyPromptButton(copied: justCopied) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ThemeStore.agentPrompt(folder: themes.folder, name: agentName), forType: .string)
                            promptCopied = true
                            justCopied = true
                            copies += 1
                        }
                        .help("Copies a line for a coding agent: read the guide in the Themes folder and save a theme there")
                        .task(id: copies) {
                            guard copies > 0 else { return }
                            do {
                                try await Task.sleep(for: CopyPromptButton.shown)
                                justCopied = false
                            } catch {}   // a newer copy started its own time
                        }
                    }
                    if promptCopied { Text("Paste the prompt into your coding agent.").font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .frame(width: 500, height: 360)
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls { themes.importTheme(url) { results.themeImport = $0 } }
            return !urls.isEmpty
        }
        .onExitCommand { dismiss() }
    }

    private var alert: Color { themes.skin(choice).alert }

    private func importPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.message = "Choose theme files to copy into Pulse's Themes folder"
        panel.begin { response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { for url in panel.urls { themes.importTheme(url) { results.themeImport = $0 } } }
        }
    }

    /// The theme as one self-contained file, wherever the person puts it.
    private func export(_ theme: PulseTheme) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(theme.id).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let data = ThemeStore.file(theme.file), name = theme.file.name
            DispatchQueue.global(qos: .userInitiated).async {
                let result: String
                do { try data.write(to: url, options: .atomic); result = "Exported \(name) to \(url.lastPathComponent)." } catch {
                    result = "\(name) wasn't exported: \(error.localizedDescription)"
                }
                DispatchQueue.main.async { results.themeImport = result }
            }
        }
    }
}
