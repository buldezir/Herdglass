import AppKit
import HerdrClient
import UniformTypeIdentifiers

typealias PaneUploadCompletion = @MainActor (Result<[String], Error>) -> Void
typealias PaneUploadHandler = (PaneUpload, @escaping PaneUploadCompletion) -> Void

@MainActor
enum TerminalClipboard {
    private static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, .init("public.jpeg"), .init("public.heic")]
    static func files(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    static func hasImage(_ pasteboard: NSPasteboard) -> Bool {
        let urls = files(from: pasteboard)
        if !urls.isEmpty {
            // Use the original image files, never Finder's preview thumbnails.
            return urls.allSatisfy { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        }
        return pasteboard.availableType(from: imageTypes) != nil
    }

    static func imageUpload(from pasteboard: NSPasteboard) -> PaneUpload? {
        guard hasImage(pasteboard) else { return nil }
        let urls = files(from: pasteboard)
        if !urls.isEmpty { return .files(urls) }
        return imagePNG(from: pasteboard).map { .image($0) }
    }

    static func imagePNG(from pasteboard: NSPasteboard) -> Data? {
        guard files(from: pasteboard).isEmpty, hasImage(pasteboard) else { return nil }
        if let png = pasteboard.data(forType: .png), NSBitmapImageRep(data: png) != nil { return png }
        for type in imageTypes where type != .png {
            if let data = pasteboard.data(forType: type), let bitmap = NSBitmapImageRep(data: data) {
                return bitmap.representation(using: .png, properties: [:])
            }
        }
        return nil
    }
}
