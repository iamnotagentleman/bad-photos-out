import SwiftUI
import AppKit

struct PhotoDetailView: View {
    @ObservedObject var item: PhotoItem
    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var coordinator: AnalysisCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var preview: NSImage? = nil

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Group {
                if let img = preview {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.1))
                        .overlay(ProgressView())
                }
            }
            .frame(maxWidth: 720, maxHeight: 480)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            stateLabel

            if case .done(let r) = item.state {
                Text("\u{201C}\(r.reason)\u{201D}")
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: 600)
            } else if case .failed(let e) = item.state {
                Text(e)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: 600)
            }

            Text(metadataLine)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button(action: revealInPhotos) {
                    Label("Reveal in Photos", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .help("Open Photos.app and copy filename to clipboard so you can locate this photo.")

                Button(action: { coordinator.reanalyze(item) }) {
                    Label("Re-analyze", systemImage: "arrow.clockwise")
                }
                .disabled(coordinator.isRunning)
            }
            .padding(.bottom, 16)
        }
        .frame(minWidth: 600, minHeight: 540)
        .task(id: item.id) {
            preview = await library.loadFullImage(for: item.asset)
        }
    }

    private var stateLabel: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(badgeColor)
                .frame(width: 10, height: 10)
            Text(stateText).font(.headline)
        }
    }

    private var badgeColor: Color {
        switch item.state.badge {
        case .keep: return .green
        case .flagged: return .red
        case .failed: return .yellow
        case .pending: return .gray
        }
    }

    private var stateText: String {
        switch item.state {
        case .pending: return "Pending"
        case .analyzing: return "Analyzing…"
        case .done(let r): return r.keep ? "Kept" : "Flagged"
        case .failed: return "Failed"
        }
    }

    private var metadataLine: String {
        let date = item.creationDate.map { Self.dateFormatter.string(from: $0) } ?? "no date"
        return "\(item.displayName) · \(date) · \(item.id.prefix(8))"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func revealInPhotos() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.displayName, forType: .string)
        if let url = URL(string: "photos://") {
            NSWorkspace.shared.open(url)
        }
    }
}
