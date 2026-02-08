import Foundation
import NaturalLanguage
import SQLite

class DatabaseManager: ObservableObject {
    static let shared = DatabaseManager()
    
    private var db: Connection?
    private let dbQueue = DispatchQueue(label: "KindleBro.DatabaseQueue")
    private let dbQueueKey = DispatchSpecificKey<Void>()
    private var fetchWordsWorkItem: DispatchWorkItem?
    private var stemDb: Connection?
    private let stemQueue = DispatchQueue(label: "KindleBro.StemQueue", qos: .userInitiated, attributes: .concurrent)
    
    @Published var books: [Book] = []
    @Published var words: [Word] = []
    @Published var isDatabaseLoaded = false
    @Published var errorMessage: String?
    @Published var appError: AppError? // Central error state
    @Published var showClearConfirmation = false
    @Published var showExportPicker = false
    
    enum AppError: LocalizedError {
        case dbError(String)
        case importError(String)
        case syncError(String)
        
        var errorDescription: String? {
            switch self {
            case .dbError(let msg): return "Database Error: \(msg)"
            case .importError(let msg): return "Import Failed: \(msg)"
            case .syncError(let msg): return "Sync Failed: \(msg)"
            }
        }
    }
    
    // Undo
    struct UndoAction {
        let changes: [(wordId: String, oldStatus: WordStatus)]
    }
    @Published var undoStack: [UndoAction] = []
    
    // Tables
    private let wordsTable = Table("WORDS")
    private let lookupsTable = Table("LOOKUPS")
    private let bookInfoTable = Table("BOOK_INFO")
    
    // Columns
    // WORDS
    private let w_id = Expression<String>("id")
    private let w_word = Expression<String>("word")
    private let w_stem = Expression<String?>("stem")
    private let w_lang = Expression<String>("lang")
    private let w_category = Expression<Int>("category")
    
    // LOOKUPS
    private let l_id = Expression<String>("id")
    private let l_word_key = Expression<String>("word_key")
    private let l_book_key = Expression<String>("book_key")
    private let l_usage = Expression<String>("usage")
    private let l_timestamp = Expression<Int64>("timestamp")
    
    // BOOK_INFO
    private let b_id = Expression<String>("id")
    private let b_title = Expression<String>("title")
    private let b_authors = Expression<String>("authors")
    private let b_lang = Expression<String>("lang")
    
    private init() {
        dbQueue.setSpecific(key: dbQueueKey, value: ())
        // Try to load from persistent store on init
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("KindleBro")
        let dbPath = appDir.appendingPathComponent("db.sqlite")
        
        if FileManager.default.fileExists(atPath: dbPath.path) {
            loadDatabase(from: dbPath)
        }
    }
    
    func getPersistentStoreURL() throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("KindleBro")
        
        if !FileManager.default.fileExists(atPath: appDir.path) {
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        }
        
        return appDir.appendingPathComponent("db.sqlite")
    }
    
    func importDatabase(from url: URL, completion: ((Swift.Result<Int, Error>) -> Void)? = nil) {
        do {
            let targetURL = try getPersistentStoreURL()
            var addedCount = 0
            
            if !FileManager.default.fileExists(atPath: targetURL.path) {
                // Scenario A: First Run - Just copy
                try FileManager.default.copyItem(at: url, to: targetURL)
                loadDatabase(from: targetURL)
                // Count all words as added
                addedCount = try db?.scalar(wordsTable.count) ?? 0
            } else {
                // Scenario B: Merge
                addedCount = try mergeDatabase(sourceURL: url, into: targetURL)
                // Reload to reflect changes
                loadDatabase(from: targetURL)
            }
            
            DispatchQueue.main.async {
                completion?(.success(addedCount))
            }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Import failed: \(error)"
                completion?(.failure(error))
            }
        }
    }
    
    func loadDatabase(from url: URL) {
        do {
            print("Opening database at: \(url.path)")
            db = try Connection(url.path)
            stemDb = try? Connection(url.path)
            
            try createSettingsTable()
            try createIndices()
            
            DispatchQueue.main.async {
                self.isDatabaseLoaded = true
                self.errorMessage = nil
                self.appError = nil
            }
            fetchBooks()
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Failed to open database: \(error)"
                self.appError = .dbError(error.localizedDescription)
            }
            print("Failed to open database: \(error)")
        }
    }
    
    private func createIndices() throws {
        guard let db = db else { return }
        // Create indices to speed up joins and filtering
        try db.run("CREATE INDEX IF NOT EXISTS idx_lookups_word_key ON LOOKUPS (word_key)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_lookups_book_key ON LOOKUPS (book_key)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_lookups_word_book_ts ON LOOKUPS (word_key, book_key, timestamp)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_lookups_book_word_ts ON LOOKUPS (book_key, word_key, timestamp)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_words_id ON WORDS (id)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_words_stem ON WORDS (stem)")
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
        guard let db = db else { return }
        let settingsTable = Table("settings")
        let keyCol = Expression<String>("key")
        let valueCol = Expression<String>("value")
        
        let work = {
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
        guard let db = db else { return nil }
        let settingsTable = Table("settings")
        let keyCol = Expression<String>("key")
        let valueCol = Expression<String>("value")
        
        let work = { () -> String? in
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
    
    private func mergeDatabase(sourceURL: URL, into targetURL: URL) throws -> Int {
        // use standard SQLite connection to target, attach source
        let db = try Connection(targetURL.path)
        
        // ATTACH 'source.db' AS source
        let attachStmt = "ATTACH DATABASE ? AS source"
        try db.run(attachStmt, sourceURL.path)
        
        // INSERT OR IGNORE INTO main.TABLE SELECT * FROM source.TABLE
        // 1. WORDS
        // We want to preserve our local changes.
        // If the ID exists, IGNORE (keep local). This preserves 'category' (Mastered status).
        try db.run("INSERT OR IGNORE INTO main.WORDS SELECT * FROM source.WORDS")
        let addedWords = db.changes
        
        // 2. BOOK_INFO
        try db.run("INSERT OR IGNORE INTO main.BOOK_INFO SELECT * FROM source.BOOK_INFO")
        
        // 3. LOOKUPS
        try db.run("INSERT OR IGNORE INTO main.LOOKUPS SELECT * FROM source.LOOKUPS")
        
        // 4. METADATA / DICT_INFO ? Not critical for this app features but good for completeness
        // try db.run("INSERT OR IGNORE INTO main.METADATA SELECT * FROM source.METADATA")
        
        // DETACH source
        try db.run("DETACH DATABASE source")
        
        return addedWords
    }
    
    func fetchBooks() {
        guard let db = db else { return }
        
        dbQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let sql = """
                SELECT
                    B.id,
                    B.title,
                    B.authors,
                    B.lang,
                    COUNT(DISTINCT W.word) AS word_count,
                    SUM(CASE WHEN W.category = 0 THEN 1 ELSE 0 END) AS learning_count
                FROM BOOK_INFO B
                JOIN LOOKUPS L ON L.book_key = B.id
                JOIN WORDS W ON W.id = L.word_key
                GROUP BY B.id
                """
                
                var bookMap: [String: Book] = [:]
                
                for row in try db.prepare(sql) {
                    let id = row[0] as! String
                    let title = row[1] as! String
                    let authors = row[2] as! String
                    let lang = row[3] as! String
                    let count = Int(row[4] as! Int64)
                    let learningCount = Int(row[5] as! Int64)
                    
                    // Use a key to aggregate duplicates (Title + Authors)
                    let bookKey = "\(title)_\(authors)"
                    
                    if count > 0 {
                        if var existing = bookMap[bookKey] {
                            existing.wordCount += count
                            if learningCount > 0 {
                                existing.isMastered = false
                            }
                            bookMap[bookKey] = existing
                        } else {
                            bookMap[bookKey] = Book(
                                id: id,
                                title: title,
                                authors: authors,
                                language: lang,
                                wordCount: count,
                                isMastered: learningCount == 0
                            )
                        }
                    }
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

    private func englishStemCandidates(for text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Avoid stemming multi-word searches or non-Latin queries.
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return [] }
        guard trimmed.range(of: "[A-Za-z]", options: .regularExpression) != nil else { return [] }

        let lower = trimmed.lowercased()
        var candidates = Set<String>()

        // Prefer lemma if available (do not hard-require language detection for short inputs).
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = trimmed
        let (lemma, _) = tagger.tag(at: trimmed.startIndex, unit: .word, scheme: .lemma)
        if let lemma = lemma?.rawValue.lowercased(), !lemma.isEmpty {
            candidates.insert(lemma)
        }

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

        // Drop the original search term to avoid redundant LIKEs.
        candidates.remove(lower)
        return Array(candidates)
    }

    private func englishStemCandidatesIfEnabled(for text: String) -> [String] {
        guard UserDefaults.standard.bool(forKey: "enableStemSearch") || UserDefaults.standard.object(forKey: "enableStemSearch") == nil else {
            return []
        }
        return englishStemCandidates(for: text)
    }
    
    func fetchWords(for bookId: String?, search: String = "") {
        guard let db = db else { return }
        
        let isShortSearch = !search.isEmpty && search.count < 3
        let relatedWordsEnabled = UserDefaults.standard.object(forKey: "enableRelatedWords") == nil
            || UserDefaults.standard.bool(forKey: "enableRelatedWords")
        var selectedBookTitle: String? = nil
        var selectedBookAuthors: String? = nil
        if let bookId = bookId {
            let resolve = {
                if let book = self.books.first(where: { $0.id == bookId }) {
                    selectedBookTitle = book.title
                    selectedBookAuthors = book.authors
                }
            }
            if Thread.isMainThread {
                resolve()
            } else {
                DispatchQueue.main.sync(execute: resolve)
            }
        }
        
        // Cancel any in-flight fetch to avoid queue backlog
        fetchWordsWorkItem?.cancel()
        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
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
                    if let _ = bookFilterClause {
                        withParts.append("""
                        book_stems AS (
                            SELECT DISTINCT W.stem AS stem
                            FROM WORDS W
                            JOIN LOOKUPS L ON L.word_key = W.id
                            WHERE W.stem IS NOT NULL AND W.stem != ''
                              AND L.book_key IN (SELECT id FROM book_filter)
                        )
                        """)
                        withParts.append("""
                        stem_book_counts AS (
                            SELECT W.stem AS stem, COUNT(DISTINCT L.book_key) AS book_count
                            FROM WORDS W
                            JOIN LOOKUPS L ON L.word_key = W.id
                            JOIN book_stems BS ON BS.stem = W.stem
                            WHERE W.stem IS NOT NULL AND W.stem != ''
                            GROUP BY W.stem
                        )
                        """)
                    } else {
                        withParts.append("""
                        stem_book_counts AS (
                            SELECT W.stem AS stem, COUNT(DISTINCT L.book_key) AS book_count
                            FROM WORDS W
                            JOIN LOOKUPS L ON L.word_key = W.id
                            WHERE W.stem IS NOT NULL AND W.stem != ''
                            GROUP BY W.stem
                        )
                        """)
                    }
                }

                let withClause = "WITH " + withParts.joined(separator: ",\n")
                let stemSelect = relatedWordsEnabled
                    ? """
                    CASE
                        WHEN W.stem IS NULL OR W.stem = '' THEN 0
                        ELSE COALESCE(stem_book_counts.book_count, 1) - 1
                    END as stem_other_book_count,
                    """
                    : "0 as stem_other_book_count,"
                let stemJoin = relatedWordsEnabled ? "LEFT JOIN stem_book_counts ON stem_book_counts.stem = W.stem" : ""

                var sql = """
                \(withClause)
                SELECT
                    W.id, W.word, W.stem, W.lang, W.category,
                    L.usage,
                    latest.latest_ts,
                    B.id as book_id, B.title as book_title, B.authors as book_authors,
                    \(stemSelect)
                    usage_counts.usage_count
                FROM latest
                JOIN WORDS W ON W.id = latest.word_key
                JOIN BOOK_INFO B ON B.id = latest.book_key
                JOIN LOOKUPS L ON L.rowid = latest.latest_rowid
                JOIN usage_counts ON usage_counts.word_key = latest.word_key AND usage_counts.book_key = latest.book_key
                \(stemJoin)
                """
                
                var conditions: [String] = []
                
                if !search.isEmpty {
                    let sanitizedSearch = search.lowercased().replacingOccurrences(of: "'", with: "''")
                    var wordConditions: [String] = [
                        "W.word LIKE '%\(sanitizedSearch)%'"
                    ]

                    let stems = self.englishStemCandidatesIfEnabled(for: search)
                    for stem in stems {
                        let sanitizedStem = stem.replacingOccurrences(of: "'", with: "''")
                        wordConditions.append("W.stem = '\(sanitizedStem)'")
                        // Fallback to word matching on stem in case the DB stem differs from our lemmatizer
                        wordConditions.append("W.word LIKE '%\(sanitizedStem)%'")
                    }

                    let usageCondition = """
                    EXISTS (
                        SELECT 1 FROM LOOKUPS LU
                        WHERE LU.word_key = W.id AND LU.book_key = B.id
                        AND LU.usage LIKE '%\(sanitizedSearch)%'
                    )
                    """
                    conditions.append("(\(wordConditions.joined(separator: " OR ")) OR \(usageCondition))")
                }
                
                if !conditions.isEmpty {
                    sql += " WHERE " + conditions.joined(separator: " AND ")
                }
                
                // Group to ensure unique word-book pairs (in case multiple lookups share same timestamp)
                sql += " GROUP BY W.id, B.id"
                // Sort: Learning first, then Mastered, then Ignored; newest first within each group
                sql += """
                 ORDER BY CASE W.category
                    WHEN 0 THEN 0
                    WHEN 100 THEN 1
                    WHEN -1 THEN 2
                    ELSE 1
                 END, latest_ts DESC
                """
                
                if !search.isEmpty {
                    sql += " LIMIT \(isShortSearch ? 100 : 500)"
                } else if bookId == nil {
                    sql += " LIMIT 1000"
                }
                
                var finalWords: [Word] = []
                
                for row in try db.prepare(sql) {
                    if workItem.isCancelled { return }
                    let id = row[0] as! String
                    let text = row[1] as! String
                    let stem = row[2] as? String
                    let lang = row[3] as! String
                    let cat = Int(row[4] as! Int64)
                    let usage = row[5] as! String
                    let ts = row[6] as! Int64
                    let bId = row[7] as! String
                    let bTitle = row[8] as! String
                    let bAuthors = row[9] as! String
                    let stemOtherBookCount = Int(row[10] as! Int64)
                    let usageCount = Int(row[11] as! Int64)
                    
                    let status = WordStatus(rawValue: cat) ?? .learning
                    let preferred = preferredUsages[id]
                    let uiId = "\(id)_\(bId)"
                    
                    let newWord = Word(
                        id: uiId,
                        databaseId: id,
                        text: text,
                        stem: stem,
                        language: lang,
                        status: status,
                        usage: preferred ?? usage,
                        allUsages: [WordUsage(text: usage, timestamp: ts)],
                        usageCount: usageCount,
                        bookId: bId,
                        bookTitle: bTitle,
                        bookAuthors: bAuthors,
                        timestamp: ts,
                        stemOtherBookCount: stemOtherBookCount
                    )
                    finalWords.append(newWord)
                }
                
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
        guard let db = db, let bookId = word.bookId else { return }
        dbQueue.async {
            do {
                let sql = """
                SELECT L.usage, L.timestamp
                FROM LOOKUPS L
                WHERE L.word_key = '\(word.databaseId)' AND L.book_key = '\(bookId)'
                ORDER BY L.timestamp DESC
                """
                
                var usages: [WordUsage] = []
                var seenTexts = Set<String>()
                for row in try db.prepare(sql) {
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

    func fetchStemMatches(for word: Word, completion: @escaping ([Word]) -> Void) {
        let sanitizedBookId = word.bookId?.replacingOccurrences(of: "'", with: "''")
        stemQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let dbUrl = try self.getPersistentStoreURL()
                let stemDb = try Connection(dbUrl.path, readonly: true)
                stemDb.busyTimeout = 5

                // Prefer the DB stem for this word id to avoid inconsistencies.
                var dbStem: String? = nil
                if let row = try stemDb.prepare("SELECT stem FROM WORDS WHERE id = ?", word.databaseId).makeIterator().next() {
                    dbStem = row[0] as? String
                }

                    let derivedCandidates = self.englishStemCandidatesIfEnabled(for: word.text)
                let candidates = Array(Set(derivedCandidates)).filter { $0.count >= 3 }

                let cleanDbStem = dbStem?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard cleanDbStem?.isEmpty == false || !candidates.isEmpty else {
                    DispatchQueue.main.async { completion([]) }
                    return
                }

                var stemPredicateParts: [String] = []
                if let cleanDbStem, !cleanDbStem.isEmpty {
                    let sanitizedStem = cleanDbStem.replacingOccurrences(of: "'", with: "''")
                    stemPredicateParts.append("LOWER(W.stem) = LOWER('\(sanitizedStem)')")
                }
                for stem in candidates where stem != cleanDbStem?.lowercased() {
                    let sanitizedStem = stem.replacingOccurrences(of: "'", with: "''")
                    stemPredicateParts.append("LOWER(W.stem) = LOWER('\(sanitizedStem)')")
                }
                let stemPredicates = stemPredicateParts.joined(separator: " OR ")

                var sql = """
                SELECT
                    W.id, W.word, W.stem, W.lang, W.category,
                    (SELECT L2.usage
                     FROM LOOKUPS L2
                     WHERE L2.word_key = W.id AND L2.book_key = B.id
                     ORDER BY L2.timestamp DESC
                     LIMIT 1) as usage,
                    (SELECT MAX(L3.timestamp)
                     FROM LOOKUPS L3
                     WHERE L3.word_key = W.id AND L3.book_key = B.id) as latest_ts,
                    B.id as book_id, B.title as book_title, B.authors as book_authors,
                    (SELECT COUNT(*)
                     FROM LOOKUPS L4
                     WHERE L4.word_key = W.id AND L4.book_key = B.id) as usage_count
                FROM WORDS W
                JOIN LOOKUPS L ON L.word_key = W.id
                JOIN BOOK_INFO B ON L.book_key = B.id
                WHERE (\(stemPredicates))
                """

                if let bookId = sanitizedBookId {
                    sql += " AND B.id != '\(bookId)'"
                }

                sql += """
                 GROUP BY W.id, B.id
                 ORDER BY CASE W.category
                    WHEN 0 THEN 0
                    WHEN 100 THEN 1
                    WHEN -1 THEN 2
                    ELSE 1
                 END, latest_ts DESC
                """

                var results: [Word] = []
                for row in try stemDb.prepare(sql) {
                    let id = row[0] as! String
                    let text = row[1] as! String
                    let stem = row[2] as? String
                    let lang = row[3] as! String
                    let cat = Int(row[4] as! Int64)
                    let usage = row[5] as! String
                    let ts = row[6] as! Int64
                    let bId = row[7] as! String
                    let bTitle = row[8] as! String
                    let bAuthors = row[9] as! String
                    let usageCount = Int(row[10] as! Int64)

                    let status = WordStatus(rawValue: cat) ?? .learning
                    let uiId = "\(id)_\(bId)"

                    results.append(Word(
                        id: uiId,
                        databaseId: id,
                        text: text,
                        stem: stem,
                        language: lang,
                        status: status,
                        usage: usage,
                        allUsages: [WordUsage(text: usage, timestamp: ts)],
                        usageCount: usageCount,
                        bookId: bId,
                        bookTitle: bTitle,
                        bookAuthors: bAuthors,
                        timestamp: ts,
                        stemOtherBookCount: 0
                    ))
                }

                DispatchQueue.main.async {
                    completion(results)
                }
            } catch {
                print("Error fetching stem matches: \(error)")
                DispatchQueue.main.async { completion([]) }
            }
        }
    }
    
    func updateStatus(word: Word, newStatus: WordStatus) {
        updateStatus(words: [word], newStatus: newStatus)
    }
    
    func updateStatus(words: [Word], newStatus: WordStatus, underscore: Bool = true) {
        // Capture old statuses for undo
        let changes = words.map { ($0.databaseId, $0.status) }
        if underscore {
            undoStack.append(UndoAction(changes: changes))
        }
        
        guard let db = db else { return }
        
        let newCategory = newStatus.rawValue
        let dbIds = words.map { $0.databaseId }
        let uiIds = words.map { $0.id }
        
        dbQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let targetWords = self.wordsTable.filter(dbIds.contains(self.w_id))
                try db.run(targetWords.update(self.w_category <- newCategory))
                
                // Update local state
                DispatchQueue.main.async {
                    for (i, w) in self.words.enumerated() {
                        if uiIds.contains(w.id) {
                            var updatedWord = w
                            updatedWord.status = newStatus
                            self.words[i] = updatedWord
                        }
                    }
                    
                    // Refresh book list to update isMastered status
                    self.fetchBooks()
                }
            } catch {
                print("Failed to update status: \(error)")
            }
        }
    }
    func undoLastAction() {
        guard let lastAction = undoStack.popLast() else { return }
        
        guard let db = db else { return }
        
        dbQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                // Group by status to minimize DB calls
                let changesByStatus = Dictionary(grouping: lastAction.changes, by: { $0.oldStatus })
                
                for (status, items) in changesByStatus {
                    let ids = items.map { $0.wordId }
                    let newCategory = status.rawValue
                    let targetWords = self.wordsTable.filter(ids.contains(self.w_id))
                    try db.run(targetWords.update(self.w_category <- newCategory))
                }
                
                // Update local state
                DispatchQueue.main.async {
                    _ = lastAction.changes.map { $0.wordId }
                    let idToStatus = Dictionary(uniqueKeysWithValues: lastAction.changes)
                    
                    for (i, w) in self.words.enumerated() {
                        if let restoredStatus = idToStatus[w.databaseId] {
                            var updatedWord = w
                            updatedWord.status = restoredStatus
                            self.words[i] = updatedWord
                        }
                    }
                    
                    // Refresh book list to update isMastered status
                    self.fetchBooks()
                }
            } catch {
                print("Failed to undo: \(error)")
            }
        }
    }
    
    // MARK: - Preferred Usage Persistence
    
    func savePreferredUsage(wordId: String, usage: String) {
        // Here wordId is the databaseId
        saveSetting(key: "pref_usage_\(wordId)", value: usage)
        
        // Update local memory immediately if possible
        // We look for any word instance with this databaseId
        for i in words.indices {
            if words[i].databaseId == wordId {
                var updatedWord = words[i]
                updatedWord.usage = usage
                words[i] = updatedWord
            }
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
        // Close connection
        db = nil
        stemDb = nil
        
        do {
            let url = try getPersistentStoreURL()
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            
            DispatchQueue.main.async {
                self.books = []
                self.words = []
                self.isDatabaseLoaded = false
                self.errorMessage = nil
            }
        } catch {
            print("Failed to clear database: \(error)")
            DispatchQueue.main.async {
                self.errorMessage = "Failed to clear database: \(error)"
            }
        }
    }
}
