import SwiftUI

/// Editor for a photo clip: crop by dragging the yellow corners, choose how
/// long the photo is shown, change its date, tag it, or delete it. Like
/// `TrimEditor` it has a review mode: with `onAdd` set, the clip is a draft
/// for the source photo at `sourceURL` and "Add to Clips" hands it back.
struct PhotoEditor: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State var clip: Clip
    @State private var image: NSImage?
    @State private var editedDate: Date
    @State private var aspectLock: AspectLock = .free
    @State private var showTransition = false
    /// Width of the review metadata pane; shared with the video editor and
    /// remembered across items and launches.
    @AppStorage("reviewPaneWidth") private var paneWidth: Double = 280

    /// Snapshot as the editor opened, for Revert.
    private let original: Clip
    private let sourceURL: URL?
    private let onAdd: ((Clip) -> Void)?
    /// Reports the working copy (date applied) on every change, so the day
    /// editor can persist it before previewing. Library mode only.
    private let onLiveEdit: ((Clip) -> Void)?
    /// Called when the user deletes the clip. When set, the host owns the
    /// deletion (and decides what to show next); otherwise the editor deletes
    /// from the store and dismisses itself. Library mode only.
    private let onDelete: (() -> Void)?
    /// Day/file context shown atop the review pane. Review mode only.
    private let reviewInfo: ReviewItemInfo?
    /// Optional control shown above the media (the Live Photo still/motion
    /// picker), kept in the media column so it doesn't push the pane down.
    private let mediaAccessory: AnyView?

    private var isReview: Bool { onAdd != nil }

    /// The working copy with the picked date applied — what would be saved.
    private var editedClip: Clip {
        var updated = clip
        updated.date = editedDate.dayKey
        return updated
    }

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

    init(clip: Clip, sourceURL: URL? = nil, onAdd: ((Clip) -> Void)? = nil,
         onLiveEdit: ((Clip) -> Void)? = nil, onDelete: (() -> Void)? = nil,
         reviewInfo: ReviewItemInfo? = nil, mediaAccessory: AnyView? = nil) {
        original = clip
        self.sourceURL = sourceURL
        self.onAdd = onAdd
        self.onLiveEdit = onLiveEdit
        self.onDelete = onDelete
        self.reviewInfo = reviewInfo
        self.mediaAccessory = mediaAccessory
        _clip = State(initialValue: clip)
        _editedDate = State(initialValue: clip.date)
    }

    private var cropBinding: Binding<CropRect> {
        Binding(
            get: { clip.crop ?? .full },
            set: { clip.crop = $0.isFull ? nil : $0 }
        )
    }

    /// Allowed photo display durations and the +/- step.
    private let durationRange = 0.5...30.0
    private let durationStep = 0.5

    private var durationBinding: Binding<Double> {
        Binding(
            get: { clip.durationSeconds },
            set: { newValue in
                let clamped = min(max(newValue, durationRange.lowerBound),
                                  durationRange.upperBound)
                clip.durationSeconds = clamped
                clip.inSeconds = 0
                clip.outSeconds = clamped
            }
        )
    }

    private func adjustDuration(by delta: Double) {
        durationBinding.wrappedValue = clip.durationSeconds + delta
    }

    var body: some View {
        editorBody
        .onAppear { load(); onLiveEdit?(editedClip) }
        // Auto-save so switching clips or closing the sheet keeps edits.
        // No-op if the clip was just deleted. Review drafts aren't saved.
        .onDisappear { if !isReview { saveEdits() } }
        .onChange(of: clip) { _, _ in onLiveEdit?(editedClip) }
        .onChange(of: editedDate) { _, _ in onLiveEdit?(editedClip) }
        .sheet(isPresented: $showTransition) {
            TransitionEditorSheet(transition: $clip.transition, maxSeconds: clip.trimmedDuration)
        }
    }

    // MARK: - Layouts

    /// Two-column layout used in both modes: the photo and crop controls take the
    /// whole left side so the image is as big as possible; tags/caption/
    /// transition/day and the add (review) or delete (library) action live in a
    /// resizable pane on the right.
    private var editorBody: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 14) {
                mediaAccessory
                photoView
                cropControls
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            ResizablePaneDivider(width: $paneWidth)
            sidePane
                .frame(width: paneWidth)
        }
    }

    /// Right-hand metadata + actions pane.
    private var sidePane: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let reviewInfo {
                ReviewItemHeader(info: reviewInfo)
                Divider()
            }
            TagRow(tags: $clip.tags)
            captionField
            TransitionRow(transition: clip.transition) { showTransition = true }
            Divider()
            DayPickerField(selection: $editedDate)
            dateStampToggle
            Spacer(minLength: 0)
            HStack {
                revertButton
                Spacer()
                // Review adds a draft; library edits an existing clip.
                if isReview { addButton } else { deleteButton }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Shared pieces

    @ViewBuilder
    private var photoView: some View {
        if let image {
            PhotoCropView(image: image, crop: cropBinding, aspect: aspectLock.ratio)
                .frame(minHeight: 300, maxHeight: .infinity)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
        }
    }

    private var cropControls: some View {
        HStack {
            Text("Show for")
            TextField("", value: durationBinding,
                      format: .number.precision(.fractionLength(1)))
                .labelsHidden()
                .frame(width: 48)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
            Text("s")
            Stepper(value: durationBinding, in: durationRange, step: durationStep) {}
                .labelsHidden()
                .help("Adjust how long this photo is shown (− / + also work)")
            // Hidden buttons so − and + adjust the duration via the keyboard.
            // "=" is the unshifted "+" key, accepted as a convenience.
            .background {
                HStack {
                    Button("Longer") { adjustDuration(by: durationStep) }
                        .keyboardShortcut("+", modifiers: [])
                    Button("Longer") { adjustDuration(by: durationStep) }
                        .keyboardShortcut("=", modifiers: [])
                    Button("Shorter") { adjustDuration(by: -durationStep) }
                        .keyboardShortcut("-", modifiers: [])
                }
                .hidden()
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
    }

    private var captionField: some View {
        HStack(spacing: 8) {
            Image(systemName: "captions.bubble")
                .foregroundStyle(.secondary)
            TextField("Caption (optional)", text: $clip.caption)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var dateStampToggle: some View {
        Toggle("Date stamp", isOn: $clip.showsDateOverlay)
            .toggleStyle(.checkbox)
            .help("Show this photo's date in the bottom-left corner of the month video. Turn off for cover photos.")
    }

    private var revertButton: some View {
        Button {
            clip = original
            editedDate = original.date
            aspectLock = .free
        } label: {
            Label("Revert", systemImage: "arrow.uturn.backward")
        }
        .disabled(!hasChanges)
        .help("Discard this photo's unsaved changes")
    }

    @ViewBuilder
    private var addButton: some View {
        if let onAdd {
            Button {
                var added = clip
                added.date = editedDate.dayKey
                onAdd(added)
            } label: {
                Label("Add to Clips", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Add this cropped photo to the day's clips (⌘↩)")
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            if let onDelete {
                onDelete()
            } else {
                store.delete(clip)
                dismiss()
            }
        } label: {
            Label("Delete Photo", systemImage: "trash")
        }
    }

    private func saveEdits() {
        var updated = clip
        updated.date = editedDate.dayKey
        store.update(updated)
    }

    private func load() {
        let url = sourceURL ?? store.fileURL(for: clip)
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
