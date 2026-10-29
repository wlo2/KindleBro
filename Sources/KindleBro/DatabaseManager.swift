import Foundation
import NaturalLanguage
import SQLite
import SQLite3

class DatabaseManager: ObservableObject {
    static let shared = DatabaseManager(storeURL: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("KindleBro/db.sqlite"))
    
    let storeURL: URL
    private var db: Connection?
    private let dbQueue = DispatchQueue(label: "KindleBro.DatabaseQueue")
    private let dbQueueKey = DispatchSpecificKey<Void>()
    private var fetchWordsWorkItem: DispatchWorkItem?
    private let relatedQueue = DispatchQueue(label: "KindleBro.RelatedQueue", qos: .userInitiated, attributes: .concurrent)
    
    @Published var books: [Book] = []
    @Published var words: [Word] = []
    @Published var isDatabaseLoaded = false
    @Published var appError: AppError? // Central error state
    @Published var showClearConfirmation = false
    @Published var showExportPicker = false
    @Published var showImportPicker = false // set from the File menu, like showExportPicker
    
    enum AppError: LocalizedError {
        case dbError(String)
        case importError(String)
        case backupError(String)
        
        var errorDescription: String? {
            switch self {
            case .dbError(let msg): return "Database Error: \(msg)"
            case .importError(let msg): return "Import Failed: \(msg)"
            case .backupError(let msg): return "Backup Failed: \(msg)"
            }
        }
    }
    
    // Undo
    struct UndoAction {
        let changes: [String: WordStatus] // WORDS.id -> status before the change
    }
    @Published var undoStack: [UndoAction] = []
    
    private let wordsTable = Table("WORDS")
    private let w_id = Expression<String>("id")
    private let w_category = Expression<Int>("category")
    
    // Tests pass a temporary file; the app uses `shared`.
    init(storeURL: URL) {
        self.storeURL = storeURL
        dbQueue.setSpecific(key: dbQueueKey, value: ())
        if FileManager.default.fileExists(atPath: storeURL.path) {
            loadDatabase(from: storeURL)
        }
    }
    
    func importDatabase(from url: URL, completion: ((Swift.Result<Int, Error>) -> Void)? = nil) {
        // On the DB queue so the merge never races other reads and writes on the same file.
        dbQueue.async {
            do {
                let targetURL = self.storeURL
                let addedCount: Int
                
                if !FileManager.default.fileExists(atPath: targetURL.path) {
                    // Scenario A: First Run - Just copy
                    try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: targetURL)
                    self.loadDatabase(from: targetURL)
                    guard self.db != nil else {
                        // Not a usable vocab.db: remove the copy so the next import starts fresh.
                        try? FileManager.default.removeItem(at: targetURL)
                        throw AppError.importError("The selected file is not a Kindle vocabulary database.")
                    }
                    // Count all words as added
                    addedCount = try self.db?.scalar(self.wordsTable.count) ?? 0
                } else {
                    // Scenario B: Merge
                    guard let db = self.db else { throw AppError.dbError("Database not loaded") }
                    addedCount = try Self.mergeDatabase(sourceURL: url, into: db)
                    self.updateLemmas() // for the newly added words
                    self.fetchBooks()
                }
                
                DispatchQueue.main.async {
                    completion?(.success(addedCount))
                }
            } catch {
                DispatchQueue.main.async {
                    self.appError = .importError(error.localizedDescription)
                    completion?(.failure(error))
                }
            }
        }
    }
    
    func loadDatabase(from url: URL) {
        do {
            print("Opening database at: \(url.path)")
            db = try Connection(url.path)
            
            try createSettingsTable()
            try createIndices()
            
            DispatchQueue.main.async {
                self.isDatabaseLoaded = true
                self.appError = nil
            }
            updateLemmas()
            fetchBooks()
        } catch {
            db = nil // half-opened (e.g. not a SQLite file) counts as not loaded
            DispatchQueue.main.async {
                self.appError = .dbError(error.localizedDescription)
            }
            print("Failed to open database: \(error)")
        }
    }
    
    func backup(to targetURL: URL) throws {
        // Run behind any queued status writes so the backup includes them.
        if DispatchQueue.getSpecific(key: dbQueueKey) == nil {
            return try dbQueue.sync { try backup(to: targetURL) }
        }
        guard let sourceHandle = db?.handle else {
            throw AppError.dbError("Database not loaded")
        }
        
        let destDb: Connection
        do {
            destDb = try Connection(targetURL.path)
        } catch {
            throw AppError.dbError("Failed to open destination database: \(error)")
        }
        
        let destHandle = destDb.handle
        
        // sqlite3_backup_init(pDest, zDestName, pSource, zSourceName)
        // zDestName and zSourceName are usually "main"
        guard let backup = sqlite3_backup_init(destHandle, "main", sourceHandle, "main") else {
            let errorMsg = String(cString: sqlite3_errmsg(destHandle))
            throw AppError.dbError("Backup initialization failed: \(errorMsg)")
        }
        
        // sqlite3_backup_step(p, nPage)
        // -1 means copy all pages
        let stepResult = sqlite3_backup_step(backup, -1)
        
        // sqlite3_backup_finish(p)
        let finishResult = sqlite3_backup_finish(backup)
        
        if stepResult != SQLITE_DONE {
            let errorMsg = String(cString: sqlite3_errmsg(destHandle))
            throw AppError.dbError("Backup step failed (\(stepResult)): \(errorMsg)")
        }
        
        if finishResult != SQLITE_OK {
            throw AppError.dbError("Backup finish failed (\(finishResult))")
        }
        
        print("Backup successful to: \(targetURL.path)")
    }
    
    private func createIndices() throws {
        guard let db = db else { return }
        // Create indices to speed up joins and filtering
        try db.run("CREATE INDEX IF NOT EXISTS idx_lookups_word_book_ts ON LOOKUPS (word_key, book_key, timestamp)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_lookups_book_word_ts ON LOOKUPS (book_key, word_key, timestamp)")
    }
    
    private func createSettingsTable() throws {
        guard let db = db else { return }
        let settingsTable = Table("settings")
        let key = Expression<String>("key")
        let value = Expression<String>("value")
        
        try db.run(settingsTable.create(ifNotExists: true) { t in
            t.column(key, primaryKey: true)
            t.column(value)
        })
    }
    
    func saveSetting(key: String, value: String) {
        let settingsTable = Table("settings")
        let keyCol = Expression<String>("key")
        let valueCol = Expression<String>("value")
        
        let work = {
            guard let db = self.db else { return }
            do {
                try db.run(settingsTable.insert(or: .replace, keyCol <- key, valueCol <- value))
            } catch {
                print("Failed to save setting \(key): \(error)")
            }
        }
        
        if DispatchQueue.getSpecific(key: dbQueueKey) != nil {
            work()
        } else {
            dbQueue.async(execute: work)
        }
    }
    
    func getSetting(key: String) -> String? {
        let settingsTable = Table("settings")
        let keyCol = Expression<String>("key")
        let valueCol = Expression<String>("value")
        
        let work = { () -> String? in
            guard let db = self.db else { return nil }
            do {
                if let row = try db.pluck(settingsTable.filter(keyCol == key)) {
                    return row[valueCol]
                }
            } catch {
                print("Failed to get setting \(key): \(error)")
            }
            return nil
        }
        
        if DispatchQueue.getSpecific(key: dbQueueKey) != nil {
            return work()
        }
        return dbQueue.sync(execute: work)
    }
    
    static func mergeDatabase(sourceURL: URL, into db: Connection) throws -> Int {
        // ATTACH is not allowed inside a transaction, so attach first.
        try db.run("ATTACH DATABASE ? AS source", sourceURL.path)
        defer { _ = try? db.run("DETACH DATABASE source") }
        
        var addedWords = 0
        // All or nothing, so a failed import never leaves words without their lookups.
        try db.transaction {
            // If the ID exists, IGNORE (keep local). This preserves 'category' (Mastered status).
            try db.run("INSERT OR IGNORE INTO main.WORDS SELECT * FROM source.WORDS")
            addedWords = db.changes
            try db.run("INSERT OR IGNORE INTO main.BOOK_INFO SELECT * FROM source.BOOK_INFO")
            try db.run("INSERT OR IGNORE INTO main.LOOKUPS SELECT * FROM source.LOOKUPS")
        }
        return addedWords
    }
    
    func fetchBooks() {
        dbQueue.async { [weak self] in
            guard let self, let db = self.db else { return }
            do {
                // DISTINCT: one row per word per book, not per lookup
                // ORDER BY B.id: a book stored twice always gets its smallest id, so selection by id stays stable.
                let sql = """
                SELECT DISTINCT
                    B.id,
                    B.title,
                    B.authors,
                    COALESCE(WL.lemma, lower(W.word)),
                    W.category
                FROM BOOK_INFO B
                JOIN LOOKUPS L ON L.book_key = B.id
                JOIN WORDS W ON W.id = L.word_key
                LEFT JOIN word_lemmas WL ON WL.word_id = W.id
                ORDER BY B.id
                """
                
                var bookMap: [String: Book] = [:]
                var lemmaStatusesByBook: [String: [String: Set<WordStatus>]] = [:]
                
                for row in try db.prepare(sql) {
                    let id = row[0] as! String
                    let title = row[1] as! String
                    let authors = row[2] as! String
                    let lemma = row[3] as! String // one entry per dictionary form
                    let category = Int(row[4] as! Int64)
                    let status = WordStatus(rawValue: category) ?? .learning
                    
                    // Use a key to aggregate duplicates (Title + Authors), same as Word.bookKey
                    let bookKey = "\(title)_\(authors)"
                    if bookMap[bookKey] == nil {
                        bookMap[bookKey] = Book(
                            id: id,
                            title: title,
                            authors: authors,
                            wordCount: 0,
                            learningWordCount: 0,
                            isMastered: true
                        )
                    }

                    var perBook = lemmaStatusesByBook[bookKey] ?? [:]
                    var statuses = perBook[lemma] ?? Set<WordStatus>()
                    statuses.insert(status)
                    perBook[lemma] = statuses
                    lemmaStatusesByBook[bookKey] = perBook
                }

                for (bookKey, statusesByWord) in lemmaStatusesByBook {
                    guard var book = bookMap[bookKey] else { continue }
                    book.wordCount = statusesByWord.count
                    book.learningWordCount = statusesByWord.values.filter { $0.contains(.learning) }.count
                    book.isMastered = book.learningWordCount == 0
                    bookMap[bookKey] = book
                }
                
                let sortedBooks = bookMap.values.sorted(by: { $0.title < $1.title })
                
                DispatchQueue.main.async {
                self.books = sortedBooks
            }
            
        } catch {
            print("Error fetching books: \(error)")
        }
        }
    }

    // Other forms a search should also find, matched against stored lemmas and word text.
    private func searchCandidates(for text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Avoid stemming multi-word searches.
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return [] }

        let lower = trimmed.lowercased()
        // Russian: the dictionary form only ("слободы" finds "слободе" via lemma "слобода").
        // Kept even when the search is that form: the stored lemma is what finds the other forms.
        if trimmed.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil {
            return [Self.lemma(word: trimmed, language: "ru", kindleStem: nil, usage: nil)]
        }
        guard trimmed.range(of: "[A-Za-z]", options: .regularExpression) != nil else { return [] }

        // Same lemma rule as the stored lemmas, plus English suffix fallbacks for words Apple doesn't know.
        var candidates: Set<String> = [Self.lemma(word: trimmed, language: "en", kindleStem: nil, usage: nil)]

        // Simple English stemming fallbacks for common suffixes.
        if lower.count > 3 {
            if lower.hasSuffix("ies"), lower.count > 3 {
                candidates.insert(String(lower.dropLast(3)) + "y")
            }
            if lower.hasSuffix("ing"), lower.count > 4 {
                candidates.insert(String(lower.dropLast(3)))
            }
            if lower.hasSuffix("es"), lower.count > 3 {
                candidates.insert(String(lower.dropLast(2)))
            }
            if lower.hasSuffix("s"), lower.count > 2 {
                candidates.insert(String(lower.dropLast(1)))
            }
            if lower.hasSuffix("ed"), lower.count > 3 {
                let pre = lower[lower.index(lower.endIndex, offsetBy: -3)]
                if pre == "e" {
                    // e.g., "peeved" -> "peeve"
                    candidates.insert(String(lower.dropLast(1)))
                } else {
                    // e.g., "walked" -> "walk"
                    candidates.insert(String(lower.dropLast(2)))
                }
            }
        }

        return Array(candidates)
    }

    private func searchCandidatesIfEnabled(for text: String) -> [String] {
        guard UserDefaults.standard.bool(forKey: "enableStemSearch") else {
            return []
        }
        return searchCandidates(for: text)
    }

    // MARK: - Lemmas (dictionary forms used to group a book's word forms)

    // Bump when `lemma(...)` changes, so stored lemmas are recomputed.
    private static let lemmaVersion = "2"

    // Archaic pronouns: Apple maps thy, thine and thou to "thee", but each is its own word to learn.
    private static let keepAsWritten: Set<String> = ["thou", "thee", "thy", "thine", "ye"]

    // Dictionary form of a looked-up word: "vitiated" and "vitiates" both give "vitiate".
    // Order: Apple's lemma for the word in its sentence (tells "drawing" the noun from "draw"),
    // then for the word alone, then Kindle's stem (right for many rare words Apple doesn't know).
    // Entries with spaces, hyphens or apostrophes stay as they are: the tagger splits them,
    // which would merge "beau-ideal" into "beau".
    static func lemma(word: String, language: String, kindleStem: String?, usage: String?) -> String {
        let lower = word.lowercased()
        guard !word.isEmpty, word.unicodeScalars.allSatisfy(CharacterSet.letters.contains),
              !keepAsWritten.contains(lower) else { return lower }
        let nl = NLLanguage(String(language.prefix { $0 != "-" }).lowercased())
        if let usage, let found = taggedLemma(of: word, in: usage, language: nl) { return found }
        if let found = taggedLemma(of: word, in: word, language: nl) { return found }
        // Kindle's stem only if it starts like the word: it stems "insentience" as "sentience",
        // which linked unrelated books. Accents are ignored, so "eclat" -> "éclat" still passes.
        if let stem = kindleStem?.lowercased(), !stem.isEmpty,
           stem.folding(options: .diacriticInsensitive, locale: nil)
               .hasPrefix(lower.folding(options: .diacriticInsensitive, locale: nil).prefix(2)) {
            return stem
        }
        return lower
    }

    private static func taggedLemma(of word: String, in text: String, language: NLLanguage) -> String? {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        tagger.setLanguage(language, range: text.startIndex..<text.endIndex)
        var result: String?
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lemma,
                             options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            // Whole-token match: matching a substring turned "so" into the lemma of "sob".
            guard text[range].compare(word, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame else { return true }
            result = tag?.rawValue.lowercased()
            return false
        }
        return result?.isEmpty == false ? result : nil
    }

    // Computes lemmas for words that have none yet (new library, new import, or a new lemmaVersion).
    // Stored so SQL can group by them; about 1 s for 4k words, once.
    private func updateLemmas() {
        guard DispatchQueue.getSpecific(key: dbQueueKey) != nil else {
            dbQueue.async { self.updateLemmas() }
            return
        }
        guard let db else { return }
        do {
            try db.run("CREATE TABLE IF NOT EXISTS word_lemmas (word_id TEXT PRIMARY KEY, lemma TEXT NOT NULL)")
            try db.run("CREATE INDEX IF NOT EXISTS idx_word_lemmas_lemma ON word_lemmas (lemma)")
            if getSetting(key: "lemmaVersion") != Self.lemmaVersion { try db.run("DELETE FROM word_lemmas") }
            let missing = try db.prepare("""
                SELECT W.id, W.word, W.lang, W.stem,
                       (SELECT L.usage FROM LOOKUPS L WHERE L.word_key = W.id ORDER BY L.timestamp DESC LIMIT 1)
                FROM WORDS W LEFT JOIN word_lemmas WL ON WL.word_id = W.id
                WHERE WL.word_id IS NULL
                """).map { row in
                (row[0] as! String, Self.lemma(word: row[1] as? String ?? "", language: row[2] as? String ?? "",
                                               kindleStem: row[3] as? String, usage: row[4] as? String))
            }
            try db.transaction {
                for (id, lemma) in missing {
                    try db.run("INSERT OR REPLACE INTO word_lemmas (word_id, lemma) VALUES (?, ?)", id, lemma)
                }
            }
            saveSetting(key: "lemmaVersion", value: Self.lemmaVersion)
        } catch {
            // Without lemmas, words fall back to their own form (COALESCE in the queries).
            print("Failed to update lemmas: \(error)")
        }
    }

    private func mergedStatus(from statuses: [WordStatus]) -> WordStatus {
        if statuses.contains(.learning) { return .learning }
        if statuses.contains(.mastered) { return .mastered }
        return .ignored
    }

    // Settings key for a preferred usage: per word and per book
    private static func preferredUsageKey(wordId: String, bookKey: String) -> String {
        "\(wordId)|\(bookKey)"
    }

    private func groupByLemma(_ words: [Word], preferredUsages: [String: String]) -> [Word] {
        var merged: [String: Word] = [:]
        var order: [String] = []

        for word in words {
            let groupKey = "\(word.bookKey)|\(word.lemma)"
            let preferred = { (id: String) in preferredUsages[Self.preferredUsageKey(wordId: id, bookKey: word.bookKey)] }
            if merged[groupKey] == nil {
                var seed = word // a raw row: one id, its own status
                seed.text = word.text.lowercased()
                seed.usage = preferred(seed.databaseId) ?? word.usage
                merged[groupKey] = seed
                order.append(groupKey)
                continue
            }

            var current = merged[groupKey]!
            for id in word.databaseIds where !current.databaseIds.contains(id) {
                current.databaseIds.append(id)
            }

            for (id, status) in word.databaseStatuses {
                current.databaseStatuses[id] = status
            }

            // Several forms ("vitiated", "vitiates"): show the dictionary form. One form keeps its spelling.
            if word.text.lowercased() != current.text { current.text = word.lemma }
            if word.lemma == word.text.lowercased() {
                current.databaseId = word.databaseId
            }

            if word.timestamp > current.timestamp {
                current.timestamp = word.timestamp
                current.usage = preferred(current.databaseId) ?? word.usage
            }

            current.usageCount += word.usageCount
            current.relatedBookCount = max(current.relatedBookCount, word.relatedBookCount)

            for usage in word.allUsages where !current.allUsages.contains(usage) {
                current.allUsages.append(usage)
            }

            if let preferredUsage = current.databaseIds.compactMap(preferred).first {
                current.usage = preferredUsage
            }

            current.status = mergedStatus(from: Array(current.databaseStatuses.values))
            merged[groupKey] = current
        }

        return order.compactMap { merged[$0] }.sorted {
            if $0.status.sortRank != $1.status.sortRank { return $0.status.sortRank < $1.status.sortRank }
            return $0.timestamp > $1.timestamp
        }
    }

    // Builds a Word from a row shaped: id, word, category, usage, timestamp,
    // book id, book title, book authors, related_book_count, usage_count, lemma
    private func makeWord(_ row: Statement.Element) -> Word {
        let id = row[0] as! String
        let text = row[1] as! String
        let lemma = row[10] as! String
        let usage = row[3] as! String
        let ts = row[4] as! Int64
        let bookTitle = row[6] as! String
        let bookAuthors = row[7] as! String
        let status = WordStatus(rawValue: Int(row[2] as! Int64)) ?? .learning
        return Word(
            // Keyed by book title + authors so duplicate BOOK_INFO rows of one book get one stable id
            id: "\(lemma)_\(bookTitle)_\(bookAuthors)",
            databaseId: id,
            databaseIds: [id],
            databaseStatuses: [id: status],
            text: text,
            lemma: lemma,
            status: status,
            usage: usage,
            allUsages: [WordUsage(text: usage, timestamp: ts)],
            usageCount: Int(row[9] as! Int64),
            bookId: row[5] as? String,
            bookTitle: bookTitle,
            bookAuthors: bookAuthors,
            timestamp: ts,
            relatedBookCount: Int(row[8] as! Int64)
        )
    }
    
    // Sort: Learning first, then Mastered, then Ignored; newest first within each group
    private static let statusOrderClause = """
     ORDER BY CASE W.category
        WHEN 0 THEN 0
        WHEN 100 THEN 1
        WHEN -1 THEN 2
        ELSE 1
     END, latest_ts DESC
    """

    // SQL literal for LIKE '%text%', with quotes and the LIKE wildcards % and _ escaped
    static func containsPattern(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "'", with: "''")
        return "'%\(escaped)%' ESCAPE '\\'"
    }
    
    func fetchWords(for bookId: String?, search: String = "") {
        let isShortSearch = !search.isEmpty && search.count < 3
        let relatedWordsEnabled = UserDefaults.standard.bool(forKey: "enableRelatedWords")
        var selectedBookTitle: String? = nil
        var selectedBookAuthors: String? = nil
        // Called from the UI only; `books` is main-thread state.
        if let bookId, let book = books.first(where: { $0.id == bookId }) {
            selectedBookTitle = book.title
            selectedBookAuthors = book.authors
        }
        
        // Cancel any in-flight fetch to avoid queue backlog
        fetchWordsWorkItem?.cancel()
        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem { [weak self] in
            guard let self, let db = self.db else { return }
            if workItem.isCancelled { return }
            
            do {
                let preferredUsages = self.loadPreferredUsages()
                
                // Optimized SQL query:
                // 1. Join WORDS, LOOKUPS, and BOOK_INFO
                // 2. Use subqueries to select latest usage/timestamp per word+book
                // 3. Group by Word ID and Book ID to avoid duplicate rows
                // 4. Let SQL handle the sorting
                
                var withParts: [String] = []
                var bookFilterClause: String? = nil
                if let bookId = bookId {
                    if let selectedBookTitle, let selectedBookAuthors {
                        let safeTitle = selectedBookTitle.replacingOccurrences(of: "'", with: "''")
                        let safeAuthors = selectedBookAuthors.replacingOccurrences(of: "'", with: "''")
                        withParts.append("""
                        book_filter AS (
                            SELECT id FROM BOOK_INFO WHERE title = '\(safeTitle)' AND authors = '\(safeAuthors)'
                        )
                        """)
                    } else {
                        let safeId = bookId.replacingOccurrences(of: "'", with: "''")
                        withParts.append("""
                        book_filter AS (
                            SELECT '\(safeId)' AS id
                        )
                        """)
                    }
                    bookFilterClause = "book_key IN (SELECT id FROM book_filter)"
                }

                let latestFilter = bookFilterClause.map { "WHERE \($0)" } ?? ""
                withParts.append("""
                latest_ts AS (
                    SELECT word_key, book_key, MAX(timestamp) AS latest_ts
                    FROM LOOKUPS
                    \(latestFilter)
                    GROUP BY word_key, book_key
                ),
                latest AS (
                    SELECT L.word_key, L.book_key, T.latest_ts AS latest_ts, MAX(L.rowid) AS latest_rowid
                    FROM LOOKUPS L
                    JOIN latest_ts T
                      ON T.word_key = L.word_key
                     AND T.book_key = L.book_key
                     AND T.latest_ts = L.timestamp
                    GROUP BY L.word_key, L.book_key, T.latest_ts
                )
                """)
                withParts.append("""
                usage_counts AS (
                    SELECT word_key, book_key, COUNT(*) AS usage_count
                    FROM LOOKUPS
                    \(latestFilter)
                    GROUP BY word_key, book_key
                )
                """)

                if relatedWordsEnabled {
                    // Related words: same lemma in other books. With a book open, only count its lemmas.
                    if bookFilterClause != nil {
                        withParts.append("""
                        book_lemmas AS (
                            SELECT DISTINCT WL.lemma AS lemma
                            FROM word_lemmas WL
                            JOIN LOOKUPS L ON L.word_key = WL.word_id
                            WHERE L.book_key IN (SELECT id FROM book_filter)
                        )
                        """)
                    }
                    let bookLemmasJoin = bookFilterClause != nil ? "JOIN book_lemmas BLM ON BLM.lemma = WL.lemma" : ""
                    withParts.append("""
                    lemma_book_counts AS (
                        SELECT WL.lemma AS lemma, COUNT(DISTINCT SB.title || '_' || SB.authors) AS book_count
                        FROM word_lemmas WL
                        JOIN LOOKUPS L ON L.word_key = WL.word_id
                        JOIN BOOK_INFO SB ON SB.id = L.book_key
                        \(bookLemmasJoin)
                        GROUP BY WL.lemma
                    )
                    """)
                }

                let withClause = "WITH " + withParts.joined(separator: ",\n")
                let relatedSelect = relatedWordsEnabled
                    ? "COALESCE(lemma_book_counts.book_count, 1) - 1 as related_book_count,"
                    : "0 as related_book_count,"
                let relatedJoin = relatedWordsEnabled ? "LEFT JOIN lemma_book_counts ON lemma_book_counts.lemma = WL.lemma" : ""

                var sql = """
                \(withClause)
                SELECT
                    W.id, W.word, W.category,
                    L.usage,
                    latest.latest_ts,
                    B.id as book_id, B.title as book_title, B.authors as book_authors,
                    \(relatedSelect)
                    usage_counts.usage_count,
                    COALESCE(WL.lemma, lower(W.word)) as lemma
                FROM latest
                JOIN WORDS W ON W.id = latest.word_key
                JOIN BOOK_INFO B ON B.id = latest.book_key
                JOIN LOOKUPS L ON L.rowid = latest.latest_rowid
                JOIN usage_counts ON usage_counts.word_key = latest.word_key AND usage_counts.book_key = latest.book_key
                LEFT JOIN word_lemmas WL ON WL.word_id = W.id
                \(relatedJoin)
                """
                
                var conditions: [String] = []
                
                if !search.isEmpty {
                    let lowerSearch = search.lowercased()
                    var wordConditions: [String] = [
                        "W.word LIKE \(Self.containsPattern(lowerSearch))"
                    ]

                    let stems = self.searchCandidatesIfEnabled(for: search)
                    for stem in stems {
                        let sanitizedStem = stem.replacingOccurrences(of: "'", with: "''")
                        wordConditions.append("WL.lemma = '\(sanitizedStem)'")
                        // Also match the candidate as text, for words whose stored lemma differs
                        wordConditions.append("W.word LIKE \(Self.containsPattern(stem))")
                    }

                    let usageCondition = """
                    EXISTS (
                        SELECT 1 FROM LOOKUPS LU
                        WHERE LU.word_key = W.id AND LU.book_key = B.id
                        AND LU.usage LIKE \(Self.containsPattern(lowerSearch))
                    )
                    """
                    conditions.append("(\(wordConditions.joined(separator: " OR ")) OR \(usageCondition))")
                }
                
                if !conditions.isEmpty {
                    sql += " WHERE " + conditions.joined(separator: " AND ")
                }
                
                // Group to ensure unique word-book pairs (in case multiple lookups share same timestamp)
                sql += " GROUP BY W.id, B.id"
                sql += Self.statusOrderClause
                
                if !search.isEmpty {
                    sql += " LIMIT \(isShortSearch ? 100 : 500)"
                } else if bookId == nil {
                    sql += " LIMIT 1000"
                }
                
                var rawWords: [Word] = []
                
                for row in try db.prepare(sql) {
                    if workItem.isCancelled { return }
                    rawWords.append(self.makeWord(row))
                }

                let finalWords = self.groupByLemma(rawWords, preferredUsages: preferredUsages)
                
                DispatchQueue.main.async {
                    if !workItem.isCancelled {
                        self.words = finalWords
                    }
                }
                
            } catch {
                print("Error fetching words: \(error)")
                DispatchQueue.main.async {
                    self.appError = .dbError(error.localizedDescription)
                }
            }
        }
        fetchWordsWorkItem = workItem
        // Run DB operations on a serial DB queue
        dbQueue.async(execute: workItem)
    }
    
    func fetchUsages(for word: Word) {
        guard let bookTitle = word.bookTitle, let bookAuthors = word.bookAuthors else { return }
        dbQueue.async {
            guard let db = self.db else { return }
            do {
                let targetIds = word.databaseIds
                let placeholders = Array(repeating: "?", count: targetIds.count).joined(separator: ", ")
                // Match the book by title + authors so duplicate BOOK_INFO rows of one book are included.
                let sql = """
                SELECT L.usage, L.timestamp
                FROM LOOKUPS L
                JOIN BOOK_INFO B ON B.id = L.book_key
                WHERE L.word_key IN (\(placeholders)) AND B.title = ? AND B.authors = ?
                ORDER BY L.timestamp DESC
                """
                
                var usages: [WordUsage] = []
                var seenTexts = Set<String>()
                for row in try db.prepare(sql, targetIds.map { $0 as Binding? } + [bookTitle, bookAuthors]) {
                    let text = row[0] as! String
                    let ts = row[1] as! Int64
                    // Keep only the latest timestamp per identical usage text.
                    if seenTexts.insert(text).inserted {
                        usages.append(WordUsage(text: text, timestamp: ts))
                    }
                }
                
                DispatchQueue.main.async {
                    if let index = self.words.firstIndex(where: { $0.id == word.id }) {
                        self.words[index].allUsages = usages
                    }
                }
            } catch {
                print("Error fetching usages: \(error)")
            }
        }
    }

    func fetchRelatedWords(for word: Word, completion: @escaping ([Word]) -> Void) {
        relatedQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let readDb = try Connection(self.storeURL.path, readonly: true)
                readDb.busyTimeout = 5

                // Same lemma as the red-dot count in fetchWords, so the popover lists exactly those books.
                let sql = """
                SELECT
                    W.id, W.word, W.category,
                    (SELECT L2.usage
                     FROM LOOKUPS L2
                     WHERE L2.word_key = W.id AND L2.book_key = B.id
                     ORDER BY L2.timestamp DESC
                     LIMIT 1) as usage,
                    (SELECT MAX(L3.timestamp)
                     FROM LOOKUPS L3
                     WHERE L3.word_key = W.id AND L3.book_key = B.id) as latest_ts,
                    B.id as book_id, B.title as book_title, B.authors as book_authors,
                    0 as related_book_count,
                    (SELECT COUNT(*)
                     FROM LOOKUPS L4
                     WHERE L4.word_key = W.id AND L4.book_key = B.id) as usage_count,
                    WL.lemma as lemma
                FROM word_lemmas WL
                JOIN WORDS W ON W.id = WL.word_id
                JOIN LOOKUPS L ON L.word_key = W.id
                JOIN BOOK_INFO B ON L.book_key = B.id
                WHERE WL.lemma = ?
                  AND NOT (B.title = ? AND B.authors = ?) -- other books only, including duplicate BOOK_INFO rows
                GROUP BY W.id, B.id
                """ + Self.statusOrderClause

                let results = try readDb.prepare(sql, word.lemma, word.bookTitle ?? "", word.bookAuthors ?? "").map(self.makeWord)
                let merged = self.groupByLemma(results, preferredUsages: [:])
                DispatchQueue.main.async { completion(merged) }
            } catch {
                print("Error fetching related words: \(error)")
                DispatchQueue.main.async { completion([]) }
            }
        }
    }
    
    func updateStatus(words: [Word], newStatus: WordStatus) {
        updateStatuses(words.map { ($0, newStatus) })
    }
    
    // Applies all changes as one undo step.
    func updateStatuses(_ changes: [(word: Word, status: WordStatus)]) {
        guard !changes.isEmpty else { return }
        var oldStatuses: [String: WordStatus] = [:]
        var newStatuses: [String: WordStatus] = [:]
        for (word, status) in changes {
            for id in word.databaseIds {
                // The same WORDS.id can sit in several rows (one per book); keep its first old status.
                oldStatuses[id] = oldStatuses[id] ?? word.databaseStatuses[id] ?? word.status
                newStatuses[id] = status
            }
        }
        undoStack.append(UndoAction(changes: oldStatuses))
        writeStatuses(newStatuses)
    }
    
    func undoLastAction() {
        guard let lastAction = undoStack.popLast() else { return }
        writeStatuses(lastAction.changes)
    }
    
    private func writeStatuses(_ statuses: [String: WordStatus]) {
        dbQueue.async { [weak self] in
            guard let self, let db = self.db else { return }
            do {
                try db.transaction {
                    // Group by status to minimize DB calls
                    for (status, items) in Dictionary(grouping: statuses, by: { $0.value }) {
                        let ids = items.map { $0.key }
                        try db.run(self.wordsTable.filter(ids.contains(self.w_id)).update(self.w_category <- status.rawValue))
                    }
                }
                
                DispatchQueue.main.async {
                    // Update every row sharing a changed WORDS.id: status is shared across books.
                    var updated = self.words
                    for i in updated.indices {
                        let matchedIds = updated[i].databaseIds.filter { statuses[$0] != nil }
                        guard !matchedIds.isEmpty else { continue }
                        for id in matchedIds {
                            updated[i].databaseStatuses[id] = statuses[id]
                        }
                        updated[i].status = self.mergedStatus(from: Array(updated[i].databaseStatuses.values))
                    }
                    self.words = updated
                    
                    // Refresh book list to update isMastered status
                    self.fetchBooks()
                }
            } catch {
                print("Failed to update status: \(error)")
                DispatchQueue.main.async {
                    self.appError = .dbError(error.localizedDescription)
                }
            }
        }
    }
    
    // MARK: - Preferred Usage Persistence
    
    func savePreferredUsage(for word: Word, usage: String) {
        // Under every form of the row: on load the first form with a saved choice wins, and the
        // row's forms change order as new lookups arrive, so a choice saved under one form could lose.
        for id in word.databaseIds {
            saveSetting(key: "pref_usage_\(Self.preferredUsageKey(wordId: id, bookKey: word.bookKey))", value: usage)
        }

        // Update local memory immediately: same word, same book only
        for i in words.indices where words[i].bookKey == word.bookKey && words[i].databaseIds.contains(word.databaseId) {
            words[i].usage = usage
        }
    }
    
    private func loadPreferredUsages() -> [String: String] {
        guard let db = db else { return [:] }
        let settingsTable = Table("settings")
        let keyCol = Expression<String>("key")
        let valueCol = Expression<String>("value")
        
        var prefs: [String: String] = [:]
        
        do {
            let query = settingsTable.filter(keyCol.like("pref_usage_%"))
            for row in try db.prepare(query) {
                let key = row[keyCol]
                let val = row[valueCol]
                if let id = key.components(separatedBy: "pref_usage_").last {
                    prefs[id] = val
                }
            }
        } catch {
            print("Failed to load preferred usages: \(error)")
        }
        return prefs
    }
    
    func clearDatabase() {
        undoStack.removeAll() // old ids would rewrite statuses in the next imported library
        // On the DB queue so no queued work runs against the deleted file
        dbQueue.async {
            self.db = nil
            
            do {
                if FileManager.default.fileExists(atPath: self.storeURL.path) {
                    try FileManager.default.removeItem(at: self.storeURL)
                }
                
                DispatchQueue.main.async {
                    self.books = []
                    self.words = []
                    self.isDatabaseLoaded = false
                }
            } catch {
                print("Failed to clear database: \(error)")
                DispatchQueue.main.async {
                    self.appError = .dbError("Failed to clear database: \(error.localizedDescription)")
                }
            }
        }
    }
}
