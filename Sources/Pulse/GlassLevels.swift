import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

private let log = Logger(subsystem: "io.github.tommyent.pulse", category: "glass")

// Prototype (the owner, 2026-11-19): glass by levels. "Let the background do the work." Off, every theme draws as its
// file says. At a level, every theme but Classic Solid keeps only its colours: each panel (rail, card, popover,
// break screen) is a wallpaper under glass, and its words turn light or dark by how bright the picture is behind it.

/// Settings › Appearance › Glass, from the clearest to the most blurred.
enum GlassLevel: String, Codable, CaseIterable {
    case liquid, glass, frosted
    var name: String { rawValue.capitalized }
    // even steps (the owner, 2026-11-19): clear glass over the sharp picture, over a lightly blurred one, then .regular
    // glass over a heavily blurred one (.regular frosts on its own, so it's kept for the last step)
    var material: Glass { self == .frosted ? .regular : .clear }
    var blur: CGFloat { switch self { case .liquid: 0; case .glass: 8; case .frosted: 30 } }   // the picture's own blur, in points
}

/// What the panels draw at a level: nil, the person's theme as its file says.
struct GlassSetting: Equatable {
    var level: GlassLevel
    var wallpaper: String?   // the mode's: nil, the desktop picture or Pulse's; "pulse"; or a file in `Wallpaper.folder`
    var light: Bool          // which of Pulse's own pictures fits the mode
}

private struct GlassSettingKey: EnvironmentKey { static let defaultValue: GlassSetting? = nil }
extension EnvironmentValues {
    var glassSetting: GlassSetting? {
        get { self[GlassSettingKey.self] }
        set { self[GlassSettingKey.self] = newValue }
    }
}

/// The pictures behind the glass. Pulse's own two ship with it, so there's always one and never a permission prompt:
/// out of the box (and whenever a picked picture can't be read) it's the Mac's desktop picture if that is one of Apple's,
/// else Pulse's. A picked picture is copied into Pulse's folder, so it stays when the original moves or goes.
@MainActor enum Wallpaper {
    static let maxBytes = 32 * 1024 * 1024
    static var folder: URL { ThemeStore.shared.folder.deletingLastPathComponent().appending(path: "Wallpapers") }
    private static var cache: [String: CGImage] = [:]

    /// The picture for a setting, and the key it's cached under.
    static func picture(_ s: GlassSetting) -> (image: CGImage, key: String)? {
        if let name = s.wallpaper, name != "pulse", isFileName(name), let p = load(folder.appending(path: name)) { return p }
        if s.wallpaper == nil, let url = NSScreen.main.flatMap({ NSWorkspace.shared.desktopImageURL(for: $0) }), isApples(url),
           let p = load(url) { return p }
        return Bundle.pulseResources.url(forResource: "Resources/wallpapers/default-\(s.light ? "light" : "dark")", withExtension: "jpg").flatMap(load)
    }

    /// Apple's own pictures can be read without asking; one in Downloads, Documents or Desktop would bring up a prompt.
    /// Inferred from where macOS keeps its pictures, not tested against every location.
    static func isApples(_ url: URL) -> Bool { url.path.hasPrefix("/System/") || url.path.hasPrefix("/Library/") }

    static func isFileName(_ name: String) -> Bool { name.count <= 80 && !name.hasPrefix(".") && !name.contains("/") && !name.contains(":") }

    private static func load(_ url: URL) -> (image: CGImage, key: String)? {
        if let image = cache[url.path] { return (image, url.path) }
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxBytes,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: 1600] as CFDictionary)
        else { return nil }
        cache[url.path] = image
        return (image, url.path)
    }

    /// Choose Picture…'s work once a picture is picked: copied in, and the mode's wallpaper set to the copy.
    static func choose(_ url: URL, light: Bool, in state: AppState) throws {
        let name = try copyIn(url, light: light)
        if light { state.persisted.wallpaperLight = name } else { state.persisted.wallpaperDark = name }
    }

    /// Test-only, on test/glass-play and never in a release branch; off unless set:
    /// `defaults write io.github.tommyent.pulse testWallpaper "dark:/path/to/picture"` (or "light:…") runs `choose` at the
    /// next launch, as the open panel would, then clears itself. Agents can't drive the system's open panel on the test Mac.
    static func takeTestPick(_ state: AppState) {
        guard let spec = UserDefaults.standard.string(forKey: "testWallpaper") else { return }
        UserDefaults.standard.removeObject(forKey: "testWallpaper")
        let light = spec.hasPrefix("light:"), path = String(spec.drop(while: { $0 != ":" }).dropFirst())
        do { try choose(URL(fileURLWithPath: path), light: light, in: state); log.info("test pick: \(spec, privacy: .public) copied") }
        catch { log.error("test pick \(spec, privacy: .public) failed: \(error.localizedDescription, privacy: .public)") }
    }

    /// Copies a picked picture into Pulse's folder under a new name (so nothing cached shows the old one), removes the
    /// mode's previous copy, and returns the new file's name.
    static func copyIn(_ url: URL, light: Bool) throws -> String {
        let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size <= maxBytes, let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "That isn't a picture Pulse can read (or it's over 32 MB)."])
        }
        let fm = FileManager.default, prefix = light ? "light-" : "dark-"
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = prefix + UUID().uuidString.prefix(8).lowercased() + "." + url.pathExtension.lowercased().prefix(5)
        try fm.copyItem(at: url, to: folder.appending(path: name))
        for old in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where old.hasPrefix(prefix) && old != name {
            try? fm.removeItem(at: folder.appending(path: old))   // Pulse's own earlier copy
        }
        return name
    }
}

/// How the words read on the part of a picture a panel shows: light words if the picture is dark there, else dark ones,
/// and a black (or white) wash over the picture only if they'd still fall short of 4.5:1.
struct WallpaperReading: Equatable {
    var light: Bool
    var wash: Double      // the wash's opacity, 0 = none
    var contrast: Double  // the words against the picture's brightest tenth (darkest, for dark words), wash included

    static let target = 4.5
    static let darkInk: SkinColor = "#15171C"

    /// `size`: the panel, in points; the picture fills it as `scaledToFill` does. Sampled about every 6 points, or every
    /// `blur` points when the picture is blurred, so a sharp picture's detail counts and a blurred one's doesn't.
    static func read(_ image: CGImage, size: CGSize, blur: CGFloat) -> WallpaperReading? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        let W = CGFloat(image.width), H = CGFloat(image.height), scale = max(size.width / W, size.height / H)
        let crop = CGRect(x: (W - size.width / scale) / 2, y: (H - size.height / scale) / 2, width: size.width / scale, height: size.height / scale)
        let step = max(6, blur), cols = max(2, Int(size.width / step)), rows = max(2, Int(size.height / step))
        guard let part = image.cropping(to: crop.integral),
              let ctx = CGContext(data: nil, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: cols * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(part, in: CGRect(x: 0, y: 0, width: cols, height: rows))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: cols * rows * 4)
        var lums = (0 ..< cols * rows).map { i in
            0.2126 * lin(Double(px[i * 4]) / 255) + 0.7152 * lin(Double(px[i * 4 + 1]) / 255) + 0.0722 * lin(Double(px[i * 4 + 2]) / 255)
        }
        lums.sort()
        return choose(dark: lums[lums.count / 10], bright: lums[lums.count * 9 / 10])
    }

    /// The words and wash for a picture whose darkest and brightest tenths have these luminances.
    static func choose(dark: Double, bright: Double) -> WallpaperReading {
        let inkL = darkInk.luminance
        func ratio(_ light: Bool, _ wash: Double) -> Double {
            light ? 1.05 / (lin(srgb(bright) * (1 - wash)) + 0.05) : (lin(srgb(dark) * (1 - wash) + wash) + 0.05) / (inkL + 0.05)
        }
        let light = ratio(true, 0) >= ratio(false, 0)
        var wash = 0.0
        while ratio(light, wash) < target, wash < 0.6 { wash += 0.02 }
        return WallpaperReading(light: light, wash: wash, contrast: ratio(light, wash))
    }

    private static func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    private static func srgb(_ l: Double) -> Double { l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055 }
}

@MainActor enum WallpaperReader {
    private static var cache: [String: WallpaperReading] = [:]
    static func read(_ picture: (image: CGImage, key: String), size: CGSize, level: GlassLevel) -> WallpaperReading? {
        let key = "\(picture.key)|\(Int(size.width))x\(Int(size.height))|\(level.rawValue)"
        if let hit = cache[key] { return hit }
        let r = WallpaperReading.read(picture.image, size: size, blur: level.blur)
        if let r {
            cache[key] = r
            log.info("reading \((picture.key as NSString).lastPathComponent, privacy: .public) \(Int(size.width))x\(Int(size.height)) \(level.rawValue, privacy: .public): \(r.light ? "light" : "dark", privacy: .public) words, wash \(r.wash, format: .fixed(precision: 2)), \(r.contrast, format: .fixed(precision: 1)):1")
        }
        return r
    }
}

extension PulseSkin {
    /// The theme's colours with the words and ring tracks a wallpaper reading asks for.
    func reading(_ r: WallpaperReading) -> PulseSkin {
        var s = self
        let ink: SkinColor = r.light ? "#FFFFFF" : WallpaperReading.darkInk
        s.ink = Ink(primary: ink, secondary: ink, alert: r.light ? "#FFB4AB" : "#B3261E")
        s.track = r.light ? "srgb:1,1,1,0.28" : "srgb:0,0,0,0.16"
        return s
    }
}

/// The wallpaper under a level's glass, filling `shape`, with the reading's wash over the picture.
struct WallpaperLayer<S: Shape>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let level: GlassLevel
    let picture: CGImage?
    let reading: WallpaperReading?
    let shape: S

    var body: some View {
        let wash = reading.map { ($0.light ? Color.black : .white).opacity($0.wash) } ?? .clear
        Group {
            if level == .liquid, picture != nil, !reduceTransparency {
                // Native clear glass frosts its entire backdrop when Pulse resigns active.
                shape.fill(wash).overlay {
                    Color.clear.glassEffect(.clear, in: shape)
                        .mask { shape.stroke(lineWidth: 8) }
                }
            } else {
                Color.clear.background(wash, in: shape)
                    .glassEffect(level.material, in: shape)
            }
        }
        .background {
            if let picture {
                Color.clear
                    .overlay { Image(decorative: picture, scale: 1).resizable().scaledToFill().blur(radius: level.blur, opaque: true) }
                    .clipShape(shape)
            }
        }
        .environment(\.appearsActive, true)
    }
}

/// A panel at a level: its content on the wallpaper, in the words its own part of the picture asks for.
struct LevelPanel<S: Shape>: ViewModifier {
    @Environment(\.pulseSkin) private var skin
    let setting: GlassSetting
    let shape: S
    @State private var size = CGSize.zero

    func body(content: Content) -> some View {
        let picture = Wallpaper.picture(setting)
        let reading = picture.flatMap { WallpaperReader.read($0, size: size, level: setting.level) }
        content
            .environment(\.pulseSkin, reading.map(skin.reading) ?? skin)
            .environment(\.colorScheme, reading?.light == false ? .light : .dark)
            .background { WallpaperLayer(level: setting.level, picture: picture?.image, reading: reading, shape: shape) }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
    }
}
