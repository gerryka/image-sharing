import AppKit
import ImgShareCore
import SwiftUI

struct MessageRow: View {
    let message: ChatMessage
    let session: ChatSession
    let onOpenImage: (ImageInfo) -> Void

    private var isRead: Bool { message.isMine && message.id <= session.otherReadUpTo }

    var body: some View {
        HStack {
            if message.isMine { Spacer(minLength: 60) }
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 2) {
                if let image = message.image {
                    ImageThumb(info: image, session: session)
                        .onTapGesture { onOpenImage(image) }
                        .help(image.filename)
                } else if let text = message.text {
                    Text(Self.linkified(text))
                        .textSelection(.enabled)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(message.isMine ? Color.accentColor : Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(message.isMine ? Color.white : Color.primary)
                        .tint(message.isMine ? .white : .accentColor)
                }
                HStack(spacing: 4) {
                    Text(message.payload.sentAt, format: .dateTime.hour().minute())
                    if message.isMine {
                        Text(isRead ? "✓✓" : "✓").foregroundStyle(isRead ? Color.accentColor : .secondary)
                            .accessibilityLabel(isRead ? "gelesen" : "zugestellt")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if !message.isMine { Spacer(minLength: 60) }
        }
    }

    /// Nur erkannte Links werden klickbar – fremder Text wird nie als Markdown interpretiert.
    static func linkified(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return out }
        let ns = text as NSString
        for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = m.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""),
                  let r = Range(m.range, in: text),
                  let lower = AttributedString.Index(r.lowerBound, within: out),
                  let upper = AttributedString.Index(r.upperBound, within: out) else { continue }
            out[lower..<upper].link = url
            out[lower..<upper].underlineStyle = .single
        }
        return out
    }
}

/// Vorschau eines Bildes; lädt und entschlüsselt bei Bedarf.
struct ImageThumb: View {
    let info: ImageInfo
    let session: ChatSession
    @State private var image: NSImage?
    @State private var error: String?

    private var aspect: CGFloat {
        info.width > 0 && info.height > 0 ? CGFloat(info.width) / CGFloat(info.height) : 4 / 3
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else if let error {
                Label(error, systemImage: "photo.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: 320, maxHeight: 320)
        .aspectRatio(error == nil ? aspect : nil, contentMode: .fit)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Bild \(info.filename)")
        .task(id: info.blobId) {
            do {
                let data = try await session.imageData(for: info)
                // Nur eine verkleinerte Vorschau im Speicher halten (Originale bis 100 MP).
                let thumb = await Task.detached { ImageFormat.thumbnail(data, maxPixelSize: 640) }.value
                if let thumb {
                    image = NSImage(cgImage: thumb, size: NSSize(width: thumb.width / 2, height: thumb.height / 2))
                } else {
                    error = ImageError.invalidImage.message
                }
            } catch {
                self.error = ErrorText.describe(error)
            }
        }
    }
}
