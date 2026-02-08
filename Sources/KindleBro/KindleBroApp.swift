import SwiftUI

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
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
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
            
            Text("gggggBBbbbBBBBBJEEEEDDDDDdddddddddddDDDDDDDDD Industries 2026")
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
    @AppStorage("customPrompt") private var customPrompt = """
For a given set of words and usage samples, generate RemNote flashcards in the following format:

word>>3 most frequent translations, ordered by descending frequency, with the most frequent translation wrapped in **bold**. After the translations, add a usage sample enclosed in backticks (``). At least one translation must be derived from the provided usage. If a word has fewer than three frequent translations, list only the available ones.
Each flashcard must be on a new line. Do not add any text, comments, or explanations — output **only** the generated flashcards.

Example:
test>>**translation1**, translation2, translation3 `Usage example`
"""
    
    var body: some View {
        PromptEditorView(prompt: $customPrompt)
    }
}

@main
struct KindleBroApp: App {
    let dbManager = DatabaseManager.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(dbManager)
        }
        .commands {
            AppMenuCommands(dbManager: dbManager)
        }
        
        Settings {
            SettingsView()
        }
        
        // Window for AI Generation output
        WindowGroup("AI Flashcards", id: "generation", for: String.self) { $prompt in
            GenerationView(prompt: prompt ?? "")
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 600, height: 500)
        
        WindowGroup("Edit Prompt", id: "promptEditor") {
            PromptEditorWindow()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 600, height: 500)
        
        WindowGroup("About KindleBro", id: "about") {
            AboutWindow()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 420, height: 320)
    }
}
