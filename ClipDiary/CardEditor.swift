import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Cards gallery + editor. `CardsManagerView` is the shared host: it shows
/// the gallery and swaps in `CardEditorView` when a card is opened. It's used
/// both as the standalone Cards window (manage mode) and as a picker sheet
/// (`onPick` set) for the day editor and the cover/ending selectors.

// MARK: - Manager (gallery ⇄ editor host)

struct CardsManagerView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    /// When set, the gallery is a picker: tapping a card calls this and closes.
    var onPick: ((CardDocument) -> Void)? = nil

    private struct EditTarget: Identifiable {
        let id = UUID()
        var doc: CardDocument
        var isNew: Bool
    }
    @State private var editing: EditTarget?

    var body: some View {
        Group {
            if let target = editing {
                CardEditorView(card: target.doc, isNew: target.isNew) { editing = nil }
            } else {
                CardGalleryView(
                    isPicker: onPick != nil,
                    onPick: { card in onPick?(card); dismiss() },
                    onEdit: { editing = EditTarget(doc: $0, isNew: false) },
                    onNew: {
                        editing = EditTarget(
                            doc: CardDocument(name: freshName(), aspect: store.settings.orientation),
                            isNew: true
                        )
                    },
                    onClose: { dismiss() }
                )
            }
        }
        .frame(minWidth: 900, idealWidth: 1040, minHeight: 620, idealHeight: 760)
    }

    /// A free default name for a new card ("Untitled", "Untitled 2", …).
    private func freshName() -> String {
        var name = "Untitled"
        var n = 2
        while !store.cardNameAvailable(name) {
            name = "Untitled \(n)"
            n += 1
        }
        return name
    }
}

// MARK: - Gallery

struct CardGalleryView: View {
    @EnvironmentObject var store: LibraryStore
    var isPicker: Bool
    var onPick: (CardDocument) -> Void
    var onEdit: (CardDocument) -> Void
    var onNew: () -> Void
    var onClose: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isPicker ? "Choose a Card" : "Cards")
                    .font(.title2.bold())
                Spacer()
                Button { onNew() } label: {
                    Label("New Card…", systemImage: "plus")
                }
                if isPicker {
                    Button("Cancel") { onClose() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            if store.cards.isEmpty {
                ContentUnavailableView {
                    Label("No cards yet", systemImage: "rectangle.on.rectangle.angled")
                } description: {
                    Text("Design a title slide — a cover, an ending, or a captioned frame — and reuse it in your videos.")
                } actions: {
                    Button("New Card…") { onNew() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(store.cards) { card in
                            cell(card)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private func cell(_ card: CardDocument) -> some View {
        VStack(spacing: 6) {
            CardThumbnail(card: card)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
                .onTapGesture { isPicker ? onPick(card) : onEdit(card) }
            HStack(spacing: 4) {
                Text(card.name)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                Menu {
                    if isPicker { Button("Use This Card") { onPick(card) } }
                    Button("Edit…") { onEdit(card) }
                    Button("Duplicate") { store.duplicateCard(card) }
                    Divider()
                    Button("Delete", role: .destructive) { store.deleteCard(card) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .help(isPicker ? "Click to use this card" : "Click to edit this card")
    }
}

/// Renders a card to a preview image at the cell's aspect, refreshing whenever
/// the card's design changes (its `Hashable` value drives the task id).
struct CardThumbnail: View {
    @EnvironmentObject var store: LibraryStore
    let card: CardDocument
    var height: CGFloat = 128

    @State private var image: NSImage?

    private var size: CGSize {
        let a = card.aspect.size
        return CGSize(width: height * a.width / a.height, height: height)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.black)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: card) {
            let pixels = CGSize(width: size.width * 2, height: size.height * 2)
            let cg = store.renderCardImage(card, size: pixels)
            image = cg.map { NSImage(cgImage: $0, size: .zero) }
        }
    }
}

// MARK: - Editor

struct CardEditorView: View {
    @EnvironmentObject var store: LibraryStore

    @State private var doc: CardDocument
    @State private var editedName: String
    @State private var selectedID: UUID?
    @State private var canvasImage: NSImage?

    private let isNew: Bool
    private let onClose: () -> Void

    init(card: CardDocument, isNew: Bool, onClose: @escaping () -> Void) {
        _doc = State(initialValue: card)
        _editedName = State(initialValue: card.name)
        self.isNew = isNew
        self.onClose = onClose
    }

    /// The document as it would be saved (name folded in from the field).
    private var current: CardDocument {
        var d = doc
        d.name = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return d
    }

    private var nameIsValid: Bool {
        store.cardNameAvailable(editedName, excluding: doc.id)
    }

    /// Render size for the live canvas — the card's aspect, longer side ~1000px.
    private var previewSize: CGSize {
        let s = doc.canvasSize
        let scale = 1000 / max(s.width, s.height)
        return CGSize(width: s.width * scale, height: s.height * scale)
    }

    private var selectedIndex: Int? {
        selectedID.flatMap { id in doc.elements.firstIndex { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            elementToolbar
            HStack(alignment: .top, spacing: 16) {
                CardCanvas(image: canvasImage, canvasSize: doc.canvasSize,
                           elements: $doc.elements, selectedID: $selectedID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                inspector
                    .frame(width: 300)
            }
        }
        .padding(20)
        .onChange(of: doc, initial: true) { _, _ in rerender() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            TextField("Card name", text: $editedName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            if !nameIsValid {
                Text(editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "Name required" : "Name already used")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
            Button("Duplicate") {
                // Persist the current edits (so the copied folder reflects them),
                // then duplicate and continue editing the copy.
                store.saveCard(current)
                if let copy = store.duplicateCard(current) {
                    doc = copy
                    editedName = copy.name
                }
            }
            .disabled(!nameIsValid)
            .help("Save and open a copy of this card")
            Button("Cancel") {
                if isNew { store.discardUnsavedCard(doc) }
                onClose()
            }
            .keyboardShortcut(.cancelAction)
            Button("Save") {
                store.saveCard(current)
                onClose()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!nameIsValid)
        }
    }

    // MARK: Element toolbar

    private var elementToolbar: some View {
        HStack(spacing: 8) {
            Button { addText() } label: { Label("Add Text", systemImage: "textformat") }
            Button { addImageFromFile() } label: { Label("Add Image…", systemImage: "photo") }
            Button { pasteImage() } label: { Label("Paste Image", systemImage: "doc.on.clipboard") }
                .disabled(!pasteboardHasImage)
            Spacer()
            // Z-order + delete act on the selected element.
            Group {
                Button { moveSelected(.back) } label: { Image(systemName: "square.3.layers.3d.bottom.filled") }
                    .help("Send to back")
                Button { moveSelected(.backward) } label: { Image(systemName: "arrow.down") }
                    .help("Send backward")
                Button { moveSelected(.forward) } label: { Image(systemName: "arrow.up") }
                    .help("Bring forward")
                Button { moveSelected(.front) } label: { Image(systemName: "square.3.layers.3d.top.filled") }
                    .help("Bring to front")
                Button(role: .destructive) { deleteSelected() } label: { Image(systemName: "trash") }
                    .help("Delete element")
            }
            .disabled(selectedIndex == nil)
        }
        .buttonStyle(.bordered)
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Card") {
                    VStack(alignment: .leading, spacing: 8) {
                        ColorPicker("Background", selection: bind($doc.background), supportsOpacity: true)
                        Picker("Shape", selection: $doc.aspect) {
                            ForEach(ProjectSettings.Orientation.allCases) { o in
                                Text(o == .portrait ? "Portrait" : "Landscape").tag(o)
                            }
                        }
                        Stepper(value: $doc.displaySeconds, in: 0.5...30, step: 0.5) {
                            Text(String(format: "Show for %.1f s", doc.displaySeconds))
                                .monospacedDigit()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                if let textStyle = selectedTextStyle {
                    GroupBox("Text") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Text", text: textStyle.string, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(1...4)
                            Picker("Font", selection: textStyle.fontName) {
                                ForEach(Card.fonts, id: \.name) { font in
                                    Text(font.label).tag(font.name)
                                }
                            }
                            HStack {
                                Text("Size")
                                Slider(value: textStyle.sizeFraction, in: 0.03...0.4)
                            }
                            ColorPicker("Colour", selection: bind(textStyle.color), supportsOpacity: true)
                            Picker("Align", selection: textStyle.alignment) {
                                Image(systemName: "text.alignleft").tag(CardTextAlignment.leading)
                                Image(systemName: "text.aligncenter").tag(CardTextAlignment.center)
                                Image(systemName: "text.alignright").tag(CardTextAlignment.trailing)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                } else if selectedIndex != nil {
                    GroupBox("Image") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Drag the corners on the canvas to resize, drag the middle to move.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Replace Image…") { replaceSelectedImage() }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                } else {
                    Text("Select an element to edit it, or add text/an image above.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Binding into the selected element's `TextStyle` (nil unless a text
    /// element is selected). Writing back re-wraps the enum case.
    private var selectedTextStyle: Binding<TextStyle>? {
        guard let idx = selectedIndex, case .text(let style) = doc.elements[idx].kind else { return nil }
        return Binding(
            get: {
                if case .text(let s) = doc.elements[idx].kind { return s }
                return style
            },
            set: { doc.elements[idx].kind = .text($0) }
        )
    }

    /// Bridges a `CardColor` binding to the `Color` the SwiftUI pickers use.
    private func bind(_ source: Binding<CardColor>) -> Binding<Color> {
        Binding(get: { source.wrappedValue.color }, set: { source.wrappedValue = CardColor($0) })
    }

    // MARK: Rendering

    private func rerender() {
        canvasImage = store.renderCardImage(doc, size: previewSize)
            .map { NSImage(cgImage: $0, size: .zero) }
    }

    // MARK: Element actions

    private func addText() {
        var element = Card.newTextElement()
        element.id = UUID()
        doc.elements.append(element)
        selectedID = element.id
    }

    private func addImageFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let assetID = store.importCardImage(from: url, into: doc) else { return }
        appendImage(assetID: assetID)
    }

    private var pasteboardHasImage: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    private func pasteImage() {
        guard let images = NSPasteboard.general.readObjects(
            forClasses: [NSImage.self], options: nil) as? [NSImage],
              let image = images.first,
              let assetID = store.importCardImage(image, into: doc)
        else { return }
        appendImage(assetID: assetID)
    }

    /// Appends a freshly imported image element sized to the image's aspect.
    private func appendImage(assetID: String) {
        let assetURL = store.cardAssetURL(card: doc, assetID: assetID)
        let imageSize = NSImage(contentsOf: assetURL)?.size ?? CGSize(width: 1, height: 1)
        let element = Card.newImageElement(assetID: assetID, imageSize: imageSize, canvas: doc.canvasSize)
        doc.elements.append(element)
        selectedID = element.id
    }

    private func replaceSelectedImage() {
        guard let idx = selectedIndex else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let assetID = store.importCardImage(from: url, into: doc) else { return }
        doc.elements[idx].kind = .image(assetID: assetID)
    }

    private enum ZOp { case back, backward, forward, front }

    private func moveSelected(_ op: ZOp) {
        guard let idx = selectedIndex else { return }
        var elements = doc.elements
        let element = elements.remove(at: idx)
        let target: Int
        switch op {
        case .back: target = 0
        case .backward: target = max(0, idx - 1)
        case .forward: target = min(elements.count, idx + 1)
        case .front: target = elements.count
        }
        elements.insert(element, at: target)
        doc.elements = elements
    }

    private func deleteSelected() {
        guard let idx = selectedIndex else { return }
        doc.elements.remove(at: idx)
        selectedID = nil
    }
}

// MARK: - Interactive canvas

/// The card preview (a rendered `NSImage`) with a selection/move/resize overlay
/// per element. Mutating an element's frame re-renders the image via the
/// editor's `onChange`, so the canvas always shows the real output.
private struct CardCanvas: View {
    let image: NSImage?
    let canvasSize: CGSize
    @Binding var elements: [CardElement]
    @Binding var selectedID: UUID?

    private let minSize: Double = 0.05
    private let handleR: CGFloat = 7
    @State private var moveAnchor: CropRect?

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
            case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let fit = fittedRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(white: 0.1))
                    .frame(width: fit.width, height: fit.height)
                    .offset(x: fit.minX, y: fit.minY)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: fit.width, height: fit.height)
                        .offset(x: fit.minX, y: fit.minY)
                }

                // Hit targets per element (back→front so the front wins taps).
                ForEach(elements) { element in
                    let r = viewRect(element.frame, in: fit)
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .onTapGesture { selectedID = element.id }
                        .gesture(element.id == selectedID ? moveGesture(element.id, fit: fit) : nil)
                }

                // Selection chrome + resize handles for the selected element.
                if let idx = selectedIndex {
                    let r = viewRect(elements[idx].frame, in: fit)
                    Rectangle()
                        .stroke(Color.yellow, lineWidth: 2)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .allowsHitTesting(false)
                    ForEach(Corner.allCases, id: \.self) { corner in
                        let p = corner.point(in: r)
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: handleR * 2, height: handleR * 2)
                            .contentShape(Circle().inset(by: -8))
                            .offset(x: p.x - handleR, y: p.y - handleR)
                            .gesture(cornerGesture(corner, idx: idx, fit: fit))
                    }
                }
            }
            .coordinateSpace(name: "cardcanvas")
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var selectedIndex: Int? {
        selectedID.flatMap { id in elements.firstIndex { $0.id == id } }
    }

    // MARK: Gestures

    private func moveGesture(_ id: UUID, fit: CGRect) -> some Gesture {
        DragGesture(coordinateSpace: .named("cardcanvas"))
            .onChanged { value in
                guard fit.width > 0, fit.height > 0,
                      let idx = elements.firstIndex(where: { $0.id == id }) else { return }
                if moveAnchor == nil { moveAnchor = elements[idx].frame }
                guard let anchor = moveAnchor else { return }
                var f = anchor
                f.x = min(max(0, anchor.x + Double(value.translation.width / fit.width)), 1 - f.width)
                f.y = min(max(0, anchor.y + Double(value.translation.height / fit.height)), 1 - f.height)
                elements[idx].frame = f
            }
            .onEnded { _ in moveAnchor = nil }
    }

    private func cornerGesture(_ corner: Corner, idx: Int, fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("cardcanvas"))
            .onChanged { value in
                guard fit.width > 0, fit.height > 0, idx < elements.count else { return }
                let ux = Double((value.location.x - fit.minX) / fit.width)
                let uy = Double((value.location.y - fit.minY) / fit.height)
                var f = elements[idx].frame
                let right = f.x + f.width
                let bottom = f.y + f.height
                switch corner {
                case .topLeft, .bottomLeft:
                    let nx = min(max(0, ux), right - minSize)
                    f.width = right - nx
                    f.x = nx
                case .topRight, .bottomRight:
                    f.width = min(max(minSize, ux - f.x), 1 - f.x)
                }
                switch corner {
                case .topLeft, .topRight:
                    let ny = min(max(0, uy), bottom - minSize)
                    f.height = bottom - ny
                    f.y = ny
                case .bottomLeft, .bottomRight:
                    f.height = min(max(minSize, uy - f.y), 1 - f.y)
                }
                elements[idx].frame = f
            }
    }

    // MARK: Geometry

    private func fittedRect(in size: CGSize) -> CGRect {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
        let scale = min(size.width / canvasSize.width, size.height / canvasSize.height)
        let w = canvasSize.width * scale
        let h = canvasSize.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func viewRect(_ f: CropRect, in fit: CGRect) -> CGRect {
        CGRect(x: fit.minX + f.x * fit.width, y: fit.minY + f.y * fit.height,
               width: f.width * fit.width, height: f.height * fit.height)
    }
}
