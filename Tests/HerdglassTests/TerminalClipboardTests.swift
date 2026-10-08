import AppKit
import Testing
@testable import Herdglass

@Suite(.serialized)
@MainActor
struct TerminalClipboardTests {
    private func bitmap() throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.bitmapData)
        bytes.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        return bitmap
    }

    @Test func screenshotTIFFConvertsToPNGWithoutLosingDimensions() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let tiff = try bitmap().tiffRepresentation
        pasteboard.setData(tiff, forType: .tiff)
        #expect(TerminalClipboard.hasImage(pasteboard))
        let png = try #require(TerminalClipboard.imagePNG(from: pasteboard))
        #expect(Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        let image = try #require(NSBitmapImageRep(data: png))
        #expect(image.pixelsWide == 3)
        #expect(image.pixelsHigh == 2)
    }

    @Test func PNGClipboardKeepsOriginalDataEvenWhenTextIsAlsoAvailable() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let png = try #require(try bitmap().representation(using: .png, properties: [:]))
        pasteboard.setData(png, forType: .png)
        pasteboard.setString("alternate representation", forType: .string)
        #expect(TerminalClipboard.imagePNG(from: pasteboard) == png)
    }

    @Test func FinderFilesDoNotTurnTheirThumbnailsIntoPastedImages() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let file = URL(fileURLWithPath: "/tmp/file with spaces.pdf")
        pasteboard.writeObjects([file as NSURL])
        pasteboard.setData(try bitmap().tiffRepresentation, forType: .tiff)
        #expect(TerminalClipboard.files(from: pasteboard) == [file])
        #expect(!TerminalClipboard.hasImage(pasteboard))
        #expect(TerminalClipboard.imagePNG(from: pasteboard) == nil)
    }

    @Test func CopiedImageFilesUploadTheOriginalFiles() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let files = [URL(fileURLWithPath: "/tmp/first image.png"), URL(fileURLWithPath: "/tmp/second.jpeg")]
        pasteboard.writeObjects(files.map { $0 as NSURL })
        pasteboard.setData(try bitmap().tiffRepresentation, forType: .tiff)
        #expect(TerminalClipboard.hasImage(pasteboard))
        guard case .files(let uploaded) = TerminalClipboard.imageUpload(from: pasteboard) else {
            Issue.record("Expected original image file URLs")
            return
        }
        #expect(uploaded == files)
        #expect(TerminalClipboard.imagePNG(from: pasteboard) == nil)
    }

    @Test func PlainTextPasteRemainsTextAndInvalidImageDataIsRejected() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("hello", forType: .string)
        #expect(!TerminalClipboard.hasImage(pasteboard))
        #expect(TerminalClipboard.imagePNG(from: pasteboard) == nil)
        pasteboard.setData(Data([1, 2, 3]), forType: .png)
        #expect(TerminalClipboard.imagePNG(from: pasteboard) == nil)
    }
}
