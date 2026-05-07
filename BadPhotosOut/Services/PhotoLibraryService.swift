import Foundation
import Photos
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum PhotoServiceError: LocalizedError {
    case notAuthorized
    case imageDataUnavailable
    case downscaleFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Photos access not granted."
        case .imageDataUnavailable: return "Photos returned no image data for this asset."
        case .downscaleFailed: return "Could not generate a downscaled JPEG."
        }
    }
}

struct AlbumOption: Identifiable, Hashable {
    let id: String
    let title: String
}

@MainActor
final class PhotoLibraryService: ObservableObject {
    @Published private(set) var authorization: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    private let thumbnailManager = PHCachingImageManager()
    private let fullManager = PHImageManager.default()

    func refreshAuthorizationStatus() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        self.authorization = status
    }

    var isAuthorized: Bool {
        authorization == .authorized || authorization == .limited
    }

    func fetchAlbums() -> [AlbumOption] {
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var albums: [AlbumOption] = []
        result.enumerateObjects { collection, _, _ in
            albums.append(AlbumOption(id: collection.localIdentifier, title: collection.localizedTitle ?? "Untitled"))
        }
        return albums.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func fetchAssets(
        scope: ScopeMode,
        days: Int,
        startDate: Date,
        endDate: Date,
        albumID: String,
        skipScreenshots: Bool
    ) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        var predicates: [NSPredicate] = [NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)]
        if scope == .lastNDays {
            let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
            predicates.append(NSPredicate(format: "creationDate >= %@", cutoff as NSDate))
        } else if scope == .dateRange {
            let dayStart = Calendar.current.startOfDay(for: startDate)
            let dayAfterEnd = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: endDate)) ?? endDate
            predicates.append(NSPredicate(format: "creationDate >= %@ AND creationDate < %@", dayStart as NSDate, dayAfterEnd as NSDate))
        }
        if skipScreenshots {
            let mask = PHAssetMediaSubtype.photoScreenshot.rawValue
            predicates.append(NSPredicate(format: "(mediaSubtypes & %d) == 0", mask))
        }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)

        if scope == .album, !albumID.isEmpty {
            let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil)
            guard let collection = collections.firstObject else { return [] }
            let result = PHAsset.fetchAssets(in: collection, options: options)
            return result.objects(at: IndexSet(integersIn: 0..<result.count))
        }

        let result = PHAsset.fetchAssets(with: .image, options: options)
        return result.objects(at: IndexSet(integersIn: 0..<result.count))
    }

    func loadThumbnail(for asset: PHAsset, size: CGSize) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            options.resizeMode = .fast
            thumbnailManager.requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !isDegraded {
                    continuation.resume(returning: image)
                }
            }
        }
    }

    func loadFullImage(for asset: PHAsset) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false
            fullManager.requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !isDegraded {
                    continuation.resume(returning: image)
                }
            }
        }
    }

    func deleteAssets(_ assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }

    func loadDownscaledJPEG(for asset: PHAsset, maxEdge: Int) async throws -> Data {
        let originalData: Data = try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.version = .current
            fullManager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data else {
                    continuation.resume(throwing: PhotoServiceError.imageDataUnavailable)
                    return
                }
                continuation.resume(returning: data)
            }
        }

        guard let source = CGImageSourceCreateWithData(originalData as CFData, nil) else {
            throw PhotoServiceError.downscaleFailed
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            throw PhotoServiceError.downscaleFailed
        }
        guard let opaque = Self.flattenedToOpaqueRGB(cgImage) else {
            throw PhotoServiceError.downscaleFailed
        }
        let outputData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(outputData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PhotoServiceError.downscaleFailed
        }
        CGImageDestinationAddImage(dest, opaque, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw PhotoServiceError.downscaleFailed
        }
        return outputData as Data
    }

    private static func flattenedToOpaqueRGB(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
