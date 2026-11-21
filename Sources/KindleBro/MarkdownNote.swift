import Foundation

// Adds generated flashcards to a Markdown note (an Obsidian note, say) without changing the text already in it.
enum MarkdownNote {
    // Cards are separated by a blank line, as in Copy flashcards. With headings, "# Book title" goes over
    // each book's cards, books in the order their first card appears.
    static func block(_ cards: [(book: String, card: String)], withHeadings: Bool) -> String {
        guard withHeadings else { return cards.map(\.card).joined(separator: "\n\n") }
        var books: [String] = []
        var byBook: [String: [String]] = [:]
        for (book, card) in cards {
            if byBook[book] == nil { books.append(book) }
            byBook[book, default: []].append(card)
        }
        return books.map { (["# \($0)"] + byBook[$0]!).joined(separator: "\n\n") }.joined(separator: "\n\n")
    }

    // The note split around the added text. At the top goes below YAML front matter, so the note's
    // properties keep working. Blank lines keep the cards apart from the text around them.
    static func insertion(of block: String, into text: String, atTop: Bool)
        -> (before: Substring, added: String, after: Substring) {
        if atTop {
            let end = frontMatterEnd(text)
            let head = text[..<end], rest = text[end...]
            // A note that is only front matter may lack the newline after its closing "---"
            let lineBreak = head.isEmpty || head.last!.isNewline ? "" : "\n"
            return (head, lineBreak + block + (rest.isEmpty ? "\n" : "\n\n"), rest)
        }
        let endingNewlines = text.reversed().prefix(while: \.isNewline).count // "\r\n" counts as one
        let gap = text.isEmpty ? "" : String(repeating: "\n", count: max(0, 2 - endingNewlines))
        return (text[...], gap + block + "\n", text[text.endIndex...])
    }

    // The note's text. Refuses a note that isn't UTF-8: decoding would replace its other bytes,
    // and writing them back would change the note.
    static func read(_ url: URL) throws -> String {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw UserFacingError("Couldn't read \(url.lastPathComponent). If it moved, choose it again from the list next to Append.")
        }
        let text = String(decoding: data, as: UTF8.self)
        guard Data(text.utf8) == data else {
            throw UserFacingError("\(url.lastPathComponent) isn't UTF-8 text, so KindleBro won't change it.")
        }
        return text
    }

    // Reads the note again, so an edit made while the preview was open is kept.
    static func add(_ block: String, to url: URL, atTop: Bool) throws {
        let parts = insertion(of: block, into: try read(url), atTop: atTop)

        if atTop {
            // Written to a copy that then replaces the note in one step, keeping its attributes:
            // a failure halfway leaves the note as it was.
            // shortcut: an edit saved in the instant between this read and the replace is lost; fine for a note
            // edited by hand, use file coordination if a sync tool starts writing the note in the background.
            let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                     appropriateFor: url, create: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let copy = folder.appendingPathComponent(url.lastPathComponent)
            try Data((parts.before + parts.added + parts.after).utf8).write(to: copy)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: copy)
        } else {
            // Only the new text is written, after the end: the note's own text is never rewritten.
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(parts.added.utf8))
        }
    }

    // Where the text after "---" front matter starts; the start of the note if it has none.
    private static func frontMatterEnd(_ text: String) -> String.Index {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)[...]
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return text.startIndex }
        lines = lines.dropFirst()
        guard let close = lines.first(where: { ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces)) })
        else { return text.startIndex }
        // Past the closing line and its newline, if it has one
        return close.endIndex < text.endIndex ? text.index(after: close.endIndex) : text.endIndex
    }
}
