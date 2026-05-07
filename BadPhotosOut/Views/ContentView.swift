import SwiftUI

enum PermissionGateState {
    case notDetermined, denied
}

struct PermissionGateView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    let state: PermissionGateState

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Photos access needed")
                .font(.title2).bold()
            Text("BadPhotosOut reviews your photos with a local Ollama vision model.\nNothing leaves this Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            switch state {
            case .notDetermined:
                Button("Grant Photos Access") {
                    Task { await library.requestAuthorization() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            case .denied:
                VStack(spacing: 6) {
                    Text("Permission was denied. Open System Settings → Privacy & Security → Photos and enable BadPhotosOut.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 460)
                    Button("Recheck") {
                        library.refreshAuthorizationStatus()
                    }
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum GridFilter: String, CaseIterable, Identifiable {
    case all, flagged, kept, failed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"
        case .flagged: return "Flagged"
        case .kept: return "Kept"
        case .failed: return "Failed"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var coordinator: AnalysisCoordinator

    @State private var filter: GridFilter = .all
    @State private var detailItem: PhotoItem? = nil

    var body: some View {
        NavigationSplitView {
            SettingsView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 320, max: 380)
        } detail: {
            VStack(spacing: 0) {
                toolbar
                Divider()
                PhotoGridView(
                    photos: filteredPhotos,
                    onSelect: { detailItem = $0 }
                )
            }
        }
        .onAppear {
            coordinator.loadPhotos()
        }
        .sheet(item: $detailItem) { item in
            PhotoDetailView(item: item)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $filter) {
                ForEach(GridFilter.allCases) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)

            Spacer()

            if coordinator.isRunning {
                ProgressView(value: progressFraction)
                    .frame(width: 120)
                Text("\(coordinator.doneCount) / \(coordinator.totalCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text(summaryText)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var progressFraction: Double {
        guard coordinator.totalCount > 0 else { return 0 }
        return Double(coordinator.doneCount) / Double(coordinator.totalCount)
    }

    private var summaryText: String {
        if coordinator.totalCount == 0 { return "No photos in scope" }
        return "\(coordinator.totalCount) in scope · \(coordinator.flaggedCount) flagged · \(coordinator.failedCount) failed"
    }

    private var filteredPhotos: [PhotoItem] {
        coordinator.photos.filter { item in
            switch filter {
            case .all: return true
            case .flagged:
                if case .done(let r) = item.state { return !r.keep }
                return false
            case .kept:
                if case .done(let r) = item.state { return r.keep }
                return false
            case .failed:
                if case .failed = item.state { return true }
                return false
            }
        }
    }
}
