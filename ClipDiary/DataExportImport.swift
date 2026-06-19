import SwiftUI
import UniformTypeIdentifiers

/// Importing a 1SE **"Download Your Data"** export (the GDPR-style zip you
/// request from the 1SE website, unzipped to a folder). Unlike a mashed video
/// — where the date is only burned into the pixels and has to be OCR'd, then
/// chronologically repaired (see `MashImport.swift`) — this export already
/// carries every clip's date as structured data, so there's nothing to guess.
///
/// Layout we read:
/// - `files/snapshots/manifest-*.json` — periodic full snapshots. The newest
///   non-partial one lists every project and, per project, every snippet with
///   its `date` (the assigned timeline day) and `video_id`.
/// - `files/snippets/<video_id>/video.mov` — the actual clip for that snippet
///   (the full snippet 1SE plays, not a 1-second trim).
///
/// We copy each snippet's `video.mov` into the project untrimmed (matching what
/// 1SE plays) with the date stamp left on (these raw clips aren't pre-stamped).

// MARK: - Parsed export

/// One snippet to import: the day it belongs to, its source `video.mov`, and
/// the caption 1SE showed on it (empty when there was none).
struct DataExportSnippet {
    let date: Date
    let videoURL: URL
    let caption: String
}

/// A 1SE project found in the export, ready to import into a ClipDiary project.
/// `snippets` are in the manifest's order — date ascending, and within a day in
/// 1SE's play order — which the import preserves.
struct DataExportProject: Identifiable {
    let id: String
    let title: String
    let snippets: [DataExportSnippet]

    var clipCount: Int { snippets.count }

    /// How many of the clips carry a 1SE caption, for the picker summary.
    var captionCount: Int { snippets.lazy.filter { !$0.caption.isEmpty }.count }

    /// First…last calendar day covered, for the picker summary.
    var dateRange: (start: Date, end: Date)? {
        let dates = snippets.map(\.date)
        guard let lo = dates.min(), let hi = dates.max() else { return nil }
        return (lo, hi)
    }
}

enum DataExportError: LocalizedError {
    case noManifest
    case unreadableManifest(String)
    case noProjects

    var errorDescription: String? {
        switch self {
        case .noManifest:
            return "This folder doesn't look like a 1SE data export — no "
                + "files/snapshots/manifest-*.json was found. Pick the folder you "
                + "unzipped from 1SE's \u{201C}Download Your Data\u{201D} request."
        case .unreadableManifest(let reason):
            return "Could not read the 1SE export manifest: \(reason)"
        case .noProjects:
            return "The 1SE export has no projects with clips to import."
        }
    }
}

// MARK: - Manifest reading

enum DataExportReader {
    /// Raw shape of a snapshot manifest — only the fields we use.
    private struct Manifest: Decodable {
        let partial: Bool?
        let projects: [Project]
        /// Keyed by project id (a string like "1" or "1661401883").
        let snippets: [String: [Snippet]]

        struct Project: Decodable {
            let id: String
            let title: String
        }
        struct Snippet: Decodable {
            let date: String
            let videoID: String?
            let key: String?
            enum CodingKeys: String, CodingKey {
                case date, key
                case videoID = "video_id"
            }
        }
    }

    /// Captions live only in `backups.json` (the manifest doesn't carry them).
    private struct Backups: Decodable {
        let snippets: [Entry]
        struct Entry: Decodable {
            let videoUID: String?
            let locationText: String?
            let diaryText: String?
            let updatedAt: String?
            enum CodingKeys: String, CodingKey {
                case videoUID = "video_uid"
                case locationText = "location_text"
                case diaryText = "diary_text"
                case updatedAt = "updated_at"
            }
        }
    }

    /// Reads the newest full snapshot in `root` and returns its projects with
    /// every snippet whose `video.mov` is actually present, biggest project
    /// first. Skips empty projects (e.g. an unused "Freestyle").
    static func read(root: URL) throws -> [DataExportProject] {
        // 1SE writes the snippet date as a plain calendar day (no time/zone).
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"

        guard let manifestURL = newestFullManifest(in: root) else {
            throw DataExportError.noManifest
        }
        let manifest: Manifest
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw DataExportError.unreadableManifest(error.localizedDescription)
        }

        let titles = Dictionary(manifest.projects.map { ($0.id, $0.title) },
                                uniquingKeysWith: { a, _ in a })
        let captions = captionMap(root: root)
        let snippetsDir = root.appendingPathComponent("files/snippets", isDirectory: true)
        let fm = FileManager.default

        var projects: [DataExportProject] = []
        for (projectID, rawSnippets) in manifest.snippets {
            var snippets: [DataExportSnippet] = []
            for raw in rawSnippets {
                guard let videoID = raw.videoID ?? raw.key,
                      let day = dateFormatter.date(from: raw.date) else { continue }
                let videoURL = snippetsDir
                    .appendingPathComponent(videoID, isDirectory: true)
                    .appendingPathComponent("video.mov")
                guard fm.fileExists(atPath: videoURL.path) else { continue }
                snippets.append(DataExportSnippet(date: day.dayKey, videoURL: videoURL,
                                                  caption: captions[videoID] ?? ""))
            }
            guard !snippets.isEmpty else { continue }
            projects.append(DataExportProject(
                id: projectID,
                title: titles[projectID] ?? "Project \(projectID)",
                snippets: snippets
            ))
        }
        guard !projects.isEmpty else { throw DataExportError.noProjects }
        return projects.sorted { $0.clipCount > $1.clipCount }
    }

    /// The newest non-partial manifest by filename. Names are
    /// `manifest-YYYY.MM.DD-HH.MM.SS-<hash>.json`, so a descending string sort is
    /// newest-first. Partials only list what changed since the last full
    /// snapshot, so they'd give an incomplete import — a full one is required.
    private static func newestFullManifest(in root: URL) -> URL? {
        let dir = root.appendingPathComponent("files/snapshots", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return nil }
        let manifests = files
            .filter { $0.lastPathComponent.hasPrefix("manifest-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        // Prefer the newest that decodes as full; fall back to the newest that
        // simply decodes (some exports may never have written a full snapshot).
        for url in manifests {
            if let data = try? Data(contentsOf: url),
               let m = try? JSONDecoder().decode(Manifest.self, from: data),
               m.partial != true {
                return url
            }
        }
        return manifests.first
    }

    /// Maps each snippet's video id to the caption 1SE displayed on it, read
    /// from `backups.json` (the manifest omits captions). 1SE keeps the user's
    /// caption in `location_text` — a legacy field name; captions grew out of
    /// the old location stamp — with `diary_text` a separate, usually-empty note
    /// used only as a fallback. A video id recurs across snapshot history, so the
    /// newest non-empty caption wins (they don't conflict in practice). Returns
    /// empty if `backups.json` is missing or unreadable — captions are a nice-to-
    /// have, never a reason to fail the import.
    private static func captionMap(root: URL) -> [String: String] {
        let url = root.appendingPathComponent("backups.json")
        guard let data = try? Data(contentsOf: url),
              let backups = try? JSONDecoder().decode(Backups.self, from: data)
        else { return [:] }
        var byUID: [String: (caption: String, updatedAt: String)] = [:]
        for entry in backups.snippets {
            guard let uid = entry.videoUID,
                  let caption = nonEmpty(entry.locationText) ?? nonEmpty(entry.diaryText)
            else { continue }
            let updatedAt = entry.updatedAt ?? ""
            if let existing = byUID[uid], existing.updatedAt >= updatedAt { continue }
            byUID[uid] = (caption, updatedAt)
        }
        return byUID.mapValues(\.caption)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        let trimmed = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Import sheet

/// Wraps the picked export folder URL so it can drive `.sheet(item:)`.
struct DataExportSource: Identifiable {
    let id = UUID()
    let url: URL
}

/// Reads a 1SE data export, lets the user pick which project to import, then
/// copies that project's clips into the currently open ClipDiary project with
/// their dates already set — no scanning, no date guessing.
struct DataExportImportSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let exportURL: URL

    private enum Phase {
        case loading
        case choose([DataExportProject])
        case importing(done: Int, total: Int, title: String)
        case done(count: Int, title: String)
        case failed(String)
    }
    @State private var phase: Phase = .loading
    @State private var selectedID: String?
    /// Security-scoped access to the picked folder, held for the sheet's life.
    @State private var didAccess = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import 1SE Data Export")
                .font(.title3.bold())
            Text(exportURL.lastPathComponent)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            switch phase {
            case .loading:
                ProgressView("Reading export…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 30)

            case .choose(let projects):
                chooseContent(projects)

            case .importing(let done, let total, let title):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Importing \u{201C}\(title)\u{201D}…")
                    ProgressView(value: Double(done), total: Double(max(total, 1))) {
                        Text("Clip \(min(done + 1, total)) of \(total)")
                            .font(.caption).monospacedDigit()
                    }
                }

            case .done(let count, let title):
                Label(
                    "Imported \(count) clip\(count == 1 ? "" : "s") from \u{201C}\(title)\u{201D}.",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)

            case .failed(let message):
                Text(message).foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                switch phase {
                case .done:
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                case .importing:
                    Button("Cancel") { dismiss() }.disabled(true)
                default:
                    Button("Cancel") { dismiss() }
                    if case .choose = phase {
                        Button("Import") { runImport() }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedID == nil)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        // Closing mid-import would leave the copy loop running invisibly.
        .interactiveDismissDisabled(isImporting)
        .onAppear { didAccess = exportURL.startAccessingSecurityScopedResource() }
        .onDisappear { if didAccess { exportURL.stopAccessingSecurityScopedResource() } }
        .task { await load() }
    }

    private var isImporting: Bool {
        if case .importing = phase { return true }
        return false
    }

    @ViewBuilder
    private func chooseContent(_ projects: [DataExportProject]) -> some View {
        Text("Choose a project to import into \u{201C}\(store.currentProjectName ?? "this project")\u{201D}. "
             + "Each clip keeps its 1SE date and caption.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        List(selection: $selectedID) {
            ForEach(projects) { project in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.title).font(.body.weight(.medium))
                        if let range = project.dateRange {
                            Text("\(range.start.formatted(date: .abbreviated, time: .omitted)) – "
                                 + "\(range.end.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(project.clipCount) clips")
                            .font(.callout).monospacedDigit()
                            .foregroundStyle(.secondary)
                        if project.captionCount > 0 {
                            Label("\(project.captionCount)", systemImage: "text.bubble")
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .help("\(project.captionCount) clips have a 1SE caption")
                        }
                    }
                }
                .padding(.vertical, 2)
                .tag(project.id)
            }
        }
        .frame(height: 240)
        Text("Tip: import each 1SE project into its own ClipDiary project — "
             + "create or open the destination first.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func load() async {
        // Let the "Reading export…" spinner paint before the manifest parse +
        // file-existence checks briefly block the main actor (a 1.5 MB JSON and
        // a few thousand stats — a one-time hitch behind the modal).
        await Task.yield()
        do {
            let projects = try DataExportReader.read(root: exportURL)
            phase = .choose(projects)
            selectedID = projects.first?.id
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func runImport() {
        guard case .choose(let projects) = phase,
              let project = projects.first(where: { $0.id == selectedID }) else { return }
        phase = .importing(done: 0, total: project.clipCount, title: project.title)
        Task {
            await store.importDataExportProject(project.snippets) { done in
                if case .importing(_, let total, let title) = phase {
                    phase = .importing(done: done, total: total, title: title)
                }
            }
            phase = .done(count: project.clipCount, title: project.title)
        }
    }
}
