import SwiftUI
import Photos

struct PhotoGridView: View {
    let photos: [PhotoItem]
    let onSelect: (PhotoItem) -> Void

    private let cellSize: CGFloat = 140
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cellSize), spacing: 6)]
    }

    var body: some View {
        if photos.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("No photos in this view")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(photos) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            PhotoCell(item: item, size: cellSize)
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                }
                .padding(8)
            }
        }
    }
}

private struct PhotoCell: View {
    @ObservedObject var item: PhotoItem
    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var settings: AppSettings
    let size: CGFloat
    @State private var thumbnail: NSImage? = nil
    @State private var showDebug: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(borderColor, lineWidth: 2)
            )

            BadgeDot(kind: item.state.badge)
                .padding(6)
        }
        .help(tooltip)
        .contextMenu {
            if isProcessed {
                Button("Show debug info") { showDebug = true }
            } else {
                Text("Not yet processed").foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showDebug) {
            DebugInfoView(
                item: item,
                prompt: OllamaClient.buildPrompt(
                    template: settings.systemPrompt,
                    criterion: settings.userPrompt,
                    flagWord: settings.flagWord
                ),
                model: settings.modelName,
                flagWord: settings.flagWord
            )
        }
        .task(id: item.id) {
            thumbnail = nil
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let target = CGSize(width: size * scale, height: size * scale)
            let img = await library.loadThumbnail(for: item.asset, size: target)
            if !Task.isCancelled {
                thumbnail = img
            }
        }
    }

    private var isProcessed: Bool {
        switch item.state {
        case .done, .failed: return true
        case .pending, .analyzing: return false
        }
    }

    private var borderColor: Color {
        switch item.state.badge {
        case .flagged: return .red.opacity(0.85)
        case .keep: return .green.opacity(0.6)
        case .failed: return .yellow.opacity(0.85)
        case .pending: return .clear
        }
    }

    private var tooltip: String {
        switch item.state {
        case .pending: return item.displayName
        case .analyzing: return "Analyzing \(item.displayName)…"
        case .done(let r): return r.reason
        case .failed(let e): return e
        }
    }
}

private struct DebugInfoView: View {
    @ObservedObject var item: PhotoItem
    let prompt: String
    let model: String
    let flagWord: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Debug info").font(.title3).bold()
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Text("\(item.displayName)  ·  model: \(model.isEmpty ? "—" : model)  ·  flag word: \"\(flagWord)\"")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            verdictBadge

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    label("Input prompt")
                    monospaced(prompt)

                    if let thinking = item.lastThinking, !thinking.isEmpty {
                        label("Reasoning trace")
                        monospaced(thinking)
                    }

                    label("Raw response")
                    monospaced(answerText)
                }
            }

            HStack {
                Button("Copy prompt") { copyToClipboard(prompt) }
                Button("Copy response") { copyToClipboard(answerText) }
                if let thinking = item.lastThinking, !thinking.isEmpty {
                    Button("Copy reasoning") { copyToClipboard(thinking) }
                }
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 640, height: 620)
    }

    @ViewBuilder
    private var verdictBadge: some View {
        switch item.state {
        case .done(let r):
            HStack(spacing: 6) {
                Circle().fill(r.keep ? .green : .red).frame(width: 10, height: 10)
                Text(r.keep ? "Kept (no flag word found)" : "Flagged (matched \"\(flagWord)\")")
                    .font(.subheadline)
            }
        case .failed:
            HStack(spacing: 6) {
                Circle().fill(.yellow).frame(width: 10, height: 10)
                Text("Failed").font(.subheadline)
            }
        case .pending, .analyzing:
            EmptyView()
        }
    }

    private var answerText: String {
        if let raw = item.lastRawResponse { return raw }
        switch item.state {
        case .done(let r): return r.reason
        case .failed(let e): return "ERROR\n\n\(e)"
        case .pending: return "Pending — not yet analyzed."
        case .analyzing: return "Analyzing…"
        }
    }

    @ViewBuilder
    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func monospaced(_ text: String) -> some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func copyToClipboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}

private struct BadgeDot: View {
    let kind: BadgeKind
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1))
            .shadow(radius: 1)
    }
    private var color: Color {
        switch kind {
        case .pending: return .gray
        case .keep: return .green
        case .flagged: return .red
        case .failed: return .yellow
        }
    }
}
