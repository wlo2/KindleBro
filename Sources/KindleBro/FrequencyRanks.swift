import Foundation

// "Rank #N" for English words. Line N of english_ranks.txt is a dictionary form and its other
// spellings, ordered by frequency in Google Books English Fiction (built by scripts/make_ranks.swift).
enum FrequencyRanks {
    // Loaded on first use, which is the first word fetch on the database queue.
    static let english: [String: Int] = {
        guard let url = Bundle.main.url(forResource: "english_ranks", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(text)
    }()

    static func parse(_ text: String) -> [String: Int] {
        var ranks: [String: Int] = [:]
        for (index, line) in text.split(separator: "\n").enumerated() {
            for form in line.split(separator: " ") where ranks[String(form)] == nil {
                ranks[String(form)] = index + 1
            }
        }
        return ranks
    }

    // The row's dictionary form first. Its own spelling covers words the list groups differently:
    // in a sentence "drawing" can be a noun, but the list counts it under "draw".
    static func rank(lemma: String, text: String, language: String) -> Int? {
        guard language.lowercased().hasPrefix("en") else { return nil }
        return english[lemma] ?? english[text.lowercased()]
    }
}
