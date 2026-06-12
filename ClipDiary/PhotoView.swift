import SwiftUI

/// Editor for a photo clip: crop by dragging the yellow corners, choose how
/// long the photo is shown, change its date, tag it, or delete it.
struct PhotoEditor: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State var clip: Clip
    @State private var image: NSImage?
    @State private var editedDate: Date
    @State private var aspectLock: AspectLock = .free

    /// Snapshot as the editor opened, for Revert.
    private let original: Clip

    private var hasChanges: Bool {
        clip != original || editedDate.dayKey != original.date
    }

    /// Optional crop aspect lock matching the export formats.
    private enum AspectLock: String, CaseIterable, Identifiable {
        case free = "Free"
        case landscape = "16:9"
        case portrait = "9:16"
        var id: String { rawValue }
        /// Desired pixel width/height ratio of the crop, nil = unconstrained.
        var ratio: Double? {
            switch self {
            case .free: nil
            case .landscape: 16.0 / 9.0
            case .portrait: 9.0 / 16.0
            }
        }
    }

    init(clip: Clip) {
        original = clip
        _clip = State(initialValue: clip)
        _editedDate = State(initialValue: clip.date)
    }

    private var cropBinding: Binding<CropRect> {
        Binding(
            get: { clip.crop ?? .full },
            set: { clip.crop = $0.isFull ? nil : $0 }
        )
    }

    private var durationBinding: Binding<Double> {
        Binding(
            get: { clip.durationSeconds },
            set: { newValue in
                clip.durationSeconds = newValue
                clip.inSeconds = 0
                clip.outSeconds = newValue
            }
        )
    }

    var body: some View {
        VStack(spacing: 14) {
            if let image {
                PhotoCropView(image: image, crop: cropBinding, aspect: aspectLock.ratio)
                    .frame(minHeight: 300)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 300)
            }

            HStack {
                Stepper(value: durationBinding, in: 0.5...30, step: 0.5) {
                    Text(String(format: "Show for %.1f s", clip.durationSeconds))
                        .monospacedDigit()
                }
                Spacer()
                Picker("", selection: $aspectLock) {
                    ForEach(AspectLock.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Lock the crop to an export aspect ratio (16:9 landscape, 9:16 portrait)")
                Button("Reset Crop") {
                    clip.crop = nil
                    aspectLock = .free
                }
                .disabled(clip.crop == nil)
            }
            .font(.callout)

            TagRow(tags: $clip.tags)

            Divider()

            HStack {
                DatePicker("Day", selection: $editedDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
                Toggle("Date stamp", isOn: $clip.showsDateOverlay)
                    .toggleStyle(.checkbox)
                    .help("Show this photo's date in the bottom-left corner of the month video. Turn off for cover photos.")
                Spacer()
                Button {
                    clip = original
                    editedDate = original.date
                    aspectLock = .free
                } label: {
                    Label("Revert", systemImage: "arrow.uturn.backward")
                }
                .disabled(!hasChanges)
                .help("Discard this photo's unsaved changes")
                Button(role: .destructive) {
                    store.delete(clip)
                    dismiss()
                } label: {
                    Label("Delete Photo", systemImage: "trash")
                }
            }
        }
        .onAppear { load() }
        // Auto-save so switching clips or closing the sheet keeps edits.
        // No-op if the clip was just deleted.
        .onDisappear { saveEdits() }
    }

    private func saveEdits() {
        var updated = clip
        updated.date = editedDate.dayKey
        store.update(updated)
    }

    private func load() {
        let url = store.fileURL(for: clip)
        Task.detached {
            let cg = loadOrientedCGImage(from: url, maxPixel: 2048)
            await MainActor.run {
                if let cg { image = NSImage(cgImage: cg, size: .zero) }
            }
        }
    }
}

/// Aspect-fit photo with a crop rectangle: drag the corners to resize,
/// drag the inside to move. Crop is stored in unit image coordinates.
struct PhotoCropView: View {
    let image: NSImage
    @Binding var crop: CropRect
    /// Desired pixel width/height ratio of the crop, nil = unconstrained.
    var aspect: Double?

    private let handleRadius: CGFloat = 8
    /// Minimum crop width/height as a fraction of the image.
    private let minCrop = 0.05

    /// `aspect` converted to unit-coordinate width/height (crop coords are
    /// fractions of the image, so the image's own ratio factors in).
    private var unitRatio: Double? {
        guard let aspect, image.size.width > 0, image.size.height > 0 else { return nil }
        return aspect * Double(image.size.height / image.size.width)
    }

    /// Crop at the start of an interior (move) drag.
    @State private var moveAnchor: CropRect?

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
            case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let fit = fittedRect(in: geo.size)
            let rect = viewRect(in: fit)

            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: fit.width, height: fit.height)
                    .offset(x: fit.minX, y: fit.minY)

                // Dim the cropped-away part of the photo.
                Path { path in
                    path.addRect(fit)
                    path.addRect(rect)
                }
                .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))

                Rectangle()
                    .stroke(Color.yellow, lineWidth: 2)
                    .contentShape(Rectangle())
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .gesture(moveGesture(fit: fit))

                ForEach(Corner.allCases, id: \.self) { corner in
                    let p = corner.point(in: rect)
                    Circle()
                        .fill(Color.yellow)
                        .frame(width: handleRadius * 2, height: handleRadius * 2)
                        .contentShape(Circle().inset(by: -8))
                        .offset(x: p.x - handleRadius, y: p.y - handleRadius)
                        .gesture(cornerGesture(corner, fit: fit))
                }
            }
            .coordinateSpace(name: "crop")
        }
        .onChange(of: aspect) { _, _ in snapToAspect() }
    }

    /// Re-fits the current crop to the locked ratio, keeping its center.
    private func snapToAspect() {
        guard let ratio = unitRatio else { return }
        var c = crop
        let centerX = c.x + c.width / 2
        let centerY = c.y + c.height / 2
        var w = c.width
        var h = w / ratio
        if h > 1 { h = 1; w = h * ratio }
        if w > 1 { w = 1; h = w / ratio }
        c.width = w
        c.height = h
        c.x = min(max(0, centerX - w / 2), 1 - w)
        c.y = min(max(0, centerY - h / 2), 1 - h)
        crop = c
    }

    // MARK: - Gestures

    private func cornerGesture(_ corner: Corner, fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("crop"))
            .onChanged { value in
                guard fit.width > 0, fit.height > 0 else { return }
                let ux = Double((value.location.x - fit.minX) / fit.width)
                let uy = Double((value.location.y - fit.minY) / fit.height)

                var c = crop
                let right = c.x + c.width
                let bottom = c.y + c.height

                if let ratio = unitRatio {
                    // Ratio-locked: the opposite corner stays fixed, width
                    // follows the pointer, height is derived.
                    let isLeft = corner == .topLeft || corner == .bottomLeft
                    let isTop = corner == .topLeft || corner == .topRight
                    let anchorX = isLeft ? right : c.x
                    let anchorY = isTop ? bottom : c.y
                    let maxW = isLeft ? anchorX : 1 - anchorX
                    let maxH = isTop ? anchorY : 1 - anchorY
                    var w = min(max(minCrop, isLeft ? anchorX - ux : ux - anchorX), maxW)
                    var h = w / ratio
                    if h > maxH {
                        h = maxH
                        w = h * ratio
                    }
                    c.x = isLeft ? anchorX - w : anchorX
                    c.y = isTop ? anchorY - h : anchorY
                    c.width = w
                    c.height = h
                } else {
                    switch corner {
                    case .topLeft, .bottomLeft:
                        let newX = min(max(0, ux), right - minCrop)
                        c.width = right - newX
                        c.x = newX
                    case .topRight, .bottomRight:
                        c.width = min(max(minCrop, ux - c.x), 1 - c.x)
                    }
                    switch corner {
                    case .topLeft, .topRight:
                        let newY = min(max(0, uy), bottom - minCrop)
                        c.height = bottom - newY
                        c.y = newY
                    case .bottomLeft, .bottomRight:
                        c.height = min(max(minCrop, uy - c.y), 1 - c.y)
                    }
                }
                crop = c
            }
    }

    private func moveGesture(fit: CGRect) -> some Gesture {
        DragGesture(coordinateSpace: .named("crop"))
            .onChanged { value in
                guard fit.width > 0, fit.height > 0 else { return }
                if moveAnchor == nil { moveAnchor = crop }
                guard let anchor = moveAnchor else { return }
                var c = anchor
                c.x = min(max(0, anchor.x + Double(value.translation.width / fit.width)),
                          1 - c.width)
                c.y = min(max(0, anchor.y + Double(value.translation.height / fit.height)),
                          1 - c.height)
                crop = c
            }
            .onEnded { _ in moveAnchor = nil }
    }

    // MARK: - Geometry

    private func fittedRect(in size: CGSize) -> CGRect {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func viewRect(in fit: CGRect) -> CGRect {
        CGRect(
            x: fit.minX + crop.x * fit.width,
            y: fit.minY + crop.y * fit.height,
            width: crop.width * fit.width,
            height: crop.height * fit.height
        )
    }
}
