import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The notes chosen for "Append cards to .md note". "notePath" is the current one; "notePaths" lists
// every note chosen so far, one path per line, so @AppStorage can watch it.
enum NoteList {
    static var paths: [String] {
        get { (UserDefaults.standard.string(forKey: "notePaths") ?? "").split(separator: "\n").map(String.init) }
        set { UserDefaults.standard.set(newValue.joined(separator: "\n"), forKey: "notePaths") }
    }

    // ".../Eng/2026.md"
    static func shortName(_ path: String) -> String {
        ".../" + URL(fileURLWithPath: path).pathComponents.suffix(2).joined(separator: "/")
    }

    // Asks for a note, adds it to the list and makes it the current one. Nil when cancelled.
    @MainActor static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.message = "Choose the Markdown note to add flashcards to"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let path = panel.url?.path else { return nil }
        if !paths.contains(path) { paths.append(path) }
        UserDefaults.standard.set(path, forKey: "notePath")
        return path
    }

    // Takes the note off the list (the file stays). The current note moves to the first one left.
    static func remove(_ path: String) {
        paths.removeAll { $0 == path }
        if UserDefaults.standard.string(forKey: "notePath") == path {
            UserDefaults.standard.set(paths.first ?? "", forKey: "notePath")
        }
    }
}

// The current note as ".../Eng/2026.md"; opens the list to switch, remove or choose another note.
struct NoteMenu: View {
    @AppStorage("notePath") private var notePath = ""
    @AppStorage("notePaths") private var notePaths = "" // watched so the list redraws after a change
    @State private var isOpen = false
    @State private var confirmingRemoval: String?

    var body: some View {
        if !notePath.isEmpty {
            Button { isOpen.toggle() } label: {
                HStack(spacing: 4) {
                    Text(NoteList.shortName(notePath))
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .help(notePath)
            .popover(isPresented: $isOpen, arrowEdge: .bottom) { list }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(NoteList.paths, id: \.self) { path in
                HStack(spacing: 6) {
                    Button { notePath = path; isOpen = false } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark").opacity(path == notePath ? 1 : 0)
                            Text(NoteList.shortName(path))
                            Spacer(minLength: 0)
                        }
                        .modifier(HoverHighlight())
                    }
                    .buttonStyle(.plain)
                    .help(path)

                    if confirmingRemoval == path {
                        Text("Remove from the list?").foregroundStyle(.secondary)
                        Button("Remove", role: .destructive) { NoteList.remove(path); confirmingRemoval = nil }
                        Button("Cancel") { confirmingRemoval = nil }
                    } else {
                        Button { confirmingRemoval = path } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help("Remove from the list. The note itself stays.")
                    }
                }
            }
            Divider().padding(.vertical, 4)
            Button {
                isOpen = false
                DispatchQueue.main.async { _ = NoteList.choose() } // once the popover is gone
            } label: {
                Text("Select new…").frame(maxWidth: .infinity, alignment: .leading).modifier(HoverHighlight())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(minWidth: 260)
    }
}

// Shows the note with the cards in place before anything is written.
struct NoteAppendSheet: View {
    let cards: [(book: String, card: String)]
    let path: String
    let onAdded: () -> Void

    @AppStorage("noteAddHeadings") private var withHeadings = true
    @AppStorage("noteAddAtTop") private var atTop = true
    @State private var noteText: String?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private var block: String { MarkdownNote.block(cards, withHeadings: withHeadings) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Append \(cards.count) \(cards.count == 1 ? "flashcard" : "flashcards") to \(URL(fileURLWithPath: path).lastPathComponent)")
                    .font(.headline)
                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Toggle("Add book title heading", isOn: $withHeadings).toggleStyle(.checkbox)
                Spacer()
                Picker("Add", selection: $atTop) {
                    Text("At the top").tag(true)
                    Text("At the bottom").tag(false)
                }
                .fixedSize()
            }
            ScrollView {
                Text(preview)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            if let error {
                Text(error).foregroundStyle(.red).lineLimit(3)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Append", action: append)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(noteText == nil)
            }
        }
        .padding(20)
        .frame(width: 680, height: 540)
        .onAppear {
            do { noteText = try MarkdownNote.read(URL(fileURLWithPath: path)) } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // A few lines of the note around the new text, which is highlighted.
    private var preview: AttributedString {
        let parts = MarkdownNote.insertion(of: block, into: noteText ?? "", atTop: atTop)
        func lines(_ text: Substring) -> [Substring] {
            text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        }
        let beforeLines = lines(parts.before), afterLines = lines(parts.after), shown = 6
        var before = AttributedString(beforeLines.count > shown + 1
                                      ? "…\n" + beforeLines.suffix(shown + 1).joined(separator: "\n") : String(parts.before))
        var added = AttributedString(parts.added)
        var after = AttributedString(afterLines.count > shown + 1
                                     ? afterLines.prefix(shown).joined(separator: "\n") + "\n…" : String(parts.after))
        before.foregroundColor = .secondary
        after.foregroundColor = .secondary
        added.backgroundColor = Color.accentColor.opacity(0.18)
        return before + added + after
    }

    private func append() {
        do {
            try MarkdownNote.add(block, to: URL(fileURLWithPath: path), atTop: atTop)
            onAdded()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
