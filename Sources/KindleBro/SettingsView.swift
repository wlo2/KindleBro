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
    @AppStorage("enableCompletedBooks") private var enableCompletedBooks = true
    @AppStorage("enableRelatedWords") private var enableRelatedWords = true
    @AppStorage("enableStemSearch") private var enableStemSearch = true
    @AppStorage("learningBatchSize") private var learningBatchSize = 15
    
    // Backup Settings
    @AppStorage("backupEnabled") private var backupEnabled = false
    @AppStorage("backupLocation") private var backupLocation = ""
    
    @State private var localAutoMaster = true
    @State private var localEnableCompletedBooks = true
    @State private var localEnableRelatedWords = true
    @State private var localEnableStemSearch = true
    @State private var localLearningBatchSize = 15
    @State private var localLearningBatchSizeText = "15"
    @State private var localBackupEnabled = false
    @State private var localBackupLocation = ""
    
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("General") {
                    Toggle("Mark words as Mastered when copied with prompt", isOn: $localAutoMaster)
                        .toggleStyle(.checkbox)
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
                    enableCompletedBooks = localEnableCompletedBooks
                    enableRelatedWords = localEnableRelatedWords
                    enableStemSearch = localEnableStemSearch
                    learningBatchSize = max(1, min(localLearningBatchSize, 500))
                    
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
        .frame(width: 500, height: 540) // fits all rows, including the backup notes, without scrolling
        .onAppear {
            localAutoMaster = autoMasterOnCopy
            localEnableCompletedBooks = enableCompletedBooks
            localEnableRelatedWords = enableRelatedWords
            localEnableStemSearch = enableStemSearch
            localLearningBatchSize = learningBatchSize
            localLearningBatchSizeText = "\(learningBatchSize)"
            localBackupEnabled = backupEnabled
            localBackupLocation = backupLocation
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
