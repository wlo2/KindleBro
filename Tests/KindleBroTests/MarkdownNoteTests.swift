import Foundation
import Testing
@testable import KindleBro

@Test func noteBlockGroupsCardsUnderTheirBookTitle() {
    let cards = [(book: "Crystal World", card: "weevil -> **долгоносик**"),
                 (book: "Shroud", card: "remit -> **компетенция**"),
                 (book: "Crystal World", card: "steadfastness -> **стойкость**")]
    #expect(MarkdownNote.block(cards, withHeadings: true) == """
        # Crystal World

        weevil -> **долгоносик**

        steadfastness -> **стойкость**

        # Shroud

        remit -> **компетенция**
        """)
    #expect(MarkdownNote.block(cards, withHeadings: false)
            == "weevil -> **долгоносик**\n\nremit -> **компетенция**\n\nsteadfastness -> **стойкость**")
}

@Test func noteKeepsItsTextAndFrontMatter() {
    func added(_ text: String, atTop: Bool) -> String {
        let parts = MarkdownNote.insertion(of: "CARDS", into: text, atTop: atTop)
        return String(parts.before) + parts.added + String(parts.after)
    }
    #expect(added("---\ntags: [eng]\n---\n# Old\n", atTop: true) == "---\ntags: [eng]\n---\nCARDS\n\n# Old\n")
    #expect(added("# Old\n", atTop: true) == "CARDS\n\n# Old\n")
    #expect(added("---\nnot front matter", atTop: true) == "CARDS\n\n---\nnot front matter")
    #expect(added("---\ntags: [eng]\n---", atTop: true) == "---\ntags: [eng]\n---\nCARDS\n") // no final newline
    #expect(added("", atTop: true) == "CARDS\n")
    #expect(added("# Old", atTop: false) == "# Old\n\nCARDS\n")
    #expect(added("# Old\n", atTop: false) == "# Old\n\nCARDS\n")
    #expect(added("# Old\r\n\r\n", atTop: false) == "# Old\r\n\r\nCARDS\n")
    #expect(added("", atTop: false) == "CARDS\n")
}

@Test func addingToANoteFileOnlyAddsText() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kb-note-\(UUID()).md")
    defer { try? FileManager.default.removeItem(at: url) }
    try "---\ntags: [eng]\n---\n# Old\n".write(to: url, atomically: true, encoding: .utf8)
    try MarkdownNote.add("TOP", to: url, atTop: true)
    try MarkdownNote.add("BOTTOM", to: url, atTop: false)
    #expect(try String(contentsOf: url, encoding: .utf8) == "---\ntags: [eng]\n---\nTOP\n\n# Old\n\nBOTTOM\n")

    let notText = Data([0x23, 0x20, 0xFF, 0xFE, 0x0A]) // "# " and two bytes that aren't UTF-8
    try notText.write(to: url)
    #expect(throws: UserFacingError.self) { try MarkdownNote.add("TOP", to: url, atTop: true) }
    #expect(try Data(contentsOf: url) == notText)
}
