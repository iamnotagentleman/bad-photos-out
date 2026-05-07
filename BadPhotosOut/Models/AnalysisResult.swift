import Foundation

struct AnalysisResult: Codable, Hashable, Sendable {
    let keep: Bool
    let reason: String
}
