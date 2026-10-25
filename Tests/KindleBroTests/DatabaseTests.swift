import Foundation
import SQLite
import Testing
@testable import KindleBro

// Minimal Kindle vocab.db schema: same column order in both files, as on device.
private func makeVocabDb(at url: URL, words: [(id: String, category: Int)], bookId: String) throws -> Connection {
    let db = try Connection(url.path)
    try db.execute("""
    CREATE TABLE WORDS (id TEXT PRIMARY KEY, word TEXT, stem TEXT, lang TEXT, category INTEGER DEFAULT 0);
    CREATE TABLE BOOK_INFO (id TEXT PRIMARY KEY, title TEXT, authors TEXT, lang TEXT);
    CREATE TABLE LOOKUPS (id TEXT PRIMARY KEY, word_key TEXT, book_key TEXT, usage TEXT, timestamp INTEGER);
    """)
    try db.run("INSERT INTO BOOK_INFO VALUES (?, 'Book', 'Author', 'en')", bookId)
    for (i, w) in words.enumerated() {
        try db.run("INSERT INTO WORDS VALUES (?, ?, ?, 'en', ?)", w.id, w.id, w.id, w.category)
        try db.run("INSERT INTO LOOKUPS VALUES (?, ?, ?, 'usage', ?)", "\(bookId)-\(w.id)", w.id, bookId, i)
    }
    return db
}

@Test func mergeKeepsLocalStatusAndAddsNewWords() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let library = try makeVocabDb(at: dir.appendingPathComponent("library.sqlite"),
                                  words: [("en:peeve", WordStatus.mastered.rawValue)], bookId: "b1")
    let sourceURL = dir.appendingPathComponent("vocab.db")
    _ = try makeVocabDb(at: sourceURL, words: [("en:peeve", 0), ("en:glib", 0)], bookId: "b1")

    let added = try DatabaseManager.mergeDatabase(sourceURL: sourceURL, into: library)

    #expect(added == 1)
    #expect(try library.scalar("SELECT category FROM WORDS WHERE id = 'en:peeve'") as? Int64 == 100)
    #expect(try library.scalar("SELECT COUNT(*) FROM LOOKUPS") as? Int64 == 2)
    // Source is detached again, so a second import can attach it.
    #expect(try DatabaseManager.mergeDatabase(sourceURL: sourceURL, into: library) == 0)
}

@Test func containsPatternTreatsWildcardsLiterally() throws {
    let db = try Connection(.inMemory)
    func matches(_ text: String, _ search: String) throws -> Bool {
        try db.scalar("SELECT ? LIKE \(DatabaseManager.containsPattern(search))", text) as? Int64 == 1
    }
    #expect(try matches("a_c", "_"))
    #expect(try !matches("abc", "_"))
    #expect(try !matches("abc", "%"))
    #expect(try matches("it's 50% off", "'s 50%"))
    #expect(try matches("back\\slash", "\\"))
}

// Library with book "A" stored twice (b1, b1dup), book "B", and an old-format (1.2) preferred usage.
private func makeLibrary() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("db.sqlite")
    let db = try Connection(url.path)
    try db.execute("""
    CREATE TABLE WORDS (id TEXT PRIMARY KEY, word TEXT, stem TEXT, lang TEXT, category INTEGER DEFAULT 0);
    CREATE TABLE BOOK_INFO (id TEXT PRIMARY KEY, title TEXT, authors TEXT, lang TEXT);
    CREATE TABLE LOOKUPS (id TEXT PRIMARY KEY, word_key TEXT, book_key TEXT, usage TEXT, timestamp INTEGER);
    CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT);
    INSERT INTO BOOK_INFO VALUES ('b1','A','X','en'), ('b1dup','A','X','en'), ('b2','B','Y','en');
    INSERT INTO WORDS VALUES ('en:peeve','peeve','peeve','en',0), ('en:peeved','peeved','peeve','en',0), ('en:glib','glib','glib','en',0);
    INSERT INTO LOOKUPS VALUES ('1','en:peeve','b1','sentence A',1), ('2','en:peeve','b2','sentence B',2),
                               ('3','en:peeved','b1dup','sentence A2',3), ('4','en:glib','b1','glib one',4);
    INSERT INTO settings VALUES ('pref_usage_en:peeve','sentence B');
    """)
    return url
}

@MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    var tries = 0
    while !condition() && tries < 300 {
        try await Task.sleep(for: .milliseconds(10))
        tries += 1
    }
}

@Test func migrationKeysOldPreferredUsageToItsBook() throws {
    let url = try makeLibrary()
    _ = DatabaseManager(storeURL: url)
    let keys = try Connection(url.path).prepare("SELECT key FROM settings").map { $0[0] as! String }
    #expect(keys == ["pref_usage_en:peeve|B_Y"])
}

@MainActor @Test func bookViewMergesDuplicateBookRowsAndKeepsUsagePerBook() async throws {
    UserDefaults.standard.register(defaults: ["enableRelatedWords": true, "enableStemSearch": true])
    let manager = DatabaseManager(storeURL: try makeLibrary())
    try await waitUntil { manager.books.count == 2 }
    let bookA = try #require(manager.books.first { $0.title == "A" })
    #expect(bookA.id == "b1")
    #expect(bookA.wordCount == 3)

    manager.fetchWords(for: bookA.id)
    try await waitUntil { !manager.words.isEmpty }
    #expect(Set(manager.words.map(\.text)) == ["peeve", "peeved", "glib"])
    let peeve = try #require(manager.words.first { $0.text == "peeve" })
    #expect(peeve.usage == "sentence A") // book B's chosen sentence must not leak in
    #expect(peeve.stemOtherBookCount == 1) // book B; the duplicate row of A is not another book
    #expect(manager.words.first { $0.text == "glib" }?.stemOtherBookCount == 0)
}

@MainActor @Test func searchFindsStemMatchesAcrossBooks() async throws {
    UserDefaults.standard.register(defaults: ["enableRelatedWords": true, "enableStemSearch": true])
    let manager = DatabaseManager(storeURL: try makeLibrary())
    manager.fetchWords(for: nil, search: "peeved")
    try await waitUntil { !manager.words.isEmpty }
    #expect(manager.words.contains { $0.text == "peeve" && $0.bookTitle == "B" })
    #expect(manager.words.contains { $0.text == "peeved" && $0.bookTitle == "A" })
    #expect(!manager.words.contains { $0.text == "glib" })
}

@MainActor @Test func failedFirstImportLeavesNoLibraryBehind() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let notADatabase = dir.appendingPathComponent("notes.txt")
    try Data("hello".utf8).write(to: notADatabase)
    let manager = DatabaseManager(storeURL: dir.appendingPathComponent("lib/db.sqlite"))

    let result = await withCheckedContinuation { done in
        manager.importDatabase(from: notADatabase) { done.resume(returning: $0) }
    }
    if case .success = result { Issue.record("import of a text file should fail") }
    #expect(!FileManager.default.fileExists(atPath: manager.storeURL.path))
}

@MainActor @Test func relatedWordsListOtherBooksOnly() async throws {
    UserDefaults.standard.register(defaults: ["enableRelatedWords": true, "enableStemSearch": true])
    let manager = DatabaseManager(storeURL: try makeLibrary())
    try await waitUntil { manager.books.count == 2 }
    manager.fetchWords(for: "b1")
    try await waitUntil { !manager.words.isEmpty }
    let peeve = try #require(manager.words.first { $0.text == "peeve" })

    let related = await withCheckedContinuation { done in
        manager.fetchStemMatches(for: peeve) { done.resume(returning: $0) }
    }
    #expect(related.map(\.bookTitle) == ["B"])
}

private func category(_ url: URL, _ id: String) throws -> Int64? {
    try Connection(url.path).scalar("SELECT category FROM WORDS WHERE id = ?", id) as? Int64
}

@MainActor @Test func undoRestoresWordSharedByTwoRows() async throws {
    let url = try makeLibrary()
    let manager = DatabaseManager(storeURL: url)
    manager.fetchWords(for: nil, search: "peeve")
    try await waitUntil { manager.words.filter { $0.text == "peeve" }.count == 2 }
    let peeveRows = manager.words.filter { $0.text == "peeve" } // book A and book B, same WORDS.id

    manager.updateStatus(words: peeveRows, newStatus: .mastered)
    _ = manager.getSetting(key: "flush") // runs behind the queued write
    #expect(try category(url, "en:peeve") == 100)

    manager.undoLastAction()
    _ = manager.getSetting(key: "flush")
    #expect(try category(url, "en:peeve") == 0)
    #expect(manager.undoStack.isEmpty)
}

@Test func backupCopiesWholeLibrary() throws {
    let manager = DatabaseManager(storeURL: try makeLibrary())
    let target = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: target) }
    try manager.backup(to: target)
    #expect(try Connection(target.path).scalar("SELECT COUNT(*) FROM WORDS") as? Int64 == 3)
}

@MainActor @Test func caseVariantsInOneBookAreOneRowAndChangeTogether() async throws {
    let url = try makeLibrary()
    try Connection(url.path).execute("""
    INSERT INTO WORDS VALUES ('en:Heathen','Heathen','heathen','en',0), ('en:heathen','heathen','heathen','en',0);
    INSERT INTO LOOKUPS VALUES ('5','en:Heathen','b1','Heathen, he said.',5), ('6','en:heathen','b1','you old heathen',6);
    """)
    let manager = DatabaseManager(storeURL: url)
    try await waitUntil { manager.books.count == 2 }
    manager.fetchWords(for: "b1")
    try await waitUntil { !manager.words.isEmpty }

    let heathenRows = manager.words.filter { $0.text == "heathen" }
    #expect(heathenRows.count == 1)
    let heathen = try #require(heathenRows.first)
    #expect(Set(heathen.allDatabaseIds) == ["en:Heathen", "en:heathen"])
    #expect(manager.books.first { $0.title == "A" }?.wordCount == 4)

    manager.updateStatus(words: [heathen], newStatus: .mastered)
    _ = manager.getSetting(key: "flush")
    #expect(try category(url, "en:Heathen") == 100)
    #expect(try category(url, "en:heathen") == 100)
}
