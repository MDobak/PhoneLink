import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileLocationsList: View {
    @EnvironmentObject private var link: PhoneLink
    @ObservedObject private var hub = FileHub.shared
    @ObservedObject private var drive = PhoneDrive.shared

    var body: some View {
        Group {
            if link.state != .connected {
                NotConnectedView()
            } else if let e = hub.rootsError {
                ContentUnavailableView {
                    Label(e.code == "perm" ? "Allow File Access" : "Files Not Available", systemImage: e.code == "perm" ? "lock" : "exclamationmark.triangle")
                } description: {
                    Text(e.code == "perm" ? "On the phone, open Phone Link and turn on Files. Then try again." : e.msg)
                } actions: {
                    Button("Try Again") { hub.loadRoots() }
                }
            } else {
                List(selection: Binding(get: { hub.place }, set: { p in
                    if let p, let loc = (hub.roots + hub.favorites).first(where: { $0.path == p }) { hub.go(loc) }
                })) {
                    Section("Locations") {
                        ForEach(Array(hub.roots.enumerated()), id: \.element.id) { i, r in
                            HStack {
                                Label(r.name, systemImage: r.symbol)
                                Spacer(minLength: 4)
                                if i == 0, drive.isMounted {
                                    Button { drive.eject() } label: { Image(systemName: "eject.fill") }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(.secondary)
                                        .help("Eject the phone drive from Finder")
                                } else if i == 0, drive.status == .mounting || drive.status == .ejecting {
                                    ProgressView().controlSize(.mini)
                                } else if i == 0, !PhoneLink.isDemo {
                                    Button { drive.showInFinder() } label: { Image(systemName: "externaldrive.badge.plus") }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(.secondary)
                                        .help("Show the phone drive in Finder")
                                }
                            }
                            .tag(r.path)
                            .contextMenu {
                                Button("Show in Finder") { drive.showInFinder() }
                                    .disabled(PhoneLink.isDemo || drive.status == .mounting || drive.status == .ejecting)
                                if drive.isMounted { Button("Eject") { drive.eject() } }
                            }
                        }
                    }
                    if !hub.favorites.isEmpty {
                        Section("Favorites") {
                            ForEach(hub.favorites) { Label($0.name, systemImage: $0.symbol).tag($0.path) }
                        }
                    }
                }
                .listStyle(.sidebar)
                .overlay { if hub.roots.isEmpty { ProgressView().controlSize(.small) } }
            }
        }
        .navigationTitle(hub.location?.name ?? "Files")
        // The phone can change the folder while this view is hidden.
        .onAppear { if hub.roots.isEmpty { hub.loadRoots() } else if link.state == .connected { hub.reload() } }
        .onChange(of: link.state) { _, s in
            if s == .connected { hub.loadRoots() } else { hub.reset() }
        }
    }
}

/// Text with a prefix, so other apps do not read it as a path.
enum RemoteDrag {
    static let prefix = "phonelink-item:"
    static func paths(_ items: [String]) -> [String] { items.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } }
}

struct FilesDetail: View {
    @EnvironmentObject private var link: PhoneLink
    @ObservedObject private var hub = FileHub.shared
    @ObservedObject private var drive = PhoneDrive.shared
    @State private var selection = Set<RemoteFile.ID>()
    @State private var sortOrder = [KeyPathComparator(\RemoteFile.name, comparator: .localizedStandard)]
    @State private var dropTargeted = false
    @State private var renaming: RemoteFile.ID?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool
    @State private var confirmDelete: [RemoteFile] = []
    @State private var infoPath: String?
    @State private var movePaths: [String] = []

    var body: some View {
        content
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
            .background { shortcuts }
            .onChange(of: hub.location) { _, _ in selection = []; renaming = nil }
            .onChange(of: hub.items) { _, items in
                if let p = hub.newItemPath, let f = items.first(where: { $0.path == p }) {
                    hub.newItemPath = nil
                    selection = [f.id]
                    startRename(f)
                }
                selection = selection.filter { id in items.contains { $0.id == id } }
            }
            .alert("Are you sure you want to delete \(deleteTitle)?", isPresented: Binding(get: { !confirmDelete.isEmpty }, set: { if !$0 { confirmDelete = [] } })) {
                Button("Delete", role: .destructive) { hub.delete(confirmDelete); confirmDelete = [] }
                Button("Cancel", role: .cancel) { confirmDelete = [] }
            } message: {
                Text(confirmDelete.count == 1
                     ? "This item will be deleted immediately from the phone. You can’t undo this action."
                     : "These items will be deleted immediately from the phone. You can’t undo this action.")
            }
            .alert("The Operation Can’t Be Completed", isPresented: Binding(get: { hub.opError != nil }, set: { if !$0 { hub.opError = nil } })) {
                Button("OK") { hub.opError = nil }
            } message: { Text(hub.opError?.msg ?? "") }
            .alert("The Phone Drive Can’t Be Shown in Finder", isPresented: Binding(get: { drive.error != nil }, set: { if !$0 { drive.error = nil } })) {
                Button("OK") { drive.error = nil }
            } message: { Text(drive.error ?? "") }
            .sheet(item: Binding(get: { infoPath.map(InfoTarget.init) }, set: { infoPath = $0?.path })) { t in
                FileInfoSheet(path: t.path)
            }
            .sheet(isPresented: Binding(get: { !movePaths.isEmpty }, set: { if !$0 { movePaths = [] } })) {
                MoveToSheet(paths: movePaths, start: hub.location)
            }
    }

    // MARK: Toolbar and shortcuts

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ControlGroup {
                Button { hub.back() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(!hub.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                Button { hub.forward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(!hub.canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
            }
            .controlGroupStyle(.navigation)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { FileHub.chooseAndSend(to: hub.location?.path) } label: {
                Label("Copy to Phone", systemImage: "arrow.up.doc")
            }
            .help("Copy files from this Mac to this folder")
            .disabled(!hub.writable || link.state != .connected)
            Button { hub.download(selectedFiles) } label: {
                Label("Download", systemImage: "arrow.down.doc")
            }
            .help("Copy the selected files to \(FileHub.receiveFolder.lastPathComponent) on this Mac")
            .disabled(selectedFiles.isEmpty)
            Menu {
                actionItems(selectedItems, background: true)
            } label: {
                Label("Action", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .help("Perform tasks with the selected items")
            .disabled(link.state != .connected && !PhoneLink.isDemo)
            driveButton
            TransfersButton()
        }
    }

    @ViewBuilder private var driveButton: some View {
        if drive.status == .mounting || drive.status == .ejecting {
            ProgressView().controlSize(.small).help(drive.status == .mounting ? "Mounting the phone drive…" : "Ejecting the phone drive…")
        } else {
            Button { drive.showInFinder() } label: {
                Label("Show in Finder", systemImage: "externaldrive.connected.to.line.below")
            }
            .help(drive.isMounted ? "Open the phone drive in Finder" : "Show the phone storage as a drive in Finder")
            .disabled(link.state != .connected || PhoneLink.isDemo)
        }
    }

    @ViewBuilder private func actionItems(_ files: [RemoteFile], background: Bool) -> some View {
        let changeable = hub.canModify && !files.isEmpty && !files.contains(where: hub.isRoot)
        if background || files.isEmpty {
            Button("New Folder") { hub.newFolder() }.disabled(!hub.canModify)
            if !files.isEmpty { Divider() }
        }
        if !files.isEmpty {
            Button("Open") { open(files) }
            Button("Download") { hub.download(files) }.disabled(files.allSatisfy(\.dir))
            Divider()
            Button("Get Info") { infoPath = files.first?.path }.disabled(files.count != 1)
            Button("Rename") { if let f = files.first { startRename(f) } }.disabled(!changeable || files.count != 1)
            Button("Duplicate") { hub.duplicate(files) }.disabled(!changeable)
            Button("Move To…") { movePaths = files.map(\.path) }.disabled(!changeable)
            Divider()
            Button("Delete Immediately…") { confirmDelete = files }.disabled(!changeable)
        }
        if background {
            Divider()
            if drive.isMounted {
                Button("Eject Phone Drive") { drive.eject() }
            } else {
                Button("Show in Finder") { drive.showInFinder() }.disabled(link.state != .connected || PhoneLink.isDemo || drive.status != .off)
            }
        }
    }

    /// Finder shortcuts. The buttons have zero size so only their shortcuts work.
    private var shortcuts: some View {
        let one = selectedItems.count == 1 ? selectedItems.first : nil
        let changeable = hub.canModify && !selectedItems.isEmpty && !selectedItems.contains(where: hub.isRoot)
        let idle = renaming == nil
        return Group {
            Button("Rename") { if let one { startRename(one) } }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!idle || one == nil || !changeable)
            Button("Delete Immediately…") { confirmDelete = selectedItems }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!idle || !changeable)
            Button("New Folder") { hub.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!idle || !hub.canModify)
            Button("Get Info") { infoPath = one?.path }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!idle || one == nil)
            Button("Duplicate") { hub.duplicate(selectedItems) }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!idle || !changeable)
            Button("Open") { open(selectedItems) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!idle || selectedItems.isEmpty)
            Button("Open") { open(selectedItems) }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!idle || selectedItems.isEmpty)
            Button("Enclosing Folder") { hub.openParent() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!idle || hub.parentLocation == nil)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: Helpers

    private var deleteTitle: String {
        confirmDelete.count == 1 ? "“\(confirmDelete[0].name)”" : "the \(confirmDelete.count) selected items"
    }

    private var subtitle: String {
        guard hub.location != nil, hub.error == nil, !hub.loading else { return "" }
        return hub.items.count == 1 ? "1 item" : "\(hub.items.count) items"
    }

    private var sorted: [RemoteFile] { hub.items.sorted(using: sortOrder) }
    private var selectedItems: [RemoteFile] { hub.items.filter { selection.contains($0.id) } }
    private var selectedFiles: [RemoteFile] { selectedItems.filter { !$0.dir } }

    private func open(_ files: [RemoteFile]) {
        if files.count == 1, let f = files.first { hub.open(f) } else { hub.download(files.filter { !$0.dir }, open: true) }
    }

    private func startRename(_ f: RemoteFile) {
        guard hub.canModify, !hub.isRoot(f) else { return }
        renameText = f.name
        renaming = f.id
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        guard let id = renaming else { return }
        renaming = nil
        if let f = hub.items.first(where: { $0.id == id }) { hub.rename(f, to: renameText) }
    }

    private func moveDropped(_ items: [String], into f: RemoteFile) -> Bool {
        let paths = RemoteDrag.paths(items)
        guard f.dir, hub.canModify, !paths.isEmpty else { return false }
        hub.move(paths, into: f.path)
        return true
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if link.state != .connected && !PhoneLink.isDemo {
            NotConnectedView()
        } else if hub.location == nil {
            ContentUnavailableView("No Location Selected", systemImage: "folder")
        } else if hub.loading && hub.items.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let e = hub.error {
            ContentUnavailableView {
                Label("Can’t Open Folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(e)
            } actions: {
                Button("Try Again") { hub.reload() }
            }
        } else {
            table
        }
    }

    @ViewBuilder private func nameCell(_ f: RemoteFile) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: FileIcons.icon(f)).resizable().frame(width: 16, height: 16)
            if renaming == f.id {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .focused($renameFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { renaming = nil }
                    .onChange(of: renameFocused) { _, on in if !on { commitRename() } }
            } else {
                Text(f.name).lineLimit(1).truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var table: some View {
        Table(of: RemoteFile.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { f in nameCell(f) }
                .width(min: 160, ideal: 260)
            TableColumn("Date Modified", value: \.mtime) { f in
                Text(f.mtime.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Size", value: \.size) { f in
                Text(f.dir ? "--" : ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 56, ideal: 70)
            TableColumn("Kind", value: \.kind) { f in
                Text(f.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 70, ideal: 110)
        } rows: {
            ForEach(sorted) { f in
                TableRow(f)
                    .draggable(RemoteDrag.prefix + f.path)
                    .dropDestination(for: String.self) { items in _ = moveDropped(items, into: f) }
            }
        }
        .contextMenu(forSelectionType: RemoteFile.ID.self) { ids in
            actionItems(hub.items.filter { ids.contains($0.id) }, background: ids.isEmpty)
        } primaryAction: { ids in
            open(hub.items.filter { ids.contains($0.id) })
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard hub.writable, let dir = hub.location?.path, !files.isEmpty else { return false }
            hub.upload(files, to: dir)
            return true
        } isTargeted: { dropTargeted = $0 && hub.writable }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 3).padding(2).allowsHitTesting(false)
            } else if hub.items.isEmpty {
                ContentUnavailableView("Folder Is Empty", systemImage: "folder",
                                       description: Text(hub.writable ? "Drop files here to copy them to the phone." : ""))
            }
        }
    }
}

private struct InfoTarget: Identifiable {
    let path: String
    var id: String { path }
}

struct FileInfoSheet: View {
    let path: String
    @ObservedObject private var hub = FileHub.shared
    @Environment(\.dismiss) private var dismiss
    @State private var file: RemoteFile?
    @State private var created: Date?
    @State private var count: Int64?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: FileIcons.icon(file ?? RemoteFile(name: (path as NSString).lastPathComponent, path: path, dir: false, size: 0, mtime: Date())))
                    .resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file?.name ?? (path as NSString).lastPathComponent).font(.headline).lineLimit(2).truncationMode(.middle)
                    if let f = file { Text(sizeText(f)).foregroundStyle(.secondary) }
                }
            }
            Divider()
            if let error {
                Text(error).foregroundStyle(.secondary)
            } else if let f = file {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                    row("Kind:", f.kind)
                    row("Size:", sizeText(f))
                    row("Where:", hub.displayPath((f.path as NSString).deletingLastPathComponent))
                    if let created { row("Created:", created.formatted(date: .complete, time: .shortened)) }
                    row("Modified:", f.mtime.formatted(date: .complete, time: .shortened))
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .task {
            do {
                let r = try await hub.info(path, deep: true)
                file = r.0; created = r.created; count = r.count
            } catch {
                self.error = (error as? FileError)?.msg ?? error.localizedDescription
            }
        }
    }

    private func sizeText(_ f: RemoteFile) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file)
        if f.dir {
            guard let count else { return "Calculating size…" }
            return "\(bytes) for \(count) \(count == 1 ? "item" : "items")"
        }
        return "\(bytes) (\(f.size.formatted()) bytes)"
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).lineLimit(3)
        }
    }
}

struct MoveToSheet: View {
    let paths: [String]
    let start: FileLocation?
    @ObservedObject private var hub = FileHub.shared
    @Environment(\.dismiss) private var dismiss
    @State private var stack: [FileLocation] = []
    @State private var folders: [RemoteFile] = []
    @State private var loading = false
    @State private var error: String?

    private var current: FileLocation? { stack.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(paths.count == 1 ? "Move “\((paths[0] as NSString).lastPathComponent)” To:" : "Move \(paths.count) Items To:")
                .font(.headline)
            HStack(spacing: 6) {
                Button { stack.removeLast(); load() } label: { Image(systemName: "chevron.left") }
                    .disabled(stack.count <= 1)
                    .help("Back")
                Menu {
                    ForEach(Array(stack.enumerated().reversed()), id: \.offset) { i, l in
                        Button(l.name) { stack = Array(stack.prefix(i + 1)); load() }
                    }
                } label: {
                    Label(current?.name ?? "", systemImage: stack.count == 1 ? (current?.symbol ?? "folder") : "folder")
                }
                .fixedSize()
            }
            List(folders) { f in
                Button {
                    stack.append(FileLocation(name: f.name, path: f.path, symbol: "folder")); load()
                } label: {
                    HStack {
                        Image(nsImage: FileIcons.icon(f)).resizable().frame(width: 16, height: 16)
                        Text(f.name).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(paths.contains(f.path))
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 260)
            .overlay {
                if loading { ProgressView().controlSize(.small) }
                else if let error { Text(error).foregroundStyle(.secondary).padding() }
                else if folders.isEmpty { Text("No Folders").foregroundStyle(.secondary) }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move") {
                    if let c = current { hub.move(paths, into: c.path) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(current == nil || paths.allSatisfy { ($0 as NSString).deletingLastPathComponent == current?.path })
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            guard let s = start, let r = hub.roots.first(where: { s.path == $0.path || s.path.hasPrefix($0.path + "/") }) ?? hub.roots.first else { return }
            var st = [r]
            if s.path.hasPrefix(r.path + "/") {
                var p = r.path
                for c in s.path.dropFirst(r.path.count + 1).split(separator: "/") {
                    p += "/" + c
                    st.append(FileLocation(name: String(c), path: p, symbol: "folder"))
                }
            }
            stack = st
            load()
        }
    }

    private func load() {
        guard let c = current else { return }
        loading = true
        error = nil
        Task { @MainActor in
            do {
                let f = try await hub.folders(in: c.path)
                if current == c { folders = f }
            } catch {
                if current == c { folders = []; self.error = (error as? FileError)?.msg ?? error.localizedDescription }
            }
            if current == c { loading = false }
        }
    }
}

struct TransfersButton: View {
    @ObservedObject private var hub = FileHub.shared
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            Label("Transfers", systemImage: "arrow.up.arrow.down")
                .overlay(alignment: .bottomTrailing) {
                    if hub.activeCount > 0 {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7).offset(x: 3, y: 2)
                    }
                }
        }
        .help("Transfers")
        .disabled(hub.transfers.isEmpty)
        .popover(isPresented: $show, arrowEdge: .bottom) { TransfersList() }
    }
}

struct TransfersList: View {
    @ObservedObject private var hub = FileHub.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                Button("Clear") { hub.clearFinished() }
                    .buttonStyle(.link)
                    .disabled(hub.transfers.allSatisfy(\.isActive))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(hub.transfers) { t in
                        TransferRow(transfer: t)
                        if t.id != hub.transfers.last?.id { Divider().padding(.leading, 52) }
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 340)
    }
}

private struct TransferRow: View {
    @ObservedObject var transfer: Transfer

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: FileIcons.icon(name: transfer.name)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name).lineLimit(1).truncationMode(.middle)
                if transfer.isActive {
                    if transfer.total > 0 { ProgressView(value: transfer.fraction).controlSize(.small) }
                    else { ProgressView().progressViewStyle(.linear).controlSize(.small) }
                }
                Text(status).font(.caption).foregroundStyle(transfer.state == .failed ? .red : .secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if transfer.isActive {
                Button { FileHub.shared.cancel(transfer) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Stop")
            } else if transfer.state == .done, let url = transfer.url {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Show in Finder")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var status: String {
        let b = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        switch transfer.state {
        case .active:
            let dir = transfer.toPhone ? "To phone" : "From phone"
            return transfer.total > 0 ? "\(dir) · \(b(transfer.done)) of \(b(transfer.total))" : dir
        case .done: return transfer.toPhone ? "Copied to the phone" : "Saved in \(transfer.url?.deletingLastPathComponent().lastPathComponent ?? "Downloads")"
        case .cancelled: return "Stopped"
        case .failed: return transfer.error ?? "Failed"
        }
    }
}
