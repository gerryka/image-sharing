import AppKit
import ImgShareCore
import SwiftUI
import UniformTypeIdentifiers

/// Verweis auf ein Bild in einem Chat (Wert für das Bildfenster).
struct ImageRef: Codable, Hashable {
    let chatId: String
    let info: ImageInfo
}

struct ImageViewerView: View {
    let ref: ImageRef
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var data: Data?
    @State private var image: NSImage?
    @State private var error: String?
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    private var fileName: String { ImageFormat.safeFileName(ref.info.filename, mime: ref.info.mime) }

    var body: some View {
        Group {
            if let image {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: image.size.width * zoom * pinch, height: image.size.height * zoom * pinch)
                }
                .gesture(MagnifyGesture().updating($pinch) { v, s, _ in s = v.magnification }
                    .onEnded { v in zoom = max(0.1, min(8, zoom * v.magnification)) })
            } else if let error {
                ContentUnavailableView(error, systemImage: "photo.badge.exclamationmark")
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 320, minHeight: 240)
        .navigationTitle(fileName)
        .toolbar {
            Button { zoom = max(0.1, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-")
            Button { zoom = min(8, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("+")
            Button("Kopieren", systemImage: "doc.on.doc") { copy() }
                .keyboardShortcut("c").disabled(data == nil)
            Button("Sichern unter …", systemImage: "square.and.arrow.down") { save() }
                .keyboardShortcut("s").disabled(data == nil)
        }
        .onExitCommand { dismiss() }
        .task { await load() }
    }

    private func load() async {
        guard let s = model.sessions[ref.chatId] else { error = "Chat nicht verfügbar."; return }
        do {
            let d = try await s.imageData(for: ref.info)
            data = d
            image = NSImage(data: d)
            if let image, let screen = NSScreen.main?.visibleFrame.size {
                // Anfangs so verkleinern, dass das Bild auf den Bildschirm passt.
                zoom = min(1, (screen.width * 0.8) / image.size.width, (screen.height * 0.8) / image.size.height)
            }
        } catch {
            self.error = ErrorText.describe(error)
        }
    }

    private func copy() {
        guard let data else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let type: NSPasteboard.PasteboardType = ref.info.mime == "image/png" ? .png : NSPasteboard.PasteboardType(UTType.jpeg.identifier)
        pb.setData(data, forType: type)
        if let tiff = image?.tiffRepresentation { pb.setData(tiff, forType: .tiff) } // für Apps ohne PNG/JPEG
    }

    private func save() {
        guard let data else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [ref.info.mime == "image/png" ? .png : .jpeg]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) } catch { self.error = ErrorText.describe(error) }
    }
}
