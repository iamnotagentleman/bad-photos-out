import Foundation
import Photos
import CryptoKit
import Combine

@MainActor
final class AnalysisCoordinator: ObservableObject {
    @Published private(set) var photos: [PhotoItem] = []
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var startedAt: Date? = nil
    @Published private(set) var lastError: String? = nil

    private let library: PhotoLibraryService
    private let client: OllamaClient
    private let settings: AppSettings
    private var cache: AnalysisCache
    private var runTask: Task<Void, Never>? = nil
    private var itemSubscriptions: [AnyCancellable] = []

    init(library: PhotoLibraryService, client: OllamaClient, settings: AppSettings) {
        self.library = library
        self.client = client
        self.settings = settings
        self.cache = AnalysisCache.load()
    }

    var totalCount: Int { photos.count }
    var doneCount: Int {
        photos.reduce(into: 0) { acc, item in
            if case .done = item.state { acc += 1 }
            else if case .failed = item.state { acc += 1 }
        }
    }
    var flaggedCount: Int {
        photos.reduce(into: 0) { acc, item in
            if case .done(let r) = item.state, !r.keep { acc += 1 }
        }
    }
    var failedCount: Int {
        photos.reduce(into: 0) { acc, item in
            if case .failed = item.state { acc += 1 }
        }
    }

    func loadPhotos() {
        let assets = library.fetchAssets(
            scope: settings.scopeMode,
            days: settings.scopeDays,
            albumID: settings.scopeAlbumID,
            skipScreenshots: settings.skipScreenshots
        )
        let fingerprint = settings.promptFingerprint
        let newItems: [PhotoItem] = assets.map { asset in
            let item = PhotoItem(asset: asset)
            if let cached = cache.lookup(assetID: asset.localIdentifier, fingerprint: fingerprint) {
                item.state = .done(cached)
            }
            return item
        }
        photos = newItems
        subscribe(to: newItems)
    }

    private func subscribe(to items: [PhotoItem]) {
        itemSubscriptions = items.map { item in
            item.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }

    func start() {
        guard !isRunning else { return }
        guard !settings.modelName.isEmpty else {
            lastError = "Pick a model in Settings before starting."
            return
        }
        guard !settings.userPrompt.trimmingCharacters(in: .whitespaces).isEmpty else {
            lastError = "Enter a criterion in Settings before starting."
            return
        }
        lastError = nil
        isRunning = true
        startedAt = Date()
        let snapshot = photos
        let fingerprint = settings.promptFingerprint
        runTask = Task { [weak self] in
            await self?.runAnalysis(items: snapshot, fingerprint: fingerprint)
            await MainActor.run { [weak self] in
                self?.isRunning = false
            }
        }
    }

    func cancel() {
        runTask?.cancel()
        isRunning = false
    }

    func reanalyze(_ item: PhotoItem) {
        guard !isRunning else { return }
        item.state = .pending
        let fingerprint = settings.promptFingerprint
        cache.remove(assetID: item.id, fingerprint: fingerprint)
        cache.persist()
        isRunning = true
        runTask = Task { [weak self] in
            await self?.runAnalysis(items: [item], fingerprint: fingerprint)
            await MainActor.run { [weak self] in
                self?.isRunning = false
            }
        }
    }

    private func runAnalysis(items: [PhotoItem], fingerprint: String) async {
        let concurrency = max(1, settings.concurrency)
        let model = settings.modelName
        let baseURL = settings.ollamaURL
        let flagWord = settings.flagWord
        let prompt = OllamaClient.buildPrompt(
            template: settings.systemPrompt,
            criterion: settings.userPrompt,
            flagWord: flagWord
        )
        let maxEdge = settings.maxImageEdge
        let timeout = TimeInterval(settings.requestTimeoutSeconds)
        let thinking = settings.thinkingMode

        let pending = items.filter { item in
            if case .pending = item.state { return true }
            return false
        }

        await withTaskGroup(of: Void.self) { group in
            var iterator = pending.makeIterator()
            var inFlight = 0

            func startNext() {
                guard let next = iterator.next() else { return }
                inFlight += 1
                group.addTask { [weak self] in
                    await self?.process(
                        item: next,
                        baseURL: baseURL,
                        model: model,
                        prompt: prompt,
                        maxEdge: maxEdge,
                        timeout: timeout,
                        thinking: thinking,
                        flagWord: flagWord,
                        fingerprint: fingerprint
                    )
                }
            }

            for _ in 0..<concurrency { startNext() }

            while inFlight > 0 {
                await group.next()
                inFlight -= 1
                if Task.isCancelled { break }
                startNext()
            }
        }

        await MainActor.run {
            self.cache.persist()
        }

        let unloadClient = client
        Task.detached(priority: .utility) {
            await unloadClient.unload(baseURL: baseURL, model: model)
        }
    }

    private func process(
        item: PhotoItem,
        baseURL: String,
        model: String,
        prompt: String,
        maxEdge: Int,
        timeout: TimeInterval,
        thinking: ThinkingMode,
        flagWord: String,
        fingerprint: String
    ) async {
        if Task.isCancelled { return }
        await MainActor.run {
            item.state = .analyzing
            item.lastRawResponse = nil
            item.lastThinking = nil
        }

        let asset = await MainActor.run { item.asset }
        let assetID = await MainActor.run { item.id }

        do {
            let jpeg = try await library.loadDownscaledJPEG(for: asset, maxEdge: maxEdge)
            let outcome = try await client.analyze(
                baseURL: baseURL,
                model: model,
                prompt: prompt,
                imageJPEG: jpeg,
                timeout: timeout,
                thinking: thinking,
                flagWord: flagWord
            )
            await MainActor.run {
                item.state = .done(outcome.result)
                item.lastRawResponse = outcome.rawResponse
                item.lastThinking = outcome.thinking
                self.cache.store(assetID: assetID, fingerprint: fingerprint, result: outcome.result)
            }
        } catch {
            await MainActor.run {
                item.state = .failed(error.localizedDescription)
            }
        }
    }
}

private struct CachedEntry: Codable {
    let key: String
    let result: AnalysisResult
}

@MainActor
final class AnalysisCache {
    private var entries: [String: AnalysisResult]
    private let url: URL

    private init(entries: [String: AnalysisResult], url: URL) {
        self.entries = entries
        self.url = url
    }

    static func load() -> AnalysisCache {
        let url = Self.cacheFileURL()
        let entries: [String: AnalysisResult]
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: AnalysisResult].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
        return AnalysisCache(entries: entries, url: url)
    }

    func lookup(assetID: String, fingerprint: String) -> AnalysisResult? {
        entries[Self.key(assetID: assetID, fingerprint: fingerprint)]
    }

    func store(assetID: String, fingerprint: String, result: AnalysisResult) {
        entries[Self.key(assetID: assetID, fingerprint: fingerprint)] = result
    }

    func remove(assetID: String, fingerprint: String) {
        entries.removeValue(forKey: Self.key(assetID: assetID, fingerprint: fingerprint))
    }

    func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func key(assetID: String, fingerprint: String) -> String {
        let raw = "\(assetID)|\(fingerprint)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func cacheFileURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("BadPhotosOut/cache.json")
    }
}
