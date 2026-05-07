import SwiftUI

@main
struct BadPhotosOutApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var library: PhotoLibraryService
    @StateObject private var coordinator: AnalysisCoordinator

    init() {
        let s = AppSettings()
        let lib = PhotoLibraryService()
        let coord = AnalysisCoordinator(library: lib, client: OllamaClient(), settings: s)
        _settings = StateObject(wrappedValue: s)
        _library = StateObject(wrappedValue: lib)
        _coordinator = StateObject(wrappedValue: coord)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(library)
                .environmentObject(coordinator)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
    }
}

struct RootView: View {
    @EnvironmentObject private var library: PhotoLibraryService

    var body: some View {
        Group {
            switch library.authorization {
            case .authorized, .limited:
                ContentView()
            case .denied, .restricted:
                PermissionGateView(state: .denied)
            case .notDetermined:
                PermissionGateView(state: .notDetermined)
            @unknown default:
                PermissionGateView(state: .notDetermined)
            }
        }
        .onAppear { library.refreshAuthorizationStatus() }
    }
}
