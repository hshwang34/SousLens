import Foundation
import UIKit

/// Turns a captured frame or a picked photo (JPEG/HEIC/PNG) into the upload the backend accepts:
/// JPEG, long edge ≤ 1600 px, ≤ 5 MB (PRD §14 "image downsampling", contract limit 5 MB).
/// Everything happens in memory; nothing is written to disk.
enum PantryImageEncoder {
    static let maxLongEdge: CGFloat = 1600
    /// 5 MB in decimal bytes: the stricter reading of the contract's "≤ 5 MB".
    static let maxBytes = 5_000_000

    enum EncodeError: Error, Equatable, LocalizedError {
        case unreadable
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .unreadable: return "That photo couldn’t be read. Try another one."
            case .tooLarge: return "That photo is too large to send even after shrinking it. Try another one."
            }
        }
    }

    /// Pure and synchronous; callers run it off the main actor (`encodeDetached`).
    static func encode(_ data: Data, maxLongEdge: CGFloat = maxLongEdge, maxBytes: Int = maxBytes) throws -> PantryPhotoUpload {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw EncodeError.unreadable
        }
        // `UIImage.size` is in points with EXIF orientation applied; scale 1 keeps px == pt.
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let target = targetSize(for: pixelSize, maxLongEdge: maxLongEdge)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            // Drawing applies the orientation, so the upload is upright with no EXIF dependency
            // (and carries no EXIF metadata such as location).
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        for quality in [0.8, 0.65, 0.5, 0.35, 0.2] as [CGFloat] {
            if let jpeg = rendered.jpegData(compressionQuality: quality), jpeg.count <= maxBytes {
                return PantryPhotoUpload(jpegData: jpeg, pixelWidth: Int(target.width), pixelHeight: Int(target.height))
            }
        }
        throw EncodeError.tooLarge
    }

    static func encodeDetached(_ data: Data) async throws -> PantryPhotoUpload {
        try await Task.detached(priority: .userInitiated) {
            try encode(data)
        }.value
    }

    /// Aspect-preserving, never upscales, whole pixels.
    static func targetSize(for size: CGSize, maxLongEdge: CGFloat) -> CGSize {
        let longEdge = max(size.width, size.height)
        guard longEdge > maxLongEdge else {
            return CGSize(width: size.width.rounded(), height: size.height.rounded())
        }
        let scale = maxLongEdge / longEdge
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }
}
