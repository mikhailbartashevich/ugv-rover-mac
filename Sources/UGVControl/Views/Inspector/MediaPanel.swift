import SwiftUI
import AppKit
import RoverKit

/// Photos and videos stored on the rover: browse, download, open, delete.
struct MediaPanel: View {
    @Environment(RoverClient.self) private var rover
    @Environment(MediaLibrary.self) private var library
    @StateObject private var state = MediaPanelState()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Kind", selection: $state.kind) {
                    Text("Photos (\(library.photos.count))").tag(MediaLibrary.Kind.photos)
                    Text("Videos (\(library.videos.count))").tag(MediaLibrary.Kind.videos)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Switch between photos and videos stored on the rover.")
                Button { Task { await refresh() } } label: {
                    if library.isLoading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
                .help("Reload the list of photos and videos from the rover.")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            content
        }
        .task { await refresh() }
        .onChange(of: rover.recordingSince) { _, _ in Task { try? await Task.sleep(for: .seconds(2)); await refresh() } }
        .sheet(item: $state.preview) { item in
            PhotoPreview(name: item.name, kind: .photos, onAction: perform)
        }
        .confirmationDialog("Delete “\(state.pendingDelete?.name ?? "")” from the rover?",
                            isPresented: Binding(get: { state.pendingDelete != nil }, set: { if !$0 { state.pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let item = state.pendingDelete { perform(.delete, item.name, item.kind) }
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    @ViewBuilder private var content: some View {
        let names = library.items(state.kind)
        if let base = rover.baseURL, !names.isEmpty {
            ScrollView {
                if state.kind == .photos {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                        ForEach(names, id: \.self) { name in
                            PhotoThumb(url: library.url(name, kind: .photos, base: base))
                                .onTapGesture { state.preview = MediaItem(name: name, kind: .photos) }
                                .contextMenu { menu(name, .photos) }
                                .help("\(name) — click to view large; right-click to open, download or delete.")
                        }
                    }
                    .padding(16)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(names, id: \.self) { name in
                            VideoRow(name: name) { perform($0, name, .videos) }
                                .contextMenu { menu(name, .videos) }
                            Divider()
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        } else {
            ContentUnavailableView {
                Label(state.kind == .photos ? "No Photos" : "No Videos",
                      systemImage: state.kind == .photos ? "photo" : "film")
            } description: {
                Text(library.error ?? "Use the camera and record buttons to capture on the rover.")
            }
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder private func menu(_ name: String, _ kind: MediaLibrary.Kind) -> some View {
        Button("Open", systemImage: "arrow.up.forward.app") { perform(.open, name, kind) }
        Button("Download", systemImage: "arrow.down.circle") { perform(.download, name, kind) }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { state.pendingDelete = MediaItem(name: name, kind: kind) }
    }

    private func refresh() async {
        if let base = rover.baseURL { await library.refresh(base: base) }
    }

    private func perform(_ action: MediaAction, _ name: String, _ kind: MediaLibrary.Kind) {
        guard let base = rover.baseURL else { return }
        Task {
            switch action {
            case .delete:
                state.preview = nil
                await library.delete(name, kind: kind, base: base)
                rover.show("Deleted \(name)", symbol: "trash")
            case .download, .open:
                do {
                    let file = try await library.download(name, kind: kind, base: base)
                    if action == .open {
                        NSWorkspace.shared.open(file)
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                        rover.show("Saved to Downloads › UGV Rover", symbol: "arrow.down.circle")
                    }
                } catch {
                    rover.show("Download failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
                }
            }
        }
    }
}

enum MediaAction { case open, download, delete }

struct MediaItem: Identifiable, Equatable {
    var id: String { "\(kind.rawValue)/\(name)" }
    let name: String
    let kind: MediaLibrary.Kind
}

@MainActor
final class MediaPanelState: ObservableObject {
    @Published var kind: MediaLibrary.Kind = .photos
    @Published var preview: MediaItem?
    @Published var pendingDelete: MediaItem?
}

private struct PhotoThumb: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill()
            case .failure: Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
            default: ProgressView().controlSize(.small)
            }
        }
        .frame(height: 78)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }
}

private struct VideoRow: View {
    let name: String
    let action: (MediaAction) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "film").foregroundStyle(.secondary)
            Text(name).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button { action(.open) } label: { Image(systemName: "play.fill") }
                .help("Download the video to Downloads › UGV Rover and open it in your default player.")
            Button { action(.download) } label: { Image(systemName: "arrow.down.circle") }
                .help("Download the video to Downloads › UGV Rover on this Mac and show it in Finder.")
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 8)
    }
}

private struct PhotoPreview: View {
    @Environment(RoverClient.self) private var rover
    @Environment(MediaLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let name: String
    let kind: MediaLibrary.Kind
    let onAction: (MediaAction, String, MediaLibrary.Kind) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let base = rover.baseURL {
                AsyncImage(url: library.url(name, kind: kind, base: base)) { img in
                    img.resizable().scaledToFit()
                } placeholder: {
                    ProgressView()
                }
                .frame(minWidth: 640, minHeight: 420)
                .background(.black)
            }
            HStack {
                Text(name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Delete…", role: .destructive) { onAction(.delete, name, kind); dismiss() }
                    .help("Delete this photo from the rover. This can't be undone.")
                Button("Download") { onAction(.download, name, kind) }
                    .help("Save the full-size photo to Downloads › UGV Rover and show it in Finder.")
                Button("Open in Preview") { onAction(.open, name, kind) }
                    .help("Download the photo and open it in Preview.")
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                    .help("Close the preview (Return).")
            }
            .padding(14)
        }
    }
}
