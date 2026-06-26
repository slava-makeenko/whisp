import SwiftUI
import SwiftData
import AppKit
import WhispCore

/// The "Files" sidebar tab: transcriptions of dropped audio/video files. Master list on the left,
/// detail (rename, transcript, attached file) on the right.
struct FileTranscriptionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FileTranscription.createdAt, order: .reverse) private var files: [FileTranscription]
    @State private var selection: FileTranscription.ID?

    private var selected: FileTranscription? { files.first { $0.id == selection } }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 300)
            Divider().overlay(Theme.hairline)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.windowBG)
        .onAppear { if selection == nil { selection = files.first?.id } }
        .onReceive(NotificationCenter.default.publisher(for: .whispOpenFiles)) { note in
            if let id = note.object as? UUID { selection = id }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ScreenHeader("Files").padding(.bottom, 6)
                if files.isEmpty {
                    Text("No file transcriptions yet.\nDrop audio or video on Home to transcribe it.")
                        .font(.geist(size: 13)).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(files) { file in
                        FileRow(file: file, selected: file.id == selection)
                            .contentShape(Rectangle())
                            .onTapGesture { selection = file.id }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.top, 28).padding(.bottom, 20)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.windowBG)
    }

    @ViewBuilder private var detail: some View {
        if let file = selected {
            FileDetail(file: file) { delete(file) }
        } else {
            Text("Select a transcription")
                .font(.geist(size: 14)).foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func delete(_ file: FileTranscription) {
        if let url = file.fileURL { try? FileManager.default.removeItem(at: url) }
        let nextID = files.first { $0.id != file.id }?.id
        modelContext.delete(file)
        try? modelContext.save()
        selection = nextID
    }
}

private struct FileRow: View {
    let file: FileTranscription
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(file.title.isEmpty ? file.originalName : file.title)
                .font(.geist(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText).lineLimit(1)
            Text(file.transcript)
                .font(.geist(size: 12)).foregroundStyle(Theme.secondaryText).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(selected ? Theme.selection : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
    }
}

private struct FileDetail: View {
    @Bindable var file: FileTranscription
    let onDelete: () -> Void
    @Environment(\.modelContext) private var modelContext
    @State private var isEditingTitle = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                attachedFile
                if file.transcript.isEmpty {
                    Text("No transcript.").font(.geist(size: 13)).foregroundStyle(Theme.secondaryText)
                } else {
                    TranscriptSummaryView(transcript: file.transcript, summary: $file.summary) {
                        try? modelContext.save()
                    }
                    Text(file.transcript)
                        .textSelection(.enabled)
                        .font(.geist(size: 14)).foregroundStyle(Theme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.windowBG)
        .id(file.id)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if isEditingTitle {
                        TextField("Title", text: $file.title)
                            .textFieldStyle(.plain)
                            .font(.geist(size: 20, weight: .semibold)).foregroundStyle(Theme.primaryText)
                            .focused($titleFocused)
                            .onSubmit(commitTitle)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
                                .stroke(Theme.accent, lineWidth: 1.5))
                        Button(action: commitTitle) {
                            Image(systemName: "checkmark.circle.fill").font(.geist(size: 17)).foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain).pointingCursor().help("Done")
                    } else {
                        Text(file.title.isEmpty ? file.originalName : file.title)
                            .font(.geist(size: 20, weight: .semibold)).foregroundStyle(Theme.primaryText)
                        Button { isEditingTitle = true } label: {
                            Image(systemName: "pencil").font(.geist(size: 13)).foregroundStyle(Theme.secondaryText)
                        }
                        .buttonStyle(.plain).pointingCursor().help("Rename")
                    }
                }
                Text(file.createdAt, format: .dateTime.day().month().year().hour().minute())
                    .font(.geist(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if !file.transcript.isEmpty {
                Button(action: copyTranscript) { Image(systemName: "doc.on.doc").font(.geist(size: 13)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).pointingCursor()
                    .help("Copy transcript")
            }
            Button(action: onDelete) { Image(systemName: "trash").font(.geist(size: 13)) }
                .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).pointingCursor()
                .help("Delete transcription")
        }
        .onChange(of: isEditingTitle) { _, editing in titleFocused = editing }
        .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
    }

    @ViewBuilder private var attachedFile: some View {
        if let url = file.fileURL, FileManager.default.fileExists(atPath: url.path) {
            HStack(spacing: 10) {
                Image(systemName: "paperclip").font(.geist(size: 13)).foregroundStyle(Theme.secondaryText)
                Text(file.originalName).font(.geist(size: 13)).foregroundStyle(Theme.primaryText).lineLimit(1)
                Spacer()
                Button("Open") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.plain).font(.geist(size: 12, weight: .medium)).foregroundStyle(Theme.accent).pointingCursor()
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.plain).font(.geist(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText).pointingCursor()
                Button { removeFile(url) } label: { Image(systemName: "xmark.circle").font(.geist(size: 13)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).pointingCursor().help("Remove attached file")
            }
            .padding(12)
            .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).stroke(Theme.hairline))
        } else if !file.storedFileName.isEmpty {
            // Stored name set but file missing on disk.
            Text("Attached file unavailable.").font(.geist(size: 12)).foregroundStyle(Theme.mutedText)
        }
    }

    private func commitTitle() {
        guard isEditingTitle else { return }
        isEditingTitle = false
        try? modelContext.save()
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.transcript, forType: .string)
    }

    private func removeFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        file.storedFileName = ""
        try? modelContext.save()
    }
}
