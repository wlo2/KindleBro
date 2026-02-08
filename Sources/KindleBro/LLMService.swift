import Foundation

enum LLMProvider: String, CaseIterable, Codable {
    case openai = "OpenAI"
    case gemini = "Gemini"
}

protocol LLMService {
    func generateResponse(prompt: String, model: String, apiKey: String) async throws -> String
    func fetchModels(apiKey: String) async throws -> [String]
}

class LLMServiceFactory {
    static func service(for provider: LLMProvider) -> LLMService {
        switch provider {
        case .openai:
            return OpenAIService.shared
        case .gemini:
            return GeminiService.shared
        }
    }
}
