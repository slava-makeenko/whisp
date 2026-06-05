import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import WhispCore

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transcription.createdAt, order: .reverse) private var items: [Transcription]
    @State private var searchText = ""

    private var filtered: [Transcription] {
        searchText.isEmpty ? items : items.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    ScreenHeader("History")
                    Spacer()
                    Button("Export CSV", systemImage: "square.and.arrow.up", action: exportCSV)
                        .disabled(filtered.isEmpty)
                        .pointingCursor()
                }
                searchField
                if filtered.isEmpty {
                    CardSection {
                        Text("Nothing here yet.").foregroundStyle(Theme.secondaryText)
                    }
                } else {
                    CardSection {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().overlay(Theme.hairline) }
                            HistoryEntryRow(item: item) { delete(item) }
                        }
                    }
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 28).padding(.top, 32)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.windowBG)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondaryText)
            TextField("Search", text: $searchText).textFieldStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.cardBG, in: Capsule())
        .overlay(Capsule().stroke(Theme.hairline))
        .frame(maxWidth: 320)
    }

    private func delete(_ item: Transcription) {
        modelContext.delete(item)
        try? modelContext.save()
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "whisp-history.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }

    private var csv: String {
        let formatter = ISO8601DateFormatter()
        var rows = ["date,backend,app,words,text"]
        for item in filtered {
            let escaped = "\"" + item.text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            rows.append("\(formatter.string(from: item.createdAt)),\(item.backend),\(item.appBundleID ?? ""),\(item.wordCount),\(escaped)")
        }
        return rows.joined(separator: "\n")
    }
}

private struct HistoryEntryRow: View {
    let item: Transcription
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text).lineLimit(3).foregroundStyle(Theme.primaryText)
                HStack(spacing: 6) {
                    Text(item.createdAt, format: .dateTime.day().month().hour().minute())
                    Text("·")
                    Text(item.backend)
                }
                .font(.caption).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if hovering {
                Button { copy() } label: { Image(systemName: "doc.on.doc").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).pointingCursor()
                Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).pointingCursor()
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
    }
}
