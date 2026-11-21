// Builds Resources/english_ranks.txt: English dictionary forms ordered by how often they occur in fiction.
// Line N is rank N: the dictionary form first, then its other spellings ("see saw seen seeing sees").
//
// Source: Google Books Ngram Viewer data, version 3 (2020-02-17), English Fiction 1-grams, CC BY 3.0.
// http://storage.googleapis.com/books/ngrams/books/20200217/eng-fiction/1-00000-of-00001.gz (940 MB)
// Each line of it: word TAB year,count,books TAB year,count,books ...
//
// Run from the repo root:
//   swiftc -O scripts/make_ranks.swift Sources/KindleBro/Lemma.swift -o /tmp/make_ranks
//   gunzip -c 1-00000-of-00001.gz | /tmp/make_ranks > Resources/english_ranks.txt

import Foundation

final class DatabaseManager {} // stand-in for the app's class, which Lemma.swift extends

@main // swiftc allows top-level code only in main.swift, and this builds with Lemma.swift
enum MakeRanks {
    static func main() {
        let years = 1900...2019 // older scans are full of OCR errors such as "fhe" for "the" (long s)
        let formsToGroup = 400_000 // most frequent spellings; below that it is mostly names, typos and OCR errors
        let ranksToKeep = 150_000

        // 1. Count each spelling, case folded, over the chosen years.
        var counts: [String: Int] = [:]
        while let line = readLine(strippingNewline: true) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let token = line[..<tab]
            // Letters only, like the app's lemma(): skips numbers, punctuation and POS-tagged copies ("run_VERB").
            guard token.unicodeScalars.allSatisfy(CharacterSet.letters.contains) else { continue }

            var total = 0, year = 0, count = 0, field = 0
            for byte in line[line.index(after: tab)...].utf8 {
                switch byte {
                case UInt8(ascii: "\t"):
                    if years.contains(year) { total += count }
                    year = 0; count = 0; field = 0
                case UInt8(ascii: ","):
                    field += 1
                case UInt8(ascii: "0")...UInt8(ascii: "9"):
                    let digit = Int(byte - UInt8(ascii: "0"))
                    if field == 0 { year = year * 10 + digit } else if field == 1 { count = count * 10 + digit }
                default:
                    break
                }
            }
            if years.contains(year) { total += count }
            if total > 0 { counts[token.lowercased(), default: 0] += total }
        }

        // 2. Group the most frequent spellings under their dictionary form, the way the app groups a book's words.
        var lemmaCounts: [String: Int] = [:]
        var forms: [String: [String]] = [:]
        let frequent = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(formsToGroup)
        for (form, count) in frequent {
            let lemma = DatabaseManager.lemma(word: form, language: "en", kindleStem: nil, usage: nil)
            lemmaCounts[lemma, default: 0] += count
            if form != lemma { forms[lemma, default: []].append(form) }
        }

        // 3. Most frequent first; ties alphabetical, so the output is the same on every run.
        let ranked = lemmaCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(ranksToKeep)
        for (lemma, count) in ranked {
            print(([lemma] + (forms[lemma] ?? [])).joined(separator: " "))
            FileHandle.standardError.write("\(lemma)\t\(count)\n".data(using: .utf8)!) // counts, for checking the cut-offs
        }
    }
}
