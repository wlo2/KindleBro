import Foundation
import NaturalLanguage

// Only Foundation and NaturalLanguage here: scripts/make_ranks.swift compiles this file too,
// so the rank list groups word forms exactly like the app does.
extension DatabaseManager {
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
}
