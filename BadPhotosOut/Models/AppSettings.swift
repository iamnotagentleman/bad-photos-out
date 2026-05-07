import Foundation
import SwiftUI

enum ScopeMode: String, CaseIterable, Identifiable {
    case lastNDays
    case dateRange
    case album
    case entireLibrary

    var id: String { rawValue }
    var label: String {
        switch self {
        case .lastNDays: return "Last N days"
        case .dateRange: return "Date range"
        case .album: return "Album"
        case .entireLibrary: return "Entire library"
        }
    }
}

enum ThinkingMode: String, CaseIterable, Identifiable {
    case off, on, low, medium, high

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .on: return "On"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var apiValue: Any? {
        switch self {
        case .off: return nil
        case .on: return true
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("ollamaURL") var ollamaURL: String = "http://localhost:11434"
    @AppStorage("modelName") var modelName: String = ""
    @AppStorage("userPrompt") var userPrompt: String = "blurry, dark, or accidental shots"
    @AppStorage("systemPrompt") var systemPrompt: String = OllamaClient.defaultPromptTemplate
    @AppStorage("concurrency") var concurrency: Int = 2
    @AppStorage("maxImageEdge") var maxImageEdge: Int = 768
    @AppStorage("requestTimeoutSeconds") var requestTimeoutSeconds: Int = 120
    @AppStorage("scopeMode") var scopeModeRaw: String = ScopeMode.lastNDays.rawValue
    @AppStorage("scopeDays") var scopeDays: Int = 30
    @AppStorage("scopeStartDate") var scopeStartDateRaw: Double = 0
    @AppStorage("scopeEndDate") var scopeEndDateRaw: Double = 0
    @AppStorage("scopeAlbumID") var scopeAlbumID: String = ""
    @AppStorage("skipScreenshots") var skipScreenshots: Bool = false
    @AppStorage("thinkingMode") var thinkingModeRaw: String = ThinkingMode.off.rawValue
    @AppStorage("flagWord") var flagWord: String = "flagged"

    var scopeMode: ScopeMode {
        get { ScopeMode(rawValue: scopeModeRaw) ?? .lastNDays }
        set { scopeModeRaw = newValue.rawValue }
    }

    var thinkingMode: ThinkingMode {
        get { ThinkingMode(rawValue: thinkingModeRaw) ?? .off }
        set { thinkingModeRaw = newValue.rawValue }
    }

    var scopeStartDate: Date {
        get {
            scopeStartDateRaw == 0
                ? Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
                : Date(timeIntervalSinceReferenceDate: scopeStartDateRaw)
        }
        set { scopeStartDateRaw = newValue.timeIntervalSinceReferenceDate }
    }

    var scopeEndDate: Date {
        get {
            scopeEndDateRaw == 0
                ? Date()
                : Date(timeIntervalSinceReferenceDate: scopeEndDateRaw)
        }
        set { scopeEndDateRaw = newValue.timeIntervalSinceReferenceDate }
    }

    var promptFingerprint: String {
        "\(modelName)|\(systemPrompt)|\(userPrompt)|\(flagWord)|\(maxImageEdge)|\(thinkingModeRaw)"
    }
}
