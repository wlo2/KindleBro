import SwiftUI
import UniformTypeIdentifiers

private struct LearningBatchSizeRow: View {
    @Binding var value: Int
    @Binding var text: String

    var body: some View {
        HStack {
            Text("Learning batch size")
            Spacer()
            HStack(spacing: 4) {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 68)
                    .onChange(of: text) { _, newValue in
                        let digits = newValue.filter(\.isNumber)
                        if digits != newValue {
                            text = digits
                            return
                        }
                        if digits.isEmpty {
                            return
                        }
                        if let parsed = Int(digits), parsed > 0 {
                            value = min(parsed, 500)
                            if parsed > 500 { text = "500" } // show what will be saved
                        }
                    }

                Button(action: {
                    value = max(1, value - 1)
                    text = "\(value)"
                }) {
                    Image(systemName: "minus")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)

                Button(action: {
                    value = min(500, value + 1)
                    text = "\(value)"
                }) {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

struct SettingsView: View {
    @AppStorage("autoMasterOnCopy") private var autoMasterOnCopy = true
    @AppStorage("copyRank") private var copyRank = true
    @AppStorage("enableCompletedBooks") private var enableCompletedBooks = true
    @AppStorage("enableRelatedWords") private var enableRelatedWords = true
    @AppStorage("enableStemSearch") private var enableStemSearch = true
    @AppStorage("learningBatchSize") private var learningBatchSize = 15
    @AppStorage("autoSyncOnLaunch") private var autoSyncOnLaunch = true
    @AppStorage("claudeCLIPath") private var claudeCLIPath = "" // empty: not connected
    @AppStorage("claudeModel") private var claudeModel = "" // empty: Claude Code's own default

    // Backup Settings
    @AppStorage("backupEnabled") private var backupEnabled = false
    @AppStorage("backupLocation") private var backupLocation = ""
    
    @State private var localAutoMaster = true
    @State private var localCopyRank = true
    @State private var localEnableCompletedBooks = true
    @State private var localEnableRelatedWords = true
    @State private var localEnableStemSearch = true
    @State private var localLearningBatchSize = 15
    @State private var localLearningBatchSizeText = "15"
    @State private var localAutoSyncOnLaunch = true
    @State private var localClaudeCLIPath = ""
    @State private var localClaudeModel = ""
    @State private var claudeAccount: String? // from the last Connect, e.g. "Claude Pro"
    @State private var claudeError: String?
    @State private var isConnectingClaude = false
    @State private var localBackupEnabled = false
    @State private var localBackupLocation = ""
    
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("General") {
                    Toggle("Sync Kindle on launch when it is connected", isOn: $localAutoSyncOnLaunch)
                        .toggleStyle(.checkbox)
                    Toggle("Mark words as Mastered when copied with prompt", isOn: $localAutoMaster)
                        .toggleStyle(.checkbox)
                    Toggle("Add the frequency rank to copied words", isOn: $localCopyRank)
                        .toggleStyle(.checkbox)
                        .help("Copy, Copy with prompt and Generate flashcards put \"(Rank 18950)\" after the word")
                    Toggle("Enable Completed books", isOn: $localEnableCompletedBooks)
                        .toggleStyle(.checkbox)
                    Toggle("Enable related words", isOn: $localEnableRelatedWords)
                        .toggleStyle(.checkbox)
                    Toggle("Enable stem-based search", isOn: $localEnableStemSearch)
                        .toggleStyle(.checkbox)
                    LearningBatchSizeRow(
                        value: $localLearningBatchSize,
                        text: $localLearningBatchSizeText
                    )
                }
                
                Section("Flashcards") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Generate flashcards with Claude Code")
                            Text(claudeStatusText)
                                .font(.caption)
                                .foregroundStyle(claudeError == nil ? Color.secondary : Color.red)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .help(claudeStatusText)
                        }
                        Spacer()
                        if isConnectingClaude {
                            ProgressView().controlSize(.small)
                        } else if localClaudeCLIPath.isEmpty {
                            Button("Connect to Claude CLI") { connectClaude() }
                        } else {
                            Button("Disconnect") {
                                localClaudeCLIPath = ""
                                claudeAccount = nil
                            }
                        }
                    }
                    // Aliases Claude Code resolves to the latest model of each family
                    Picker("Model", selection: $localClaudeModel) {
                        Text("Claude Code's default").tag("")
                        Text("Fable").tag("fable")
                        Text("Opus").tag("opus")
                        Text("Sonnet").tag("sonnet")
                        Text("Haiku").tag("haiku")
                    }
                    .disabled(localClaudeCLIPath.isEmpty)
                }

                Section("Database Backup") {
                    Toggle("Enable Automatic Backup on Exit", isOn: $localBackupEnabled)
                        .toggleStyle(.checkbox)
                    
                    HStack {
                        Text("Backup Location:")
                        Spacer()
                        if localBackupLocation.isEmpty {
                            Text("Not Set")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(URL(fileURLWithPath: localBackupLocation).lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(localBackupLocation)
                        }
                        Button("Select...") {
                            selectBackupLocation()
                        }
                    }
                    if !localBackupLocation.isEmpty && localBackupEnabled {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("A full backup will be created immediately upon saving if settings changed.")
                            Text("After that, the whole library is copied again every time the app quits.")
                                .bold()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            
            Divider()
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
                
                Spacer()
                
                Button("Save") {
                    autoMasterOnCopy = localAutoMaster
                    copyRank = localCopyRank
                    enableCompletedBooks = localEnableCompletedBooks
                    enableRelatedWords = localEnableRelatedWords
                    enableStemSearch = localEnableStemSearch
                    learningBatchSize = max(1, min(localLearningBatchSize, 500))
                    autoSyncOnLaunch = localAutoSyncOnLaunch
                    claudeCLIPath = localClaudeCLIPath
                    claudeModel = localClaudeModel

                    let locationChanged = localBackupLocation != backupLocation
                    let backupEnabledChanged = localBackupEnabled != backupEnabled
                    
                    backupEnabled = localBackupEnabled
                    backupLocation = localBackupLocation
                    
                    // Trigger immediate backup if enabled and location set, and either setting changed
                    if localBackupEnabled && !localBackupLocation.isEmpty && (locationChanged || backupEnabledChanged) {
                        let db = DatabaseManager.shared
                        do {
                            try db.backup(to: URL(fileURLWithPath: localBackupLocation))
                        } catch {
                            db.appError = .backupError(error.localizedDescription)
                        }
                    }
                    
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding()
        }
        .frame(width: 500, height: 750) // fits all rows, including the backup notes, without scrolling
        .onAppear {
            localAutoMaster = autoMasterOnCopy
            localCopyRank = copyRank
            localEnableCompletedBooks = enableCompletedBooks
            localEnableRelatedWords = enableRelatedWords
            localEnableStemSearch = enableStemSearch
            localLearningBatchSize = learningBatchSize
            localLearningBatchSizeText = "\(learningBatchSize)"
            localAutoSyncOnLaunch = autoSyncOnLaunch
            localClaudeCLIPath = claudeCLIPath
            localClaudeModel = claudeModel
            localBackupEnabled = backupEnabled
            localBackupLocation = backupLocation
        }
    }
    
    private var claudeStatusText: String {
        if let claudeError { return claudeError }
        if localClaudeCLIPath.isEmpty { return "Uses the Claude Code CLI installed on this Mac, with its own sign-in." }
        return "Connected: \(claudeAccount ?? localClaudeCLIPath)"
    }

    // Finds the CLI and checks that it is signed in; Save keeps the connection.
    private func connectClaude() {
        isConnectingClaude = true
        claudeError = nil
        Task {
            let result = await Task.detached { () -> Result<(path: String, account: String), Error> in
                guard let path = ClaudeCLI.find() else {
                    return .failure(UserFacingError("Claude Code CLI not found. Install it, run claude in Terminal to sign in, then connect again."))
                }
                return Result { (path, try ClaudeCLI.account(at: path)) }
            }.value
            isConnectingClaude = false
            switch result {
            case .success(let found):
                localClaudeCLIPath = found.path
                claudeAccount = found.account
            case .failure(let error):
                claudeError = error.localizedDescription
            }
        }
    }

    private func selectBackupLocation() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .database, .database]
        panel.nameFieldStringValue = "KindleBro_Backup.sqlite"
        panel.canCreateDirectories = true
        panel.title = "Select Backup Location"
        
        if panel.runModal() == .OK {
            if let url = panel.url {
                localBackupLocation = url.path
            }
        }
    }
}
