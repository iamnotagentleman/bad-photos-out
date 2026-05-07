import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var coordinator: AnalysisCoordinator

    @State private var availableModels: [OllamaModelInfo] = []
    @State private var connectionStatus: ConnectionStatus = .unknown
    @State private var isTesting: Bool = false
    @State private var albums: [AlbumOption] = []
    @State private var modelCapabilities: Set<String> = []

    private let client = OllamaClient()

    enum ConnectionStatus: Equatable {
        case unknown
        case ok(Int)
        case failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    section("Ollama") {
                        LabeledField("Endpoint") {
                            TextField("http://localhost:11434", text: $settings.ollamaURL)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledField("Model") {
                            HStack {
                                if availableModels.isEmpty {
                                    TextField("e.g. llava:latest", text: $settings.modelName)
                                        .textFieldStyle(.roundedBorder)
                                } else {
                                    Picker("", selection: $settings.modelName) {
                                        Text("Select a model").tag("")
                                        ForEach(availableModels) { m in
                                            Text(m.name).tag(m.name)
                                        }
                                    }
                                    .labelsHidden()
                                }
                            }
                        }
                        HStack {
                            Button(action: testConnection) {
                                if isTesting {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Test connection")
                                }
                            }
                            .disabled(isTesting)
                            connectionStatusView
                        }
                        capabilityBadges
                        if modelCapabilities.contains("thinking") {
                            LabeledField("Thinking") {
                                Picker("", selection: Binding(
                                    get: { settings.thinkingMode },
                                    set: { settings.thinkingMode = $0 }
                                )) {
                                    ForEach(ThinkingMode.allCases) { mode in
                                        Text(mode.label).tag(mode)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                            }
                            Text("Reasoning trace runs before the JSON answer. Higher levels are slower; bump request timeout if needed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if !settings.modelName.isEmpty && !modelCapabilities.isEmpty && settings.thinkingMode != .off {
                            Label("This model doesn't support thinking; the setting will be ignored.", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    section("Criterion") {
                        Text("Describe what makes a photo unnecessary.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $settings.userPrompt)
                            .font(.body)
                            .frame(minHeight: 80)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))

                        LabeledField("Flag word") {
                            TextField("flagged", text: $settings.flagWord)
                                .textFieldStyle(.roundedBorder)
                        }
                        Text("If the model's reply contains this word (case-insensitive), the photo is flagged.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    section("System prompt") {
                        HStack {
                            Text("Placeholders: {criterion} and {flag_word} are substituted before sending.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Reset to default") {
                                settings.systemPrompt = OllamaClient.defaultPromptTemplate
                            }
                            .controlSize(.small)
                            .disabled(settings.systemPrompt == OllamaClient.defaultPromptTemplate)
                        }
                        TextEditor(text: $settings.systemPrompt)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 140)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                        if !settings.systemPrompt.contains("{criterion}") {
                            Label("Template is missing {criterion} — the criterion won't be sent.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if !settings.systemPrompt.contains("{flag_word}") {
                            Label("Template is missing {flag_word} — the model won't know what word to use to flag.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    section("Scope") {
                        Picker("", selection: Binding(
                            get: { settings.scopeMode },
                            set: { settings.scopeMode = $0 }
                        )) {
                            ForEach(ScopeMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.radioGroup)

                        if settings.scopeMode == .lastNDays {
                            let daysBinding = Binding<Int>(
                                get: { settings.scopeDays },
                                set: { settings.scopeDays = max(1, min(3650, $0)) }
                            )
                            HStack(spacing: 6) {
                                TextField("Days", value: daysBinding, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 70)
                                Stepper("days", value: daysBinding, in: 1...3650)
                            }
                        } else if settings.scopeMode == .dateRange {
                            let startBinding = Binding<Date>(
                                get: { settings.scopeStartDate },
                                set: {
                                    settings.scopeStartDate = $0
                                    if settings.scopeEndDate < $0 { settings.scopeEndDate = $0 }
                                }
                            )
                            let endBinding = Binding<Date>(
                                get: { settings.scopeEndDate },
                                set: { settings.scopeEndDate = max($0, settings.scopeStartDate) }
                            )
                            VStack(alignment: .leading, spacing: 6) {
                                DatePicker("From", selection: startBinding, in: ...Date(), displayedComponents: [.date])
                                DatePicker("To", selection: endBinding, in: settings.scopeStartDate...Date(), displayedComponents: [.date])
                            }
                        } else if settings.scopeMode == .album {
                            Picker("Album", selection: $settings.scopeAlbumID) {
                                Text("Select an album").tag("")
                                ForEach(albums) { album in
                                    Text(album.title).tag(album.id)
                                }
                            }
                            .onAppear { albums = library.fetchAlbums() }
                        }

                        Toggle("Skip screenshots", isOn: $settings.skipScreenshots)
                    }

                    section("Performance") {
                        LabeledField("Concurrency") {
                            Stepper("\(settings.concurrency)", value: $settings.concurrency, in: 1...8)
                        }
                        LabeledField("Max image edge") {
                            Stepper("\(settings.maxImageEdge) px", value: $settings.maxImageEdge, in: 256...2048, step: 64)
                        }
                        LabeledField("Request timeout") {
                            Stepper("\(settings.requestTimeoutSeconds)s", value: $settings.requestTimeoutSeconds, in: 10...600, step: 10)
                        }
                    }
                }
                .disabled(coordinator.isRunning)
                .opacity(coordinator.isRunning ? 0.55 : 1)

                Divider()

                runControls

                if let err = coordinator.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
        }
        .onAppear {
            albums = library.fetchAlbums()
            Task { await refreshModels() }
        }
        .onChange(of: settings.ollamaURL) { _, _ in
            Task { await refreshModels() }
        }
        .onChange(of: settings.scopeMode) { _, _ in coordinator.loadPhotos() }
        .onChange(of: settings.scopeDays) { _, _ in coordinator.loadPhotos() }
        .onChange(of: settings.scopeStartDateRaw) { _, _ in coordinator.loadPhotos() }
        .onChange(of: settings.scopeEndDateRaw) { _, _ in coordinator.loadPhotos() }
        .onChange(of: settings.scopeAlbumID) { _, _ in coordinator.loadPhotos() }
        .onChange(of: settings.skipScreenshots) { _, _ in coordinator.loadPhotos() }
        .onChange(of: settings.userPrompt) { _, _ in coordinator.loadPhotos() }
        .onChange(of: settings.systemPrompt) { _, _ in coordinator.loadPhotos() }
        .onChange(of: settings.flagWord) { _, _ in coordinator.loadPhotos() }
        .onChange(of: settings.modelName) { _, _ in
            coordinator.loadPhotos()
            Task { await refreshCapabilities() }
        }
        .onChange(of: settings.thinkingMode) { _, _ in coordinator.loadPhotos() }
        .onChange(of: settings.maxImageEdge) { _, _ in coordinator.loadPhotos() }
    }

    @ViewBuilder
    private var capabilityBadges: some View {
        if !settings.modelName.isEmpty {
            HStack(spacing: 6) {
                if modelCapabilities.isEmpty {
                    Text("capabilities: —")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(orderedCapabilityList(), id: \.self) { cap in
                        Text(cap)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.18))
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    private func orderedCapabilityList() -> [String] {
        let preferred = ["completion", "vision", "thinking", "tools", "embedding", "insert"]
        let known = preferred.filter { modelCapabilities.contains($0) }
        let extras = modelCapabilities.subtracting(known).sorted()
        return known + extras
    }

    private var runControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if coordinator.isRunning {
                    Button(role: .destructive, action: { coordinator.cancel() }) {
                        Label("Cancel", systemImage: "stop.fill")
                    }
                } else {
                    Button(action: { coordinator.start() }) {
                        Label("Start analysis", systemImage: "play.fill")
                    }
                    .keyboardShortcut("r")
                    .disabled(coordinator.totalCount == 0)
                }
                Spacer()
                Button(action: { coordinator.loadPhotos() }) {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .help("Re-fetch photos in scope")
                .disabled(coordinator.isRunning)
            }
            if coordinator.isRunning, coordinator.totalCount > 0 {
                ProgressView(value: Double(coordinator.doneCount), total: Double(coordinator.totalCount))
                Text("\(coordinator.doneCount) / \(coordinator.totalCount) · \(coordinator.flaggedCount) flagged")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var connectionStatusView: some View {
        switch connectionStatus {
        case .unknown:
            EmptyView()
        case .ok(let count):
            Label("\(count) models", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(2)
        }
    }

    private func testConnection() {
        Task { await refreshModels(force: true) }
    }

    private func refreshModels(force: Bool = false) async {
        if force { isTesting = true }
        defer { if force { isTesting = false } }
        do {
            let models = try await client.listModels(baseURL: settings.ollamaURL)
            availableModels = models
            connectionStatus = .ok(models.count)
            if settings.modelName.isEmpty, let first = models.first {
                settings.modelName = first.name
            }
            await refreshCapabilities()
        } catch {
            availableModels = []
            connectionStatus = .failed(error.localizedDescription)
            modelCapabilities = []
        }
    }

    private func refreshCapabilities() async {
        guard !settings.modelName.isEmpty else {
            modelCapabilities = []
            return
        }
        do {
            modelCapabilities = try await client.capabilities(
                baseURL: settings.ollamaURL,
                model: settings.modelName
            )
        } catch {
            modelCapabilities = []
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
    }
}

private struct LabeledField<Content: View>: View {
    let label: String
    let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content
        }
    }
}
