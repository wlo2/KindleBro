import Foundation

// An error whose message is shown to the user as it is.
struct UserFacingError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Book: Identifiable, Hashable {
    let id: String // BOOK_INFO.id
    let title: String
    let authors: String
    var wordCount: Int = 0
    var learningWordCount: Int = 0
    var isMastered: Bool = false
    var dateAdded: Int64 = 0 // ms, like lookup timestamps: the sync that brought the book in

    var sidebarCountText: String {
        if !isMastered && learningWordCount < wordCount {
            return "\(learningWordCount)/\(wordCount)"
        }
        return "\(wordCount)"
    }
}

// Sidebar book order; stored in UserDefaults as "bookSort"
enum BookSort: String {
    case dateAdded, alphabetical
}

struct WordUsage: Identifiable, Hashable {
    var id: String { text } // Using text as ID since it's unique in context of a word in a book
    let text: String
    let timestamp: Int64
    
    var date: Date {
        return Date(timeIntervalSince1970: TimeInterval(timestamp / 1000))
    }
}

struct Word: Identifiable, Hashable {
    let id: String // Unique identifier for SwiftUI (e.g., wordId_bookTitleHash)
    var databaseId: String // Original WORDS.id for database updates
    var databaseIds: [String] = []
    var databaseStatuses: [String: WordStatus] = [:]
    var text: String
    let lemma: String // dictionary form; a book's forms with the same lemma show as one row
    var status: WordStatus
    var usage: String? // The active/preferred usage text
    var allUsages: [WordUsage] = [] // All available context examples with dates
    var usageCount: Int = 1 // Total count of usages in the database
    let bookId: String? // From BOOK_INFO
    let bookTitle: String? // From BOOK_INFO
    let bookAuthors: String? // From BOOK_INFO
    var timestamp: Int64 // Primary timestamp (often the latest)
    var relatedBookCount: Int = 0 // Count of other books sharing the same stem
    var rank: Int? = nil // frequency rank of the dictionary form in English fiction; nil if not English or rare
    
    var date: Date {
        return Date(timeIntervalSince1970: TimeInterval(timestamp / 1000))
    }
    
    // Copy, Copy with prompt, Copy all and Generate flashcards: "remit (Rank 18950)" over the usage,
    // so a prompt can put the rank on the card. Settings can leave the rank out.
    func clipboardText(withRank: Bool) -> String {
        let rankText = withRank ? rank.map { " (Rank \($0))" } : nil
        return "\(text)\(rankText ?? "")\n\(usage ?? "")"
    }

    // Duplicate BOOK_INFO rows of one book share this key
    var bookKey: String { "\(bookTitle ?? "")_\(bookAuthors ?? "")" }

    var sortedUsages: [WordUsage] {
        return allUsages.sorted(by: { $0.timestamp > $1.timestamp })
    }
}

enum WordStatus: Int {
    case learning = 0
    case mastered = 100
    case ignored = -1

    // List order: Learning, then Mastered, then Ignored
    var sortRank: Int {
        switch self {
        case .learning: return 0
        case .mastered: return 1
        case .ignored: return 2
        }
    }
}
