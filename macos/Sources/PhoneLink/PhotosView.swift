import SwiftUI
import UniformTypeIdentifiers

struct PhotosGrid: View {
    @EnvironmentObject private var link: PhoneLink
    @ObservedObject private var features = PhoneFeatures.shared
    @Binding var selection: Int64?
    @State private var marked = Set<Int64>()
    @State private var deletion: Set<Int64>?

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 160), spacing: 3)]

    var body: some View {
        Group {
            if link.state != .connected && link.photos.isEmpty {
                NotConnectedView()
            } else if let err = link.photosError {
                ContentUnavailableView {
                    Label("Photos Not Available", systemImage: "photo.on.rectangle")
                } description: {
                    Text(err)
                } actions: {
                    Button("Try Again") { link.loadPhotos() }
                }
            } else if link.photos.isEmpty {
                ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle",
                                       description: Text("New photos and screenshots show here."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(link.photos) { p in
                            PhotoCell(photo: p, selected: marked.contains(p.id) || (marked.isEmpty && selection == p.id)) {
                                deletion = marked.contains(p.id) ? marked : [p.id]
                            }
                            .onTapGesture(count: 2) { PhotoActions.open(p) }
                            .onTapGesture { click(p.id) }
                        }
                    }
                    .padding(3)
                }
                .focusable()
                .focusEffectDisabled()
                .onDeleteCommand {
                    let ids = marked.isEmpty ? Set(selection.map { [$0] } ?? []) : marked
                    if !ids.isEmpty { deletion = ids }
                }
                .onAppear {
                    // Demo only: show the confirmation for a screenshot.
                    if PhoneLink.isDemo, ProcessInfo.processInfo.environment["PHONELINK_DEMO"] == "deletephotos" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            marked = Set(link.photos.prefix(3).map(\.id))
                            deletion = marked
                        }
                    }
                }
            }
        }
        .navigationTitle("Photos")
        .toolbar {
            ToolbarItem {
                Button { link.loadPhotos() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .help("Reload Photos")
                    .disabled(link.state != .connected)
            }
        }
        .onAppear { if link.state == .connected, !PhoneLink.isDemo { link.loadPhotos() } }
        .onChange(of: link.state) { _, s in if s == .connected { link.loadPhotos() } }
        .alert(deleteTitle, isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), presenting: deletion) { ids in
            if features.available(.deletePhotos) {
                Button("Delete", role: .destructive) {
                    link.deletePhotos(ids)
                    marked.subtract(ids)
                    if let s = selection, ids.contains(s) { selection = nil }
                }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { ids in
            Text(deleteMessage(ids.count))
        }
    }

    private func click(_ id: Int64) {
        if NSEvent.modifierFlags.contains(.command) {
            if marked.isEmpty, let s = selection { marked = [s] }
            if marked.contains(id) { marked.remove(id) } else { marked.insert(id) }
        } else {
            marked = [id]
        }
        selection = id
    }

    private var deleteTitle: String {
        let n = deletion?.count ?? 1
        if !features.available(.deletePhotos) { return n == 1 ? "This Photo Can’t Be Deleted Now" : "These Photos Can’t Be Deleted Now" }
        return n == 1 ? "Delete this photo from the phone?" : "Delete \(n) photos from the phone?"
    }

    private func deleteMessage(_ n: Int) -> String {
        if let reason = features.reason(.deletePhotos) { return reason }
        if link.photosGoToTrash { return n == 1 ? "The photo goes to the trash on the phone for 30 days." : "The photos go to the trash on the phone for 30 days." }
        return "This deletes \(n == 1 ? "it" : "them") permanently. You can’t undo this action."
    }
}

private struct PhotoCell: View {
    @EnvironmentObject private var link: PhoneLink
    let photo: PhonePhoto
    let selected: Bool
    var onDelete: () -> Void = {}

    var body: some View {
        Color(nsColor: .quaternaryLabelColor)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let img = link.photoThumbs[photo.id] {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                }
            }
            .clipped()
            .overlay {
                if selected {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .contentShape(Rectangle())
            .onDrag { PhotoActions.provider(photo) } preview: {
                if let img = link.photoThumbs[photo.id] {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: 120)
                }
            }
            .contextMenu {
                Button("Open") { PhotoActions.open(photo) }
                Button("Save to Downloads") { PhotoActions.save(photo) }
                Button("Copy") { PhotoActions.copy(photo) }
                Divider()
                Button("Delete…", action: onDelete)
            }
            .help(photo.name)
            .accessibilityLabel(photo.name)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct PhotoDetail: View {
    @EnvironmentObject private var link: PhoneLink
    let id: Int64?
    @State private var full: NSImage?
    @State private var loadedId: Int64?

    var body: some View {
        if let id, let p = link.photos.first(where: { $0.id == id }) {
            VStack(spacing: 0) {
                ZStack {
                    if let img = (loadedId == id ? full : nil) ?? link.photoThumbs[id] {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                            .onDrag { PhotoActions.provider(p) }
                    }
                    if loadedId != id { ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.callout.weight(.medium)).lineLimit(1)
                        Text(detail(p)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Copy") { PhotoActions.copy(p) }
                    Button("Save to Downloads") { PhotoActions.save(p) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            }
            .navigationTitle(p.name)
            .task(id: id) {
                full = nil
                loadedId = nil
                let url = await withCheckedContinuation { c in
                    FileHub.shared.fetch(path: "media:\(id)", name: p.name) { c.resume(returning: $0) }
                }
                // A different photo was selected while this one loaded.
                guard !Task.isCancelled else { return }
                full = url.flatMap(NSImage.init(contentsOf:))
                loadedId = id
            }
        } else {
            ContentUnavailableView("No Photo Selected", systemImage: "photo")
        }
    }

    private func detail(_ p: PhonePhoto) -> String {
        var parts = [p.date.formatted(date: .abbreviated, time: .shortened)]
        if p.width > 0 { parts.append("\(p.width) × \(p.height)") }
        if p.size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: p.size, countStyle: .file)) }
        return parts.joined(separator: " · ")
    }
}

enum PhotoActions {
    static func type(_ p: PhonePhoto) -> UTType {
        UTType(filenameExtension: (p.name as NSString).pathExtension) ?? .jpeg
    }

    /// Loads the file from the phone only when the drop happens.
    static func provider(_ p: PhonePhoto) -> NSItemProvider {
        let item = NSItemProvider()
        item.suggestedName = (p.name as NSString).deletingPathExtension
        item.registerFileRepresentation(forTypeIdentifier: type(p).identifier, fileOptions: [], visibility: .all) { done in
            DispatchQueue.main.async {
                FileHub.shared.fetch(path: "media:\(p.id)", name: p.name) { url in
                    done(url, false, url == nil ? CocoaError(.fileReadUnknown) : nil)
                }
            }
            return nil
        }
        return item
    }

    static func open(_ p: PhonePhoto) {
        fetch(p) { NSWorkspace.shared.open($0) }
    }

    static func copy(_ p: PhonePhoto) {
        fetch(p) { url in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL] + (NSImage(contentsOf: url).map { [$0] } ?? []))
        }
    }

    static func save(_ p: PhonePhoto) {
        fetch(p) { url in
            let dest = unique(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent(p.name))
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            } catch {
                PhoneLink.shared.banner = "Phone Link could not save the photo in Downloads."
            }
        }
    }

    /// Calls `use` on the main thread. Tells the user if the copy fails.
    private static func fetch(_ p: PhonePhoto, use: @escaping (URL) -> Void) {
        FileHub.shared.fetch(path: "media:\(p.id)", name: p.name) { url in
            if let url { use(url) } else { PhoneLink.shared.banner = "Phone Link could not get the photo from the phone." }
        }
    }

    private static func unique(_ u: URL) -> URL {
        var n = 2
        var out = u
        let base = u.deletingPathExtension().lastPathComponent, ext = u.pathExtension
        while FileManager.default.fileExists(atPath: out.path) {
            out = u.deletingLastPathComponent().appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : "." + ext))
            n += 1
        }
        return out
    }
}
