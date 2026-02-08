import SwiftUI

struct SettingsView: View {
    @AppStorage("autoMasterOnCopy") private var autoMasterOnCopy = true
    @AppStorage("enableCompletedBooks") private var enableCompletedBooks = true
    @AppStorage("enableRelatedWords") private var enableRelatedWords = true
    @AppStorage("enableStemSearch") private var enableStemSearch = true
    @AppStorage("openAIKey") private var openAIApiKey = ""
    @AppStorage("geminiKey") private var geminiApiKey = ""
    
    // Updated Settings
    @AppStorage("activeProvider") private var activeProvider: LLMProvider = .openai
    @AppStorage("openaiModel") private var openaiModel: String = "gpt-4o"
    @AppStorage("geminiModel") private var geminiModel: String = "gemini-2.0-flash"
    
    @State private var localAutoMaster = true
    @State private var localEnableCompletedBooks = true
    @State private var localEnableRelatedWords = true
    @State private var localEnableStemSearch = true
    @State private var localOpenAIKey = ""
    @State private var localGeminiKey = ""
    @State private var localProvider: LLMProvider = .openai
    @State private var localOpenAIModel: String = ""
    @State private var localGeminiModel: String = ""
    
    @State private var models: [String] = []
    @State private var isLoadingModels = false
    
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
                }
                
                Section("AI Provider") {
                    Picker("Active Provider", selection: $localProvider) {
                        ForEach(LLMProvider.allCases, id: \.self) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: localProvider) { _, _ in
                        fetchModels()
                    }
                }
                
                if localProvider == .openai {
                    Section("OpenAI Configuration") {
                        LabeledContent("API Key") {
                            SecureField("Enter Key", text: $localOpenAIKey)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: localOpenAIKey) { _, _ in
                                    fetchModels()
                                }
                        }
                        
                        Picker("Model", selection: $localOpenAIModel) {
                            if models.isEmpty {
                                Text(localOpenAIModel).tag(localOpenAIModel)
                            }
                            ForEach(models, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .disabled(isLoadingModels || localOpenAIKey.isEmpty)
                        
                        if isLoadingModels {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                } else {
                    Section("Gemini Configuration") {
                        LabeledContent("API Key") {
                            SecureField("Enter Key", text: $localGeminiKey)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: localGeminiKey) { _, _ in
                                    fetchModels()
                                }
                        }
                        
                        Picker("Model", selection: $localGeminiModel) {
                            if models.isEmpty {
                                Text(localGeminiModel).tag(localGeminiModel)
                            }
                            ForEach(models, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .disabled(isLoadingModels || localGeminiKey.isEmpty)
                        
                        if isLoadingModels {
                            ProgressView()
                                .controlSize(.small)
                        }
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
                    activeProvider = localProvider
                    openaiModel = localOpenAIModel
                    geminiModel = localGeminiModel
                    
                    // Update OpenAI Key
                    if localOpenAIKey != "****************" {
                        openAIApiKey = localOpenAIKey
                    }
                    
                    // Update Gemini Key
                    if localGeminiKey != "****************" {
                        geminiApiKey = localGeminiKey
                    }
                    
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding()
        }
        .frame(width: 500, height: 520)
        .onAppear {
            localAutoMaster = autoMasterOnCopy
            localEnableCompletedBooks = enableCompletedBooks
            localEnableRelatedWords = enableRelatedWords
            localEnableStemSearch = enableStemSearch
            localProvider = activeProvider
            localOpenAIModel = openaiModel
            localGeminiModel = geminiModel
            localOpenAIKey = openAIApiKey.isEmpty ? "" : "****************"
            localGeminiKey = geminiApiKey.isEmpty ? "" : "****************"
            fetchModels()
        }
    }
    
    private func fetchModels() {
        let apiKey = (localProvider == .openai) 
            ? (localOpenAIKey == "****************" ? openAIApiKey : localOpenAIKey)
            : (localGeminiKey == "****************" ? geminiApiKey : localGeminiKey)
            
        guard !apiKey.isEmpty else { 
            models = []
            return 
        }
        
        isLoadingModels = true
        Task {
            do {
                let service = LLMServiceFactory.service(for: localProvider)
                let fetchedModels = try await service.fetchModels(apiKey: apiKey)
                await MainActor.run {
                    self.models = fetchedModels
                    self.isLoadingModels = false
                    
                    // Update local model selection if it's empty or invalid
                    if localProvider == .openai {
                        if localOpenAIModel.isEmpty || !fetchedModels.contains(localOpenAIModel) {
                            localOpenAIModel = fetchedModels.first ?? "gpt-4o"
                        }
                    } else {
                        if localGeminiModel.isEmpty || !fetchedModels.contains(localGeminiModel) {
                            localGeminiModel = fetchedModels.first ?? "gemini-2.0-flash"
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.isLoadingModels = false
                }
            }
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
