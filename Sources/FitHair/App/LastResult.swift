import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Everything needed to come back to the latest measurement after quitting. The classification isn't
/// kept: it is worked out again from the measurement.
struct LastResult: Codable, Equatable {
    var measurement: FaceMeasurement
    var colourProfile: ColourProfile?
    var shape: FaceShape
    var shapeConfirmed: Bool
    var fromCamera: Bool
    var shadeID: String
}

/// Keeps the latest photo and its measurement in the app's own folder on this Mac; nothing leaves it.
struct LastResultStore: Sendable {
    let directory: URL

    private var resultURL: URL { directory.appendingPathComponent("result.json") }
    private var photoURL: URL { directory.appendingPathComponent("photo.jpg") }

    static var onDisk: LastResultStore? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .map { LastResultStore(directory: $0.appendingPathComponent("Plinth/LastResult", isDirectory: true)) }
    }

    /// A nil photo keeps the one already saved (the shape or colour changed, not the picture).
    func save(_ result: LastResult, photo: CGImage?) {
        guard let json = try? JSONEncoder().encode(result) else { return }
        let manager = FileManager.default
        guard (try? manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])) != nil else { return }
        if let photo {
            guard let jpeg = Self.jpeg(photo), (try? jpeg.write(to: photoURL, options: .atomic)) != nil else { return }
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: photoURL.path)
        }
        try? json.write(to: resultURL, options: .atomic)
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resultURL.path)
    }

    func load() -> LastResult? {
        guard let data = try? Data(contentsOf: resultURL) else { return nil }
        return try? JSONDecoder().decode(LastResult.self, from: data)
    }

    /// Nil unless the picture is still the size the saved points were measured on.
    func loadPhoto(matching size: CGSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              CGFloat(image.width) == size.width, CGFloat(image.height) == size.height else { return nil }
        return image
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
