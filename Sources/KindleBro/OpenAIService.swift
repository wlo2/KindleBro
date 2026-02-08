import Foundation

struct OpenAIRequest: Codable {
    let model: String
    let messages: [OpenAIMessage]
}

struct OpenAIMessage: Codable {
    let role: String
    let content: String
}

struct OpenAIResponse: Codable {
    struct Choice: Codable {
        let message: OpenAIMessage
    }
    let choices: [Choice]
}

class OpenAIService: LLMService {
    static let shared = OpenAIService()
    
    func generateResponse(prompt: String, model: String, apiKey: String) async throws -> String {
        guard !apiKey.isEmpty else {
            throw NSError(domain: "OpenAIService", code: 1, userInfo: [NSLocalizedDescriptionKey: "OpenAI API Key is missing. Please set it in Settings."])
        }
        
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let body = OpenAIRequest(
            model: model,
            messages: [
                OpenAIMessage(role: "user", content: prompt)
            ]
        )
        
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "OpenAIService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "API Error: \(errorMsg)"])
        }
        
        let result = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        return result.choices.first?.message.content ?? "No response from AI"
    }
    
    func fetchModels(apiKey: String) async throws -> [String] {
        guard !apiKey.isEmpty else { return [] }
        
        let url = URL(string: "https://api.openai.com/v1/models")!
        var request = URLRequest(url: url)
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw NSError(domain: "OpenAIService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch models"])
        }
        
        struct ModelsResponse: Codable {
            struct Model: Codable { let id: String }
            let data: [Model]
        }
        
        let result = try JSONDecoder().decode(ModelsResponse.self, from: data)
        // Filter to only include chat models for better UX
        return result.data.map { $0.id }
            .filter { $0.contains("gpt") }
            .sorted()
    }
}
