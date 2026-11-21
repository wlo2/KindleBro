import Foundation
import os

// Flashcard generation through the Claude Code CLI that the user installed and signed in to.
// KindleBro never reads or stores the login: the CLI uses its own (a Claude subscription or an API key).
enum ClaudeCLI {
    // An empty folder, so the CLI loads no project CLAUDE.md, hooks or MCP servers. Made again for
    // each run: macOS deletes temporary items unused for a few days, and the app may stay open longer.
    private static var workDirectory: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KindleBro-claude")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // Apps opened from Finder don't get the shell's PATH: try the usual install places, then a login shell.
    static func find() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let usual = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let path = usual.first(where: FileManager.default.isExecutableFile(atPath:)) { return path }
        guard let out = try? run("/bin/zsh", ["-lc", "command -v claude"]), out.status == 0 else { return nil }
        let path = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    // "Claude Pro" for a signed-in CLI; throws with what to do otherwise.
    static func account(at path: String) throws -> String {
        try account(fromStatus: run(path, ["auth", "status"]).stdout)
    }

    static func account(fromStatus data: Data) throws -> String {
        struct Status: Decodable { let loggedIn: Bool; let subscriptionType: String?; let authMethod: String? }
        guard let status = try? JSONDecoder().decode(Status.self, from: data) else {
            throw UserFacingError("Couldn't read the Claude Code sign-in. Update Claude Code and try again.")
        }
        guard status.loggedIn else {
            throw UserFacingError("Claude Code isn't signed in. Run claude in Terminal, sign in, then connect again.")
        }
        if let plan = status.subscriptionType, !plan.isEmpty { return "Claude \(plan.capitalized)" }
        return status.authMethod ?? "signed in"
    }

    // model: an alias such as "sonnet", or empty for Claude Code's own default.
    static func generate(prompt: String, words: [Word], withRank: Bool, model: String,
                         cliPath: String) async throws -> [Word.ID: String] {
        guard FileManager.default.isExecutableFile(atPath: cliPath) else {
            throw UserFacingError("Claude Code isn't at \(cliPath) any more. Connect again in Settings.")
        }
        let process = Process()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let arguments = ["-p", "--output-format", "json", "--tools", "", "--strict-mcp-config", "--no-session-persistence",
                         "--system-prompt", "You write flashcards for a language learner. Follow the user's format exactly.",
                         "--json-schema", cardsSchema] + (model.isEmpty ? [] : ["--model", model])
        let input = Data(input(prompt: prompt, words: words, withRank: withRank).utf8)
        let out = try await withTaskCancellationHandler {
            try await Task.detached {
                try run(cliPath, arguments, input: input, process: process, isCancelled: { cancelled.withLock { $0 } })
            }.value
        } onCancel: {
            // Flag first: run() checks it right after the launch, so a Close before the launch still stops it.
            cancelled.withLock { $0 = true }
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        if out.stdout.isEmpty {
            let message = String(decoding: out.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw UserFacingError(message.isEmpty ? "Claude Code exited with code \(out.status)." : message)
        }
        return try cards(from: out.stdout, words: words)
    }

    // The same text as Copy with prompt, with the words numbered so each card maps back to its word.
    static func input(prompt: String, words: [Word], withRank: Bool) -> String {
        let entries = words.enumerated()
            .map { "[\($0.offset + 1)] \($0.element.clipboardText(withRank: withRank))" }.joined(separator: "\n\n")
        return """
        \(prompt)

        \(entries)

        Return one card per word in "cards": "number" is the word's number in square brackets, \
        "card" is its flashcard exactly in the format above, without the number.
        """
    }

    static let cardsSchema = #"{"type":"object","properties":{"cards":{"type":"array","items":{"type":"object","properties":{"number":{"type":"integer"},"card":{"type":"string"}},"required":["number","card"],"additionalProperties":false}}},"required":["cards"],"additionalProperties":false}"#

    // Reads the CLI's JSON result. Words the model skipped get no card.
    static func cards(from output: Data, words: [Word]) throws -> [Word.ID: String] {
        struct Result: Decodable {
            struct Cards: Decodable { let cards: [Card] }
            struct Card: Decodable { let number: Int; let card: String }
            let is_error: Bool?
            let result: String?
            let structured_output: Cards?
        }
        guard let result = try? JSONDecoder().decode(Result.self, from: output) else {
            throw UserFacingError("Claude Code returned something KindleBro can't read.")
        }
        if result.is_error == true { throw UserFacingError(result.result ?? "Claude Code reported an error.") }
        guard let cards = result.structured_output?.cards else {
            throw UserFacingError(result.result.map { "Claude Code returned no flashcards: \($0)" } ?? "Claude Code returned no flashcards.")
        }
        var byWord: [Word.ID: String] = [:]
        for card in cards where words.indices.contains(card.number - 1) {
            byWord[words[card.number - 1].id] = card.card.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return byWord
    }

    private static func run(_ path: String, _ arguments: [String], input: Data? = nil, process: Process = Process(),
                            isCancelled: () -> Bool = { false }) throws -> (status: Int32, stdout: Data, stderr: Data) {
        let folder = workDirectory
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        // An npm-installed CLI starts with "#!/usr/bin/env node", so node must be on PATH.
        var environment = ProcessInfo.processInfo.environment
        let dir = (path as NSString).deletingLastPathComponent
        environment["PATH"] = "\(dir):/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment

        // Input from a file, not a pipe: writing to a pipe the CLI has closed would kill the app (SIGPIPE).
        var inputFile: URL?
        if let input {
            let file = folder.appendingPathComponent(UUID().uuidString)
            try input.write(to: file)
            inputFile = file
            process.standardInput = try FileHandle(forReadingFrom: file)
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        defer { if let inputFile { try? FileManager.default.removeItem(at: inputFile) } }

        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        if isCancelled(), process.isRunning { process.terminate() }
        // Read both pipes at once, so a full stderr buffer can't stall the CLI.
        var errorData = Data()
        let errorRead = DispatchGroup()
        errorRead.enter()
        DispatchQueue.global().async {
            errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            errorRead.leave()
        }
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        errorRead.wait()
        process.waitUntilExit()
        return (process.terminationStatus, outputData, errorData)
    }
}
