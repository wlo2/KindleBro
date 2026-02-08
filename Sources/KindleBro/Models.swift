import Foundation

struct Book: Identifiable, Hashable {
    let id: String // BOOK_INFO.id
    let title: String
    let authors: String
    let language: String
    var wordCount: Int = 0
    var isMastered: Bool = false
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
    let databaseId: String // Original WORDS.id for database updates
    let text: String
    let stem: String?
    let language: String
    var status: WordStatus
    var usage: String? // The active/preferred usage text
    var allUsages: [WordUsage] = [] // All available context examples with dates
    var usageCount: Int = 1 // Total count of usages in the database
    let bookId: String? // From BOOK_INFO
    let bookTitle: String? // From BOOK_INFO
    let bookAuthors: String? // From BOOK_INFO
    let timestamp: Int64 // Primary timestamp (often the latest)
    var stemOtherBookCount: Int = 0 // Count of other books sharing the same stem
    
    var date: Date {
        return Date(timeIntervalSince1970: TimeInterval(timestamp / 1000))
    }
    
    var sortedUsages: [WordUsage] {
        return allUsages.sorted(by: { $0.timestamp > $1.timestamp })
    }
}

enum WordStatus: Int {
    case learning = 0
    case mastered = 100
    case ignored = -1
}
