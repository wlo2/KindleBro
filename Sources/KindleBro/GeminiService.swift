import Foundation

struct GeminiRequest: Codable {
    struct Content: Codable {
        struct Part: Codable {
            let text: String
        }
        let parts: [Part]
    }
    let contents: [Content]
}

struct GeminiResponse: Codable {
    struct Candidate: Codable {
        struct Content: Codable {
            struct Part: Codable {
                let text: String
            }
            let parts: [Part]
        }
        let content: Content
    }
    let candidates: [Candidate]
}

class GeminiService: LLMService {
    static let shared = GeminiService()
    
    func generateResponse(prompt: String, model: String, apiKey: String) async throws -> String {
        guard !apiKey.isEmpty else {
            throw NSError(domain: "GeminiService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Gemini API Key is missing."])
        }
        
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = GeminiRequest(contents: [
            GeminiRequest.Content(parts: [
                GeminiRequest.Content.Part(text: prompt)
            ])
        ])
        
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "GeminiService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "API Error: \(errorMsg)"])
        }
        
        let result = try JSONDecoder().decode(GeminiResponse.self, from: data)
        return result.candidates.first?.content.parts.first?.text ?? "No response from Gemini"
    }
    
    func fetchModels(apiKey: String) async throws -> [String] {
        guard !apiKey.isEmpty else { return [] }
        
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(apiKey)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw NSError(domain: "GeminiService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch models"])
        }
        
        struct ModelsResponse: Codable {
            struct Model: Codable { let name: String }
            let models: [Model]
        }
        
        let result = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return result.models.map { $0.name.replacingOccurrences(of: "models/", with: "") }
            .filter { $0.contains("gemini") }
            .sorted()
    }
}
