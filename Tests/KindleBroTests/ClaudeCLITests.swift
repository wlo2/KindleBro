import Foundation
import Testing
@testable import KindleBro

private func word(_ text: String, rank: Int? = nil, status: WordStatus = .learning) -> Word {
    Word(id: text, databaseId: "en:\(text)", text: text, lemma: text, status: status,
         usage: "Usage of \(text).", bookId: nil, bookTitle: nil, bookAuthors: nil, timestamp: 0, rank: rank)
}

@Test func claudeInputNumbersTheWordsAfterThePrompt() {
    let input = ClaudeCLI.input(prompt: "Make cards.", words: [word("remit", rank: 18950), word("glance")], withRank: true)
    #expect(input.hasPrefix("Make cards.\n\n[1] remit (Rank 18950)\nUsage of remit.\n\n[2] glance\nUsage of glance.\n\n"))
}

@Test func claudeCardsMapBackToTheirWordsByNumber() throws {
    let words = [word("remit"), word("glance"), word("peeve")]
    let output = #"""
    {"type":"result","is_error":false,"result":"{}","structured_output":{"cards":[
      {"number":2,"card":"glance>>**взгляд** "},
      {"number":1,"card":"remit>>**компетенция**"},
      {"number":9,"card":"stray card with no word"}]}}
    """#
    let cards = try ClaudeCLI.cards(from: Data(output.utf8), words: words)
    #expect(cards == ["remit": "remit>>**компетенция**", "glance": "glance>>**взгляд**"]) // "peeve" was skipped
}

@Test func claudeErrorsAreReportedWithTheirMessage() {
    let output = #"{"type":"result","is_error":true,"result":"Not logged in · Please run /login"}"#
    #expect(throws: UserFacingError.self) { try ClaudeCLI.cards(from: Data(output.utf8), words: [word("remit")]) }
    #expect((try? ClaudeCLI.account(fromStatus: Data(#"{"loggedIn":true,"subscriptionType":"pro"}"#.utf8))) == "Claude Pro")
    #expect(throws: UserFacingError.self) { try ClaudeCLI.account(fromStatus: Data(#"{"loggedIn":false}"#.utf8)) }
}

@Test func ignoredCardsStayOutAfterTheListShowsAnotherBook() {
    var panel = FlashcardPanel(words: [word("remit"), word("glance"), word("peeve", status: .mastered)])
    panel.cards = ["remit": "remit card", "glance": "glance card", "peeve": "peeve card"]
    panel.update(from: [word("remit"), word("glance", status: .ignored), word("peeve", status: .mastered)])
    panel.update(from: [word("weevil")]) // another book is open now
    #expect(panel.kept.map(\.card) == ["remit card", "peeve card"])
    #expect(panel.statusAfterUnignore(of: "glance") == .learning)
    #expect(panel.statusAfterUnignore(of: "peeve") == .mastered)
}

@Test func closingRightAwayStopsClaude() async throws {
    let fake = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-\(UUID())")
    try "#!/bin/sh\nexec sleep 30\n".write(to: fake, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    defer { try? FileManager.default.removeItem(at: fake) }

    let start = Date()
    let generation = Task {
        try await ClaudeCLI.generate(prompt: "Make cards.", words: [word("remit")], withRank: true, model: "", cliPath: fake.path)
    }
    generation.cancel() // before the CLI has started
    await #expect(throws: CancellationError.self) { try await generation.value }
    #expect(Date().timeIntervalSince(start) < 10) // the 30-second "generation" was stopped
}
