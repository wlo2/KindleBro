import SwiftUI
import UniformTypeIdentifiers

private let sidebarTrailingColumnWidth: CGFloat = 56
private let sidebarTrailingColumnPadding: CGFloat = 8
private let sidebarHeaderTrailingInset: CGFloat = 12

struct ContentView: View {
    @EnvironmentObject var dbManager: DatabaseManager
    
    // By id: Book values change whenever their counts do, which would drop a value-based selection.
    @State private var selectedBookId: Book.ID?
    @State private var searchText = ""
    @State private var selectedWordIds = Set<Word.ID>()
    @State private var toastMessage: String?
    @State private var bookSearchText = ""
    @State private var completedCollapsed = false
    @State private var booksCollapsed = false
    
    // Modify Prompt Feature
    @AppStorage("customPrompt") private var customPrompt = defaultPrompt
    
    // Settings
    @AppStorage("autoMasterOnCopy") private var autoMasterOnCopy = true
    @AppStorage("enableCompletedBooks") private var enableCompletedBooks = true
    @AppStorage("enableRelatedWords") private var enableRelatedWords = true
    @AppStorage("enableStemSearch") private var enableStemSearch = true
    @AppStorage("learningBatchSize") private var learningBatchSize = 15
    
    // Session Restoration
    @AppStorage("lastSelectedBookId") private var lastSelectedBookId: String = ""
    
    // Search & Navigation Navigation State
    @State private var wordIdToSelectAfterBookChange: String? = nil
    @State private var navigatingFromSearch = false
    // Hides the list while a jump loads another book, so it appears already scrolled to the word.
    @State private var hideListForJump = false
    @State private var scrollRequest: UUID? = nil
    @State private var lastScrolledId: String? = nil
    @State private var searchTask: Task<Void, Never>?
    
    private var selectedBook: Book? { dbManager.books.first { $0.id == selectedBookId } }
    
    var body: some View {
        NavigationSplitView {
            sidebarView
        } detail: {
            detailView
        }
        .fileImporter(isPresented: $dbManager.showImportPicker, allowedContentTypes: [.data]) { handleImport($0) }
        .fileExporter(isPresented: $dbManager.showExportPicker, document: SQLiteFile(), contentType: .data, defaultFilename: "vocab.db") { handleExport($0) }
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
        .onChange(of: selectedBookId) { _, _ in handleBookChange() }
        .onChange(of: searchText) { _, _ in handleSearchChange() }
        .onChange(of: selectedWordIds) { oldValue, newValue in
            handleSelection(oldValue: oldValue, newValue: newValue)
        }
        .onChange(of: dbManager.words) { _, newValue in
            handleDataLoaded(newValue)
        }
        // Both settings change what the word query returns
        .onChange(of: enableRelatedWords) { _, _ in refreshWords() }
        .onChange(of: enableStemSearch) { _, _ in refreshWords() }
    }
    
    @ViewBuilder
    private var sidebarView: some View {
        List(selection: $selectedBookId) {
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
                                NavigationLink(value: book.id) { BookRow(book: book) }
                            }
                        }
                    } header: {
                        sectionHeader("Books", icon: "books.vertical", count: activeBooks.count, collapsed: $booksCollapsed)
                    }
                    .collapsible(false) // we draw our own chevron; the system one shifted the header on hover
                }

                if !completedBooks.isEmpty {
                    Section {
                        if !completedCollapsed || !bookSearchText.isEmpty {
                            ForEach(completedBooks) { book in
                                NavigationLink(value: book.id) { BookRow(book: book, showStrikethrough: false) }
                            }
                        }
                    } header: {
                        sectionHeader("Completed", icon: "checkmark.circle", count: completedBooks.count, collapsed: $completedCollapsed)
                    }
                    .collapsible(false) // we draw our own chevron; the system one shifted the header on hover
                }
            } else {
                ForEach(bookSearchText.isEmpty ? dbManager.books : dbManager.books.filter { $0.title.localizedCaseInsensitiveContains(bookSearchText) }) { book in
                    NavigationLink(value: book.id) { BookRow(book: book) }
                }
            }
        }
        .searchable(text: $bookSearchText, placement: .sidebar, prompt: "Search Books")
        .navigationSplitViewColumnWidth(min: 200, ideal: 250)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: syncKindle) { Label("Sync Kindle", systemImage: "arrow.triangle.2.circlepath") }.help("Sync Kindle")
            }
        }
    }
    
    private func sectionHeader(_ title: String, icon: String, count: Int, collapsed: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: icon)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(minWidth: 18, alignment: .trailing)
            Button(action: { collapsed.wrappedValue.toggle() }) {
                Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down")
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
                  ? "\(collapsed.wrappedValue ? "Show" : "Hide") \(title.lowercased())"
                  : "Search is active")
        }
        .font(.title3)
        .padding(.vertical, 10)
        .padding(.trailing, sidebarHeaderTrailingInset)
    }
    
    @ViewBuilder
    private var detailView: some View {
        DetailViewContent(
            dbManager: dbManager,
            selectedBook: selectedBook,
            searchText: $searchText,
            selectedWordIds: $selectedWordIds,
            scrollRequest: $scrollRequest,
            lastScrolledId: $lastScrolledId,
            toastMessage: toastMessage,
            hideList: hideListForJump,
            enableRelatedWords: enableRelatedWords,
            onImport: { dbManager.showImportPicker = true },
            onStatusUpdate: { dbManager.updateStatus(word: $0, newStatus: $1, bulkIds: selectedWordIds) },
            onToast: { showToast(message: $0, duration: $1) },
            onBulkCopy: handleBulkCopy,
            onJumpToWord: handleJumpToWord,
            onSelectBatch: handleSelectLearningBatch,
            onSelectAll: handleSelectAll,
            onCopyAll: handleCopyAll,
            onUndo: { dbManager.undoLastAction() },
            onRefresh: refreshWords,
            onPromptCopy: handlePromptCopy,
            onArrowKeyUpdate: handleArrowKeyStatusUpdate
        )
    }
    
    // MARK: - Handlers
    
    private func handleArrowKeyStatusUpdate(to targetStatus: WordStatus) {
        guard !selectedWordIds.isEmpty else { return }
        let selectedWords = dbManager.words.filter { selectedWordIds.contains($0.id) }
        guard !selectedWords.isEmpty else { return }
        
        // Right Arrow (target .mastered): .learning -> .mastered, .ignored -> .learning
        // Left Arrow (target .ignored): .learning -> .ignored, .mastered -> .learning
        // One batch call so Undo reverts the whole key press.
        let changes: [(word: Word, status: WordStatus)] = selectedWords.compactMap { word in
            switch (targetStatus, word.status) {
            case (.mastered, .learning): return (word, .mastered)
            case (.mastered, .ignored), (.ignored, .mastered): return (word, .learning)
            case (.ignored, .learning): return (word, .ignored)
            default: return nil
            }
        }
        guard !changes.isEmpty else { return }
        dbManager.updateStatuses(changes)
        
        showToast(message: "Status toggled for \(changes.count) \(changes.count == 1 ? "word" : "words")", duration: 1.5)
    }
    
    private func handleOnAppear() {
        if let backupError = UserDefaults.standard.string(forKey: "lastBackupError") {
            UserDefaults.standard.removeObject(forKey: "lastBackupError")
            dbManager.appError = .backupError("The backup on last quit failed: \(backupError)")
        }
        if dbManager.isDatabaseLoaded {
            restoreLastSelectedBook()
            if let p = dbManager.getSetting(key: "customPrompt") { customPrompt = p }
            refreshWords()
        }
    }

    private func restoreLastSelectedBook() {
        if selectedBookId == nil, dbManager.books.contains(where: { $0.id == lastSelectedBookId }) {
            selectedBookId = lastSelectedBookId
        }
    }
    
    private func handleImport(_ result: Result<URL, Error>) {
        if case .success(let url) = result { importLibrary(from: url, toast: "Imported") }
    }
    
    // Shared by Import and Sync. Failures are shown by DatabaseManager as an alert.
    private func importLibrary(from url: URL, toast: String) {
        dbManager.importDatabase(from: url) { r in
            guard case .success(let c) = r else { return }
            showToast(message: "\(toast). \(c) words added", duration: 4.0)
            if let p = dbManager.getSetting(key: "customPrompt") { customPrompt = p }
            refreshWords() // new words for the open book
        }
    }
    
    private func handleExport(_ result: Result<URL, Error>) {
        if case .failure(let e) = result, (e as? CocoaError)?.code != .userCancelled {
            dbManager.appError = .dbError("Export failed: \(e.localizedDescription)")
        }
    }
    

    private func handleBookChange() {
        if !navigatingFromSearch { searchText = "" }
        bookSearchText = "" // Clear book search on selection
        refreshWords()
        if wordIdToSelectAfterBookChange == nil { selectedWordIds.removeAll() }
        if let selectedBookId { lastSelectedBookId = selectedBookId }
    }
    
    private func handleSearchChange() {
        if navigatingFromSearch { searchTask?.cancel(); return }
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { refreshWords(); selectedWordIds.removeAll() }
        }
    }

    private func handleSelection(oldValue: Set<Word.ID>, newValue: Set<Word.ID>) {
        if !navigatingFromSearch, !searchText.isEmpty, let f = newValue.first, oldValue != newValue {
            lastScrolledId = f; scrollRequest = UUID()
            bookSearchText = "" // Clear book search when jumping to a word
        }
        if !searchText.isEmpty && oldValue.isEmpty && newValue.count == 1, let sid = newValue.first,
           let w = dbManager.words.first(where: { $0.id == sid }) {
            navigateToBook(of: w)
        }
    }
    
    private func handleDataLoaded(_ words: [Word]) {
        guard let tid = wordIdToSelectAfterBookChange else { return }
        if words.contains(where: { $0.id == tid }) {
            // INSTANT STABILIZED SCROLL:
            // 1. Set selection immediately (triggering List update)
            selectedWordIds = [tid]
            lastScrolledId = tid
            
            // 2. Scroll on the next main-loop turn: the List has its new rows by then.
            // (Was a fixed 50 ms wait; the list is hidden meanwhile, so that wait was pure delay.)
            DispatchQueue.main.async {
                scrollRequest = UUID()
                hideListForJump = false // same update as the scroll
            }
        } else {
            hideListForJump = false
        }
        // Clear the target even when the word is missing, so search never stays blocked.
        wordIdToSelectAfterBookChange = nil
        // Defer flag reset to prevent double-scroll
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            navigatingFromSearch = false
            // Run any search typed while input was muted
            if !searchText.isEmpty { handleSearchChange() }
        }
    }

    private func refreshWords() { dbManager.fetchWords(for: searchText.isEmpty ? selectedBookId : nil, search: searchText) }
    
    private func syncKindle() {
        let p = "/Volumes/Kindle/system/vocabulary/vocab.db"
        if FileManager.default.fileExists(atPath: p) {
            importLibrary(from: URL(fileURLWithPath: p), toast: "Synced")
        } else { showToast(message: "No device found", duration: 4.0) }
    }
    
    private func handleBulkCopy() {
        let t = dbManager.formatSelected(ids: selectedWordIds)
        if !t.isEmpty { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string); showToast(message: "Copied", duration: 2.5) }
    }
    
    private func handleCopyAll() {
        let count = dbManager.words.filter { $0.status == .learning }.count
        let t = dbManager.formatAllLearning()
        if !t.isEmpty {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(customPrompt)\n\n\(t)", forType: .string)
            // The list is capped for "All Words" and search, so say how many were actually copied.
            showToast(message: "Copied \(count) learning \(count == 1 ? "word" : "words")", duration: 2.5)
            if autoMasterOnCopy { dbManager.masterAllLearning() }
        } else { showToast(message: "No words to copy", duration: 2.5) }
    }

    private func handleSelectLearningBatch() {
        let batchSize = max(1, learningBatchSize)
        let ids = dbManager.learningWordIds(limit: batchSize)
        if !ids.isEmpty {
            selectedWordIds = Set(ids)
        } else {
            showToast(message: "No words to select", duration: 2.5)
        }
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
    
    private func handleJumpToWord(_ word: Word) {
        if dbManager.words.contains(where: { $0.id == word.id }) {
            selectedWordIds = [word.id]
            lastScrolledId = word.id
            scrollRequest = UUID()
            return
        }
        navigateToBook(of: word)
    }

    private func navigateToBook(of word: Word) {
        wordIdToSelectAfterBookChange = word.id
        navigatingFromSearch = true
        hideListForJump = true
        // Never leave the list hidden if the book load fails
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { hideListForJump = false }
        searchText = ""

        // Match title + authors: different books can share a title.
        let book = dbManager.books.first(where: { $0.title == word.bookTitle && $0.authors == word.bookAuthors })
        if let book, book.id != selectedBookId {
            selectedBookId = book.id
        } else if let bookId = book?.id ?? word.bookId {
            // Same book: selection does not change, so reload directly
            dbManager.fetchWords(for: bookId, search: "")
        }
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
            Text(book.sidebarCountText)
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
                        onSelectUsage: { dbManager.savePreferredUsage(for: word, usage: $0) },
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
                    // No animation: handleDataLoaded triggers this once the List has the target row.
                    proxy.scrollTo(tid, anchor: .center)
                }
            }
        }
    }
}

struct DetailViewContent: View {
    @ObservedObject var dbManager: DatabaseManager
    let selectedBook: Book?
    @Binding var searchText: String
    @Binding var selectedWordIds: Set<Word.ID>
    @Binding var scrollRequest: UUID?
    @Binding var lastScrolledId: String?
    let toastMessage: String?
    let hideList: Bool
    let enableRelatedWords: Bool
    
    let onImport: () -> Void
    let onStatusUpdate: (Word, WordStatus) -> Void
    let onToast: (String, TimeInterval) -> Void
    let onBulkCopy: () -> Void
    let onJumpToWord: (Word) -> Void
    let onSelectBatch: () -> Void
    let onSelectAll: () -> Void
    let onCopyAll: () -> Void
    let onUndo: () -> Void
    let onRefresh: () -> Void
    let onPromptCopy: () -> Void
    let onArrowKeyUpdate: (WordStatus) -> Void

    var body: some View {
        ZStack {
            if !dbManager.isDatabaseLoaded {
                ContentUnavailableView("Library Empty", systemImage: "books.vertical", description: Text("Import a vocab.db file to get started."))
                    .toolbar { Button("Import", action: onImport) }
            } else {
                WordListView(
                    dbManager: dbManager,
                    selectedWordIds: $selectedWordIds,
                    searchText: searchText,
                    scrollRequest: $scrollRequest,
                    lastScrolledId: $lastScrolledId,
                    onStatusUpdate: onStatusUpdate,
                    onToast: onToast,
                    onBulkCopy: onBulkCopy,
                    onJumpToWord: onJumpToWord,
                    enableRelatedWords: enableRelatedWords,
                    onSelectAll: onSelectAll,
                    onCopyAll: onCopyAll
                )
                .opacity(hideList ? 0 : 1)
                .navigationTitle(!searchText.isEmpty ? "Results" : (selectedBook?.title ?? "All Words"))
                .searchable(text: $searchText, prompt: "Search words or usage...")
                // Native toolbar items: one tooltip and one circular highlight per button,
                // and Liquid Glass group capsules on macOS 26+.
                .toolbar {
                    if selectedWordIds.count > 1 {
                        ToolbarItem(placement: .status) {
                            Text("\(selectedWordIds.count) selected").foregroundStyle(.secondary).font(.caption).padding(.horizontal, 8)
                        }
                    } else {
                        ToolbarItemGroup(placement: .status) {
                            Button(action: onSelectBatch) { Label("Select learning batch", systemImage: "checkmark.circle") }.help("Select learning batch")
                            Button(action: onSelectAll) { Label("Select all Learning words", systemImage: "checklist") }.help("Select all Learning words")
                            Button(action: onCopyAll) { Label("Copy all Learning words", systemImage: "doc.on.doc") }.help("Copy all Learning words")
                        }
                    }
                    ToolbarItemGroup(placement: .automatic) {
                        Button(action: onUndo) { Label("Undo", systemImage: "arrow.uturn.backward") }.help("Undo").disabled(dbManager.undoStack.isEmpty)
                        Button(action: onRefresh) { Label("Refresh list", systemImage: "arrow.clockwise") }.help("Refresh list")
                        Button(action: onPromptCopy) { Label("Copy with prompt", systemImage: "text.append") }.help("Copy with prompt").disabled(selectedWordIds.isEmpty)
                    }
                }
                .onCopyCommand {
                    let t = dbManager.formatSelected(ids: selectedWordIds)
                    if !t.isEmpty {
                        onToast("Copied", 2.5)
                        return [NSItemProvider(object: t as NSString)]
                    }
                    return []
                }
            }
            if let message = toastMessage { ToastView(message: message) }
        }
        .onKeyPress(.rightArrow) {
            onArrowKeyUpdate(.mastered)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            onArrowKeyUpdate(.ignored)
            return .handled
        }
        // Esc as a window-wide shortcut, so it works wherever focus is (after a search it stays
        // in the toolbar search field, which onExitCommand on this view never sees).
        // First Esc clears the selection, the next clears the search, like the search field itself.
        .background {
            Button("Clear selection") {
                if !selectedWordIds.isEmpty { selectedWordIds.removeAll() } else { searchText = "" }
            }
            .keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }
}

struct ToastView: View {
    let message: String
    var body: some View { VStack { Spacer(); Text(message).font(.title2).padding(20).background(.regularMaterial).cornerRadius(12).shadow(radius: 8).padding(.bottom, 60).transition(.opacity) }.zIndex(1) }
}

// Export document. The snapshot is taken when the file is written, so it includes every change made so far.
struct SQLiteFile: FileDocument {
    static var readableContentTypes = [UTType.database, UTType.data]
    init() {}
    init(configuration: ReadConfiguration) throws {}
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("KindleBro-export.sqlite")
        try? FileManager.default.removeItem(at: tmp)
        try DatabaseManager.shared.backup(to: tmp)
        return FileWrapper(regularFileWithContents: try Data(contentsOf: tmp))
    }
}

extension DatabaseManager {
    private func learningWords(limit: Int? = nil) -> [Word] {
        let learning = words.filter { $0.status == .learning }
        if let limit {
            return Array(learning.prefix(max(0, limit)))
        }
        return learning
    }

    func formatSelected(ids: Set<Word.ID>) -> String { words.filter { ids.contains($0.id) }.map { "\($0.text)\n\($0.usage ?? "")" }.joined(separator: "\n\n") }
    func formatAllLearning() -> String { learningWords().map { "\($0.text)\n\($0.usage ?? "")" }.joined(separator: "\n\n") }
    func learningWordIds(limit: Int) -> [Word.ID] { learningWords(limit: limit).map(\.id) }
    func masterAllLearning() { updateStatus(words: learningWords(), newStatus: .mastered) }
    func masterSelected(ids: Set<Word.ID>) { updateStatus(words: words.filter { ids.contains($0.id) && $0.status != .mastered }, newStatus: .mastered) }
    func updateStatus(word: Word, newStatus: WordStatus, bulkIds: Set<Word.ID>) {
        if bulkIds.contains(word.id) { updateStatus(words: words.filter { bulkIds.contains($0.id) }, newStatus: newStatus) }
        else { updateStatus(words: [word], newStatus: newStatus) }
    }
}
