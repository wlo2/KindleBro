import SwiftUI

struct GenerationView: View {
    let prompt: String
    @AppStorage("openAIKey") private var openAIApiKey = ""
    @AppStorage("geminiKey") private var geminiApiKey = ""
    @AppStorage("activeProvider") private var activeProvider: LLMProvider = .openai
    @AppStorage("openaiModel") private var openaiModel: String = "gpt-4o"
    @AppStorage("geminiModel") private var geminiModel: String = "gemini-2.0-flash"
    
    @State private var output = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        VStack {
            if isLoading {
                VStack(spacing: 15) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Generating flashcards...")
                        .font(.headline)
                }
                .padding()
            } else if let error = errorMessage {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 50))
                        .foregroundColor(.red)
                    Text(error)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Retry") {
                        generate()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("AI Output (\(activeProvider.rawValue))")
                            .font(.headline)
                        Spacer()
                        Button(action: {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(output, forType: .string)
                        }) {
                            Label("Copy Result", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.blue)
                        .disabled(output.isEmpty)
                    }
                    .padding()
                    .background(Color(NSColor.windowBackgroundColor))
                    
                    Divider()
                    
                    ScrollView {
                        Text(output)
                            .textSelection(.enabled)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
        }
        .navigationTitle("AI Flashcards")
        .frame(minWidth: 600, minHeight: 500)
        .onAppear {
            generate()
        }
    }
    
    private func generate() {
        guard !isLoading else { return }
        
        let apiKey = (activeProvider == .openai) ? openAIApiKey : geminiApiKey
        let model = (activeProvider == .openai) ? openaiModel : geminiModel
        
        if apiKey.isEmpty {
            errorMessage = "Error: No API key found for \(activeProvider.rawValue). Please provide it in Settings."
            return
        }
        
        isLoading = true
        errorMessage = nil
        output = ""
        
        Task {
            do {
                let service = LLMServiceFactory.service(for: activeProvider)
                let response = try await service.generateResponse(prompt: prompt, model: model, apiKey: apiKey)
                
                await MainActor.run {
                    output = response
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}
