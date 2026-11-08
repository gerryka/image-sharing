import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ImgShareCore

let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

struct ImageFormatTests {
    @Test func detectsPng() {
        #expect(ImageFormat.detectMime(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == "image/png")
    }

    @Test func detectsJpeg() {
        #expect(ImageFormat.detectMime(Data([0xFF, 0xD8, 0xFF, 0xE0])) == "image/jpeg")
    }

    @Test func rejectsOthers() {
        #expect(ImageFormat.detectMime(Data("GIF89a".utf8)) == nil)
        #expect(ImageFormat.detectMime(Data([0xFF, 0xD8])) == nil)
        #expect(ImageFormat.detectMime(Data()) == nil)
    }

    @Test func safeFileName() {
        #expect(ImageFormat.safeFileName("../../etc/passwd.png", mime: "image/png") == "passwd.png")
        #expect(ImageFormat.safeFileName("..\\..\\x.png", mime: "image/png") == "x.png")
        #expect(ImageFormat.safeFileName("bild\u{202E}gnp.exe", mime: "image/jpeg") == "bildgnp.jpg")
        #expect(ImageFormat.safeFileName(nil, mime: "image/png") == "bild.png")
        #expect(ImageFormat.safeFileName("..png", mime: "image/png") == "bild.png")
        #expect(ImageFormat.safeFileName(String(repeating: "a", count: 200) + ".png", mime: "image/png")
            == String(repeating: "a", count: 80) + ".png")
    }

    @Test func formatSize() {
        #expect(ImageFormat.formatSize(500) == "500 B")
        #expect(ImageFormat.formatSize(2048) == "2 KB")
        #expect(ImageFormat.formatSize(1_572_864) == "1,5 MB")
    }

    @Test func dimensionsOfTinyPng() {
        let d = ImageFormat.dimensions(of: tinyPNG)
        #expect(d?.width == 1 && d?.height == 1)
        #expect(ImageFormat.dimensions(of: Data("nope".utf8)) == nil)
    }

    @Test func tiffToPng() throws {
        let src = CGImageSourceCreateWithData(tinyPNG as CFData, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        let out = NSMutableData()
        let dst = CGImageDestinationCreateWithData(out, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, img, nil)
        #expect(CGImageDestinationFinalize(dst))
        let png = try #require(ImageFormat.pngData(fromTIFF: out as Data))
        #expect(ImageFormat.detectMime(png) == "image/png")
    }

    @Test func limits() {
        #expect(ImageFormat.maxImageBytes == 25_165_824)
        #expect(ImageFormat.maxPixels == 100_000_000)
    }
}

struct ImageHeaderTests {
    @Test func pngDimensionsFromHeaderWithoutImageData() {
        let d = ImageFormat.dimensions(of: pngHeaderOnly(width: 20000, height: 30000))
        #expect(d?.width == 20000 && d?.height == 30000)
    }
}
