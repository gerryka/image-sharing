import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// QR-Code des Schlüssels (Fehlerkorrektur M, wie der Windows-Client).
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let img = Self.image(for: text) {
            Image(decorative: img, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityLabel("QR-Code des Schlüssels")
        }
    }

    static func image(for text: String) -> CGImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(out, from: out.extent)
    }
}
