import SwiftUI

let defaultPrompt = """
For a given set of words and usage samples, generate RemNote flashcards in the following format:

word>>3 most frequent translations, ordered by descending frequency, with the most frequent translation wrapped in **bold**. After the translations, add a usage sample enclosed in backticks (``). At least one translation must be derived from the provided usage. If a word has fewer than three frequent translations, list only the available ones.
Each flashcard must be on a new line. Do not add any text, comments, or explanations — output **only** the generated flashcards.

Example:
test>>**translation1**, translation2, translation3 `Usage example`
"""

private struct AppMenuCommands: Commands {
    let dbManager: DatabaseManager
    @Environment(\.openWindow) private var openWindow
    
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About KindleBro") {
                openWindow(id: "about")
            }
        }
        
        CommandGroup(replacing: .importExport) { }
        
        CommandGroup(after: .newItem) {
            Button("Import Database...") {
                dbManager.showImportPicker = true
            }
            Button("Export Database...") {
                dbManager.showExportPicker = true
            }
            Divider()
            Button("Clear Database") {
                dbManager.showClearConfirmation = true
            }
        }
        
        CommandGroup(after: .appSettings) {
            Button("Edit Prompt...") {
                openWindow(id: "promptEditor")
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}

private struct AboutWindow: View {
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "KindleBro"
    }
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.5"
    }
    
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .cornerRadius(18)
            
            Text(appName)
                .font(.title2)
                .bold()
            
            Text("Version \(version)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Link("GitHub", destination: URL(string: "https://github.com/wlo2/KindleBro")!)
                .font(.subheadline)
                .foregroundStyle(.blue)
            
            Text("gggggJJJJJJJJJJJJJEEEEEEEBBBBbbbBDDDDDDDDdddddddDDDDT Industries 2026")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 420, height: 320)
    }
}

private struct PromptEditorWindow: View {
    @AppStorage("customPrompt") private var customPrompt = defaultPrompt
    
    var body: some View {
        // Save to the library here, not in the main window: that one may be closed.
        PromptEditorView(prompt: $customPrompt)
            .onChange(of: customPrompt) { _, newValue in
                DatabaseManager.shared.saveSetting(key: "customPrompt", value: newValue)
            }
    }
}

@main
struct KindleBroApp: App {
    let dbManager = DatabaseManager.shared
    
    init() {
        let defaults = UserDefaults.standard
        // Single source of the setting defaults; the views' @AppStorage fallbacks only apply without this.
        defaults.register(defaults: [
            "enableStemSearch": true,
            "enableRelatedWords": true,
            "enableCompletedBooks": true,
            "autoMasterOnCopy": true,
            "learningBatchSize": 15,
            "customPrompt": defaultPrompt,
        ])
        
        // Settings opens with the cursor in its only text field (batch size). Clear it at the AppKit
        // level: a view-level FocusState fix missed every second open (stale focus state, late subscription).
        // The short delay lets SwiftUI place its default focus first.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { note in
            guard let window = note.object as? NSWindow, window.title.hasSuffix("Settings") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { window.makeFirstResponder(nil) }
        }
        
        // Registered here, not in a view, so it also runs when the main window is closed.
        // queue: nil runs it synchronously, before the app exits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            // No library (e.g. after Clear Database): nothing to back up, and the old backup stays as it is.
            guard DatabaseManager.shared.isDatabaseLoaded, defaults.bool(forKey: "backupEnabled"),
                  let location = defaults.string(forKey: "backupLocation"), !location.isEmpty else { return }
            do {
                try DatabaseManager.shared.backup(to: URL(fileURLWithPath: location))
            } catch {
                // No UI at quit time; ContentView reports it on next launch.
                defaults.set(error.localizedDescription, forKey: "lastBackupError")
            }
        }
    }
    
    var body: some Scene {
        // Window, not WindowGroup: single instance. A second main window would share one word list.
        Window("KindleBro", id: "main") {
            ContentView()
                .environmentObject(dbManager)
        }
        .commands {
            AppMenuCommands(dbManager: dbManager)
        }
        
        Settings {
            SettingsView()
        }
        
        Window("Edit Prompt", id: "promptEditor") {
            PromptEditorWindow()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 600, height: 500)
        
        Window("About KindleBro", id: "about") {
            AboutWindow()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 420, height: 320)
    }
}
