import SwiftUI

struct CropSelection: Identifiable {
    let id = UUID()
    let image: CGImage
    let setting: GlassSetting
    let theme: PulseTheme
    let rail: CGSize
}

struct WallpaperCropEditor: View {
    let selection: CropSelection
    let save: (WallpaperCrop) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WallpaperCrop
    @State private var grabOffset: CGSize?
    @FocusState private var editingPicture: Bool

    init(selection: CropSelection, save: @escaping (WallpaperCrop) -> Void) {
        self.selection = selection
        self.save = save
        _draft = State(initialValue: selection.setting.wallpaperCrop)
    }

    private var source: CGSize { CGSize(width: selection.image.width, height: selection.image.height) }
    private var crop: CGRect { draft.rect(image: source, panel: selection.rail) }

    private var zoomLabel: String { Double(draft.zoom).formatted(.percent.precision(.fractionLength(0))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Adjust wallpaper crop").font(.title2.bold())
            Text("Drag to choose a detail for the rail, cards, and menu. The outline shows how it fits the rail.")
                .foregroundStyle(.secondary)
            HStack(spacing: 18) {
                pictureControl
                VStack(spacing: 8) {
                    railPreview
                    Text("Rail preview").font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: selection.rail.width > selection.rail.height ? 202 : 110)
            }
            .frame(height: 260)
            HStack {
                Text("Zoom")
                Slider(value: Binding<Double>(get: { draft.zoom * 100 }, set: { percent in
                    let center = CGPoint(x: crop.midX / source.width, y: crop.midY / source.height)
                    draft = WallpaperCrop(focus: center, zoom: percent.rounded() / 100, rotated: draft.rotated)
                }), in: (WallpaperCrop.zoomRange.lowerBound * 100)...(WallpaperCrop.zoomRange.upperBound * 100))
                .accessibilityLabel("Wallpaper zoom, percent")
                Text(zoomLabel).monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
            Toggle("Rotate crop 90°", isOn: $draft.rotated)
                .toggleStyle(.checkbox)
                .help("Turn the selected part of the wallpaper a quarter turn counterclockwise.")
            Divider()
            HStack {
                Button("Center") { draft.focus = WallpaperCrop.middle; editingPicture = true }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") { save(draft); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear { editingPicture = true }
    }

    private var pictureControl: some View {
        Image(decorative: selection.image, scale: 1)
            .resizable().aspectRatio(contentMode: .fit)
            .overlay { GeometryReader { proxy in cropControl(size: proxy.size) } }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .focusable().focused($editingPicture)
            .onMoveCommand { direction in
                switch direction {
                case .left: nudge(-1, 0)
                case .right: nudge(1, 0)
                case .up: nudge(0, -1)
                case .down: nudge(0, 1)
                default: break
                }
            }
            .accessibilityRepresentation { accessiblePosition }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var accessiblePosition: some View {
        if crop.width < source.width { positionSlider(horizontal: true) }
        if crop.height < source.height { positionSlider(horizontal: false) }
        if crop.size == source { Text("The whole picture fits the rail.") }
    }

    private func positionSlider(horizontal: Bool) -> some View {
        let fraction = horizontal ? crop.width / source.width : crop.height / source.height
        let position = Binding<Double>(
            get: { horizontal ? crop.midX / source.width : crop.midY / source.height },
            set: { if horizontal { draft.focus.x = $0 } else { draft.focus.y = $0 } }
        )
        return Slider(value: position, in: (fraction / 2)...(1 - fraction / 2)) {
            Text(horizontal ? "Horizontal rail crop position" : "Vertical rail crop position")
        }
        .accessibilityValue("\(Int((position.wrappedValue * 100).rounded())) percent")
    }

    private func cropControl(size: CGSize) -> some View {
        let scale = size.width / source.width
        let rect = crop.applying(CGAffineTransform(scaleX: scale, y: scale))
        let outline = Capsule().path(in: rect)
        return ZStack {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addPath(outline)
            }
            .fill(.black.opacity(0.42), style: FillStyle(eoFill: true))
            outline.stroke(.black.opacity(0.7), lineWidth: 4)
            outline.stroke(.white, lineWidth: 2)
        }
        .contentShape(Rectangle())
        .pointerStyle(grabOffset == nil ? .grabIdle : .grabActive)
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            editingPicture = true
            if grabOffset == nil {
                grabOffset = outline.contains(drag.startLocation)
                    ? CGSize(width: rect.midX - drag.startLocation.x, height: rect.midY - drag.startLocation.y) : .zero
            }
            move(to: drag.location, offset: grabOffset ?? .zero, in: size)
        }.onEnded { drag in
            if hypot(drag.translation.width, drag.translation.height) < 2 {
                move(to: drag.location, offset: .zero, in: size)
            }
            grabOffset = nil
        })
    }

    private func move(to point: CGPoint, offset: CGSize, in size: CGSize) {
        draft.focus = CGPoint(x: min(1, max(0, (point.x + offset.width) / size.width)),
                        y: min(1, max(0, (point.y + offset.height) / size.height)))
    }

    private func nudge(_ dx: CGFloat, _ dy: CGFloat) {
        if dx != 0, crop.width < source.width {
            draft.focus.x = min(1, max(0, crop.midX / source.width + dx * 0.01))
        }
        if dy != 0, crop.height < source.height {
            draft.focus.y = min(1, max(0, crop.midY / source.height + dy * 0.01))
        }
    }

    private var railPreview: some View {
        let rail = selection.rail
        let availableWidth: CGFloat = rail.width > rail.height ? 200 : 108
        let scale = min(1.5, availableWidth / rail.width, 206 / rail.height)
        var skin = selection.theme.file.look
        skin.groove = nil
        return RingView(account: .codex, percent: 35, size: min(28, rail.width, rail.height), showPercent: false)
            .frame(width: rail.width, height: rail.height)
            .modifier(LevelPanel(setting: selection.setting, shape: Capsule(), crop: draft))
            .environment(\.pulseSkin, skin)
            .scaleEffect(scale)
            .frame(width: rail.width * scale, height: rail.height * scale)
            .accessibilityHidden(true)
    }
}
