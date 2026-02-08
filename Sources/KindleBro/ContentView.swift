import SwiftUI
import UniformTypeIdentifiers

private let sidebarTrailingColumnWidth: CGFloat = 30
private let sidebarTrailingColumnPadding: CGFloat = 8
private let sidebarHeaderTrailingInset: CGFloat = 12

struct ContentView: View {
    @EnvironmentObject var dbManager: DatabaseManager
    @Environment(\.openWindow) private var openWindow
    
    @State private var selectedBook: Book?
    @State private var searchText = ""
    @State private var showImportPicker = false
    @State private var documentToExport: SQLiteFile?
    @State private var selectedWordIds = Set<Word.ID>()
    @State private var toastMessage: String?
    @State private var bookSearchText = ""
    @State private var completedCollapsed = false
    @State private var booksCollapsed = false
    
    // Modify Prompt Feature
    @AppStorage("customPrompt") private var customPrompt = """
For a given set of words and usage samples, generate RemNote flashcards in the following format:

word>>3 most frequent translations, ordered by descending frequency, with the most frequent translation wrapped in **bold**. After the translations, add a usage sample enclosed in backticks (``). At least one translation must be derived from the provided usage. If a word has fewer than three frequent translations, list only the available ones.
Each flashcard must be on a new line. Do not add any text, comments, or explanations — output **only** the generated flashcards.

Example:
test>>**translation1**, translation2, translation3 `Usage example`
"""
    @State private var showPromptEditor = false
    
    // Settings
    @AppStorage("autoMasterOnCopy") private var autoMasterOnCopy = true
    @AppStorage("enableCompletedBooks") private var enableCompletedBooks = true
    @AppStorage("enableRelatedWords") private var enableRelatedWords = true
    @AppStorage("enableStemSearch") private var enableStemSearch = true
    
    // Session Restoration
    @AppStorage("lastSelectedBookId") private var lastSelectedBookId: String = ""
    
    // Search & Navigation Navigation State
    @State private var wordIdToSelectAfterBookChange: String? = nil
    @State private var navigatingFromSearch = false
    @State private var scrollRequest: UUID? = nil
    @State private var lastScrolledId: String? = nil
    @State private var searchTask: Task<Void, Never>?
    
    var body: some View {
        NavigationSplitView {
            sidebarView
        } detail: {
            detailView
        }
        .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.data]) { handleImport($0) }
        .fileExporter(isPresented: $dbManager.showExportPicker, document: documentToExport, contentType: .data, defaultFilename: "vocab.db") { handleExport($0) }
        .alert("Clear Database?", isPresented: $dbManager.showClearConfirmation) {
            Button("Clear", role: .destructive) { dbManager.clearDatabase() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Are you sure? This action can't be undone.") }
        .alert(isPresented: Binding(get: { dbManager.appError != nil }, set: { if !$0 { dbManager.appError = nil } })) {
            Alert(title: Text("Error"), message: Text(dbManager.appError?.localizedDescription ?? "Unknown Error"), dismissButton: .default(Text("OK")))
        }
        .onAppear { handleOnAppear() }
        .onChange(of: dbManager.isDatabaseLoaded) { _, newValue in
            if newValue { restoreLastSelectedBook() }
        }
        .onChange(of: dbManager.books) { _, _ in
            restoreLastSelectedBook()
        }
        .onChange(of: selectedBook) { _, _ in handleBookChange() }
        .onChange(of: searchText) { _, _ in handleSearchChange() }
        .onChange(of: customPrompt) { _, newValue in
            dbManager.saveSetting(key: "customPrompt", value: newValue)
        }
    }
    
    @ViewBuilder
    private var sidebarView: some View {
        List(selection: $selectedBook) {
            if enableCompletedBooks {
                let filtered = bookSearchText.isEmpty
                    ? dbManager.books
                    : dbManager.books.filter { $0.title.localizedCaseInsensitiveContains(bookSearchText) }
                let activeBooks = filtered.filter { !$0.isMastered }
                let completedBooks = filtered.filter { $0.isMastered }

                if !activeBooks.isEmpty {
                    Section {
                        if !booksCollapsed || !bookSearchText.isEmpty {
                            ForEach(activeBooks) { book in
                                NavigationLink(value: book) { BookRow(book: book) }
                            }
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Label("Books", systemImage: "books.vertical")
                            Spacer()
                            Text("\(activeBooks.count)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(minWidth: 18, alignment: .trailing)
                            Button(action: { booksCollapsed.toggle() }) {
                                Image(systemName: booksCollapsed ? "chevron.right" : "chevron.down")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(width: sidebarTrailingColumnWidth, alignment: .trailing)
                                    .padding(.trailing, sidebarTrailingColumnPadding)
                                    .padding(.vertical, 2)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!bookSearchText.isEmpty)
                            .help(bookSearchText.isEmpty
                                  ? (booksCollapsed ? "Show books" : "Hide books")
                                  : "Search is active")
                        }
                        .font(.title3)
                        .padding(.vertical, 10)
                        .padding(.trailing, sidebarHeaderTrailingInset)
                    }
                }

                if !completedBooks.isEmpty {
                    Section {
                        if !completedCollapsed || !bookSearchText.isEmpty {
                            ForEach(completedBooks) { book in
                                NavigationLink(value: book) { BookRow(book: book, showStrikethrough: false) }
                            }
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Label("Completed", systemImage: "checkmark.circle")
                            Spacer()
                            Text("\(completedBooks.count)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(minWidth: 18, alignment: .trailing)
                            Button(action: { completedCollapsed.toggle() }) {
                                Image(systemName: completedCollapsed ? "chevron.right" : "chevron.down")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(width: sidebarTrailingColumnWidth, alignment: .trailing)
                                    .padding(.trailing, sidebarTrailingColumnPadding)
                                    .padding(.vertical, 2)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!bookSearchText.isEmpty)
                            .help(bookSearchText.isEmpty
                                  ? (completedCollapsed ? "Show completed books" : "Hide completed books")
                                  : "Search is active")
                        }
                        .font(.title3)
                        .padding(.vertical, 10)
                        .padding(.trailing, sidebarHeaderTrailingInset)
                    }
                }
            } else {
                ForEach(bookSearchText.isEmpty ? dbManager.books : dbManager.books.filter { $0.title.localizedCaseInsensitiveContains(bookSearchText) }) { book in
                    NavigationLink(value: book) { BookRow(book: book) }
                }
            }
        }
        .searchable(text: $bookSearchText, placement: .sidebar, prompt: "Search Books")
        .navigationSplitViewColumnWidth(min: 200, ideal: 250)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: syncKindle) { Image(systemName: "arrow.triangle.2.circlepath") }.help("Sync Kindle")
                Button(action: { showImportPicker = true }) { Image(systemName: "square.and.arrow.down") }.help("Import DB")
            }
        }
    }
    
    @ViewBuilder
    private var detailView: some View {
        ZStack {
            if !dbManager.isDatabaseLoaded {
                ContentUnavailableView("Library Empty", systemImage: "books.vertical", description: Text("Import a vocab.db file to get started."))
                    .toolbar { Button("Import", action: { showImportPicker = true }) }
            } else {
                WordListView(
                    dbManager: dbManager,
                    selectedWordIds: $selectedWordIds,
                    searchText: searchText,
                    scrollRequest: $scrollRequest,
                    lastScrolledId: $lastScrolledId,
                    onStatusUpdate: { dbManager.updateStatus(word: $0, newStatus: $1, bulkIds: selectedWordIds) },
                    onToast: { showToast(message: $0, duration: $1) },
                    onBulkCopy: handleBulkCopy,
                    onJumpToWord: handleJumpToWord,
                    enableRelatedWords: enableRelatedWords,
                    onSelectAll: handleSelectAll,
                    onCopyAll: handleCopyAll
                )
                .navigationTitle(!searchText.isEmpty ? "Results" : (selectedBook?.title ?? "All Words"))
                .searchable(text: $searchText, prompt: "Search words or usage...")
                .toolbar {
                    ToolbarItem(placement: .status) { SelectionStatusView(count: selectedWordIds.count, onSelectAll: handleSelectAll, onCopyAll: handleCopyAll) }
                    ToolbarItem(placement: .automatic) {
                        ActionToolbar(
                            dbManager: dbManager,
                            hasSelection: !selectedWordIds.isEmpty,
                            onUndo: { dbManager.undoLastAction() },
                            onRefresh: refreshWords,
                            onPromptCopy: handlePromptCopy,
                            onGenerateFlashcards: handleGenerateFlashcards
                        )
                    }
                }
                .onChange(of: selectedWordIds) { oldValue, newValue in handleSelection(oldValue: oldValue, newValue: newValue) }
                .onChange(of: dbManager.words) { _, newWords in handleDataLoaded(newWords) }
                .onCopyCommand { handleCopyCommand() }
            }
            if let message = toastMessage { ToastView(message: message) }
        }
        .sheet(isPresented: $showPromptEditor) { PromptEditorView(prompt: $customPrompt) }
        .onChange(of: dbManager.showExportPicker) { _, newValue in handleExportTrigger(newValue) }
    }
    
    // MARK: - Handlers
    
    private func handleOnAppear() {
        if dbManager.isDatabaseLoaded {
            restoreLastSelectedBook()
            if let p = dbManager.getSetting(key: "customPrompt") { customPrompt = p }
            refreshWords()
        }
    }

    private func restoreLastSelectedBook() {
        if selectedBook == nil, !lastSelectedBookId.isEmpty {
            if let b = dbManager.books.first(where: { $0.id == lastSelectedBookId }) {
                selectedBook = b
            }
        }
    }
    
    private func handleImport(_ result: Result<URL, Error>) {
        if case .success(let url) = result {
            dbManager.importDatabase(from: url) { r in
                if case .success(let c) = r { showToast(message: "Imported. \(c) words added", duration: 4.0) }
            }
            if let p = dbManager.getSetting(key: "customPrompt") { customPrompt = p }
        }
    }
    
    private func handleExport(_ result: Result<URL, Error>) { if case .failure(let e) = result { print("Export failed: \(e)") } }
    
    private func handleExportTrigger(_ val: Bool) {
        if val {
            dbManager.saveSetting(key: "customPrompt", value: customPrompt)
            if let url = try? dbManager.getPersistentStoreURL(), let data = try? Data(contentsOf: url) { documentToExport = SQLiteFile(data: data) }
            else { dbManager.showExportPicker = false }
        }
    }

    private func handleBookChange() {
        if !navigatingFromSearch { searchText = "" }
        bookSearchText = "" // Clear book search on selection
        refreshWords()
        if wordIdToSelectAfterBookChange == nil { selectedWordIds.removeAll() }
        if let id = selectedBook?.id { lastSelectedBookId = id }
    }
    
    private func handleSearchChange() {
        if navigatingFromSearch { searchTask?.cancel(); return }
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { refreshWords(); selectedWordIds.removeAll() }
        }
    }

    private func handleSelection(oldValue: Set<Word.ID>, newValue: Set<Word.ID>) {
        if !navigatingFromSearch, !searchText.isEmpty, let f = newValue.first, oldValue != newValue {
            lastScrolledId = f; scrollRequest = UUID()
            bookSearchText = "" // Clear book search when jumping to a word
        }
        if !searchText.isEmpty && oldValue.isEmpty && newValue.count == 1, let sid = newValue.first {
            if let w = dbManager.words.first(where: { $0.id == sid }), let t = w.bookTitle, let b = dbManager.books.first(where: { $0.title == t }) {
                wordIdToSelectAfterBookChange = sid; navigatingFromSearch = true; searchText = ""
                if selectedBook == b { dbManager.fetchWords(for: b.id, search: "") } else { selectedBook = b }
            }
        }
    }
    
    private func handleDataLoaded(_ words: [Word]) {
        if let tid = wordIdToSelectAfterBookChange, words.contains(where: { $0.id == tid }) {
            // INSTANT STABILIZED SCROLL:
            // 1. Set selection immediately (triggering List update)
            selectedWordIds = [tid]
            lastScrolledId = tid
            
            // 2. Wait 50ms for List layout to stabilize, then trigger jump
            // This tiny delay ensures the List recognizes the target ID before we scroll
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                scrollRequest = UUID()
            }
            
            // 3. Clear the target
            wordIdToSelectAfterBookChange = nil
            
            // 4. Defer flag reset to prevent double-scroll
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                navigatingFromSearch = false
            }
        }
    }

    private func refreshWords() { dbManager.fetchWords(for: searchText.isEmpty ? selectedBook?.id : nil, search: searchText) }
    
    private func syncKindle() {
        let p = "/Volumes/Kindle/system/vocabulary/vocab.db"
        if FileManager.default.fileExists(atPath: p) {
            dbManager.importDatabase(from: URL(fileURLWithPath: p)) { r in
                if case .success(let c) = r { showToast(message: "Synced. \(c) words added", duration: 4.0) }
            }
        } else { showToast(message: "No device found", duration: 4.0) }
    }
    
    private func handleBulkCopy() {
        let t = dbManager.formatSelected(ids: selectedWordIds)
        if !t.isEmpty { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string); showToast(message: "Copied", duration: 2.5) }
    }
    
    private func handleCopyAll() {
        let t = dbManager.formatAllLearning()
        if !t.isEmpty {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(customPrompt)\n\n\(t)", forType: .string)
            showToast(message: "Copied all learning words", duration: 2.5)
            if autoMasterOnCopy { dbManager.masterAllLearning() }
        } else { showToast(message: "No words to copy", duration: 2.5) }
    }
    
    private func handleSelectAll() { selectedWordIds = Set(dbManager.words.filter { $0.status == .learning }.map { $0.id }) }
    
    private func handlePromptCopy() {
        let t = dbManager.formatSelected(ids: selectedWordIds)
        if !t.isEmpty {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(customPrompt)\n\n\(t)", forType: .string)
            showToast(message: "Copied with prompt", duration: 2.5)
            if autoMasterOnCopy { dbManager.masterSelected(ids: selectedWordIds) }
        }
    }
    
    private func handleGenerateFlashcards() {
        let t = dbManager.formatSelected(ids: selectedWordIds)
        if !t.isEmpty {
            openWindow(id: "generation", value: "\(customPrompt)\n\n\(t)")
            if autoMasterOnCopy { dbManager.masterSelected(ids: selectedWordIds) }
        }
    }

    private func handleJumpToWord(_ word: Word) {
        if dbManager.words.contains(where: { $0.id == word.id }) {
            selectedWordIds = [word.id]
            lastScrolledId = word.id
            scrollRequest = UUID()
            return
        }

        wordIdToSelectAfterBookChange = word.id
        navigatingFromSearch = true
        searchText = ""

        guard let title = word.bookTitle else { return }
        if let authors = word.bookAuthors,
           let book = dbManager.books.first(where: { $0.title == title && $0.authors == authors }) {
            selectedBook = book
        } else if let book = dbManager.books.first(where: { $0.title == title }) {
            selectedBook = book
        } else if let bookId = word.bookId {
            dbManager.fetchWords(for: bookId, search: "")
        }
    }
    
    private func handleCopyCommand() -> [NSItemProvider] {
        let t = dbManager.formatSelected(ids: selectedWordIds)
        if !t.isEmpty { showToast(message: "Copied", duration: 2.5); return [NSItemProvider(object: t as NSString)] }
        return []
    }

    private func showToast(message: String, duration: TimeInterval) {
        withAnimation { toastMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { withAnimation { if toastMessage == message { toastMessage = nil } } }
    }
}

// MARK: - Specialized Subviews

struct BookRow: View {
    let book: Book
    var showStrikethrough: Bool = true
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(book.title).lineLimit(1).strikethrough(showStrikethrough && book.isMastered)
                Text(book.authors).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text("\(book.wordCount)")
                .foregroundStyle(.secondary)
                .font(.caption)
                .frame(width: sidebarTrailingColumnWidth, alignment: .trailing)
                .padding(.trailing, sidebarTrailingColumnPadding)
        }
    }
}

struct WordListView: View {
    @ObservedObject var dbManager: DatabaseManager
    @Binding var selectedWordIds: Set<Word.ID>
    let searchText: String
    @Binding var scrollRequest: UUID?
    @Binding var lastScrolledId: String?
    
    let onStatusUpdate: (Word, WordStatus) -> Void
    let onToast: (String, TimeInterval) -> Void
    let onBulkCopy: () -> Void
    let onJumpToWord: (Word) -> Void
    let enableRelatedWords: Bool
    let onSelectAll: () -> Void
    let onCopyAll: () -> Void
    
    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selectedWordIds) {
                ForEach(dbManager.words) { word in
                    WordRow(
                        word: word,
                        onUpdateStatus: { onStatusUpdate(word, $0) },
                        onCopy: { onToast("Copied", 2.5) },
                        onContextCopy: onBulkCopy,
                        onSelectUsage: { dbManager.savePreferredUsage(wordId: word.databaseId, usage: $0) },
                        onSelectAll: onSelectAll,
                        onCopyAll: onCopyAll,
                        onJumpToWord: onJumpToWord,
                        enableRelatedWords: enableRelatedWords,
                        showBookTitle: !searchText.isEmpty,
                        dbManager: dbManager
                    ).tag(word.id).id(word.id)
                }
            }
            .onChange(of: scrollRequest) { _, newValue in
                if newValue != nil, let tid = lastScrolledId {
                    // INSTANT DIRECT SNAP:
                    // No animation, no delay (optimizing for speed).
                    // We rely on the 300ms pre-stabilization wait in handleDataLoaded 
                    // to ensure the list is ready.
                    proxy.scrollTo(tid, anchor: .center)
                }
            }
        }
    }
}

struct SelectionStatusView: View {
    let count: Int; let onSelectAll: () -> Void; let onCopyAll: () -> Void
    var body: some View {
        if count > 1 { Text("\(count) selected").foregroundStyle(.secondary).font(.caption).padding(.horizontal, 8) }
        else { HStack(spacing: 12) {
            Button(action: onSelectAll) { Image(systemName: "checklist") }.help("Select all Learning words")
            Button(action: onCopyAll) { Image(systemName: "doc.on.doc") }.help("Copy all Learning words")
        }}
    }
}

struct ActionToolbar: View {
    @ObservedObject var dbManager: DatabaseManager; let hasSelection: Bool
    let onUndo: () -> Void; let onRefresh: () -> Void; let onPromptCopy: () -> Void; let onGenerateFlashcards: () -> Void
    var body: some View {
        HStack {
            Button(action: onUndo) { Image(systemName: "arrow.uturn.backward") }.help("Undo").disabled(dbManager.undoStack.isEmpty)
            Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }.help("Refresh list")
            Button(action: onPromptCopy) { Image(systemName: "text.append") }.help("Copy with prompt").disabled(!hasSelection)
            Button(action: onGenerateFlashcards) { Image(systemName: "sparkles") }.help("Generate flashcards").disabled(!hasSelection)
        }
    }
}

struct ToastView: View {
    let message: String
    var body: some View { VStack { Spacer(); Text(message).font(.title2).padding(20).background(.regularMaterial).cornerRadius(12).shadow(radius: 8).padding(.bottom, 60).transition(.opacity) }.zIndex(1) }
}

struct SQLiteFile: FileDocument {
    static var readableContentTypes = [UTType.database, UTType.data]
    var data: Data?; init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { if let d = configuration.file.regularFileContents { self.data = d } }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { return FileWrapper(regularFileWithContents: data ?? Data()) }
}

extension DatabaseManager {
    func formatSelected(ids: Set<Word.ID>) -> String { words.filter { ids.contains($0.id) }.map { "\($0.text)\n\($0.usage ?? "")" }.joined(separator: "\n\n") }
    func formatAllLearning() -> String { words.filter { $0.status == .learning }.map { "\($0.text)\n\($0.usage ?? "")" }.joined(separator: "\n\n") }
    func masterAllLearning() { updateStatus(words: words.filter { $0.status == .learning }, newStatus: .mastered) }
    func masterSelected(ids: Set<Word.ID>) { updateStatus(words: words.filter { ids.contains($0.id) && $0.status != .mastered }, newStatus: .mastered) }
    func updateStatus(word: Word, newStatus: WordStatus, bulkIds: Set<Word.ID>) {
        if bulkIds.contains(word.id) { updateStatus(words: words.filter { bulkIds.contains($0.id) }, newStatus: newStatus) }
        else { updateStatus(word: word, newStatus: newStatus) }
    }
}
