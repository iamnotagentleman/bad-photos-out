import Foundation
import Photos

enum AnalysisState: Equatable {
    case pending
    case analyzing
    case done(AnalysisResult)
    case failed(String)

    var badge: BadgeKind {
        switch self {
        case .pending: return .pending
        case .analyzing: return .pending
        case .done(let r): return r.keep ? .keep : .flagged
        case .failed: return .failed
        }
    }
}

enum BadgeKind {
    case pending, keep, flagged, failed
}

@MainActor
final class PhotoItem: ObservableObject, Identifiable {
    let id: String
    let asset: PHAsset
    @Published var state: AnalysisState = .pending
    @Published var lastRawResponse: String? = nil
    @Published var lastThinking: String? = nil

    init(asset: PHAsset) {
        self.id = asset.localIdentifier
        self.asset = asset
    }

    var creationDate: Date? { asset.creationDate }

    var displayName: String {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first?.originalFilename ?? "asset \(id.prefix(8))"
    }
}
