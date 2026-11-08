import ImgShareCore
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Bindable var vm: ChatViewModel
    @State private var showImporter = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            ForEach(vm.outgoing.items) { item in OutgoingRow(item: item, vm: vm) }
            if let p = vm.pendingImage { PendingImageView(picked: p, vm: vm) }
            if let err = vm.sendError {
                Text(err).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button { showImporter = true } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.borderless)
                    .help("Bild auswählen (PNG oder JPG)")
                TextField("Nachricht", text: $vm.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focused)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                    .onKeyPress(keys: [.return]) { press in
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                            vm.draft += "\n"
                        } else {
                            Task { await vm.sendText() }
                        }
                        return .handled
                    }
                Button { Task { await vm.sendText() } } label: { Image(systemName: "paperplane.fill") }
                    .buttonStyle(.borderless)
                    .disabled(vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isSendingText)
                    .help("Senden (Enter)")
            }
        }
        .padding(10)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.png, .jpeg]) { result in
            vm.pick(result.flatMap { url in Result { try PasteboardImage.read(fileURL: url) } })
        }
        .onAppear { focused = true }
    }
}

private struct PendingImageView: View {
    let picked: PasteboardImage.Picked
    let vm: ChatViewModel

    var body: some View {
        HStack {
            if let img = NSImage(data: picked.data) {
                Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: 80, maxHeight: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading) {
                Text(picked.fileName).lineLimit(1).truncationMode(.middle)
                Text(ImageFormat.formatSize(Int64(picked.data.count))).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Verwerfen") { vm.pendingImage = nil }
            Button("Senden") { vm.sendPendingImage() }.keyboardShortcut(.defaultAction)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct OutgoingRow: View {
    let item: OutgoingItem
    let vm: ChatViewModel

    var body: some View {
        HStack {
            Image(systemName: "photo")
            if let err = item.error {
                Text(err).foregroundStyle(.red).font(.caption)
                Spacer()
                Button("Verwerfen") { vm.outgoing.discard(item.id) }
                Button("Erneut senden") { vm.retry(item.id) }
            } else {
                ProgressView(value: item.progress).progressViewStyle(.linear)
                Text("Wird gesendet …").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
