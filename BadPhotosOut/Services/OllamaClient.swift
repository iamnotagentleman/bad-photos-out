import Foundation

enum OllamaError: LocalizedError {
    case invalidURL
    case unreachable(String)
    case httpStatus(Int, String)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Ollama URL is invalid."
        case .unreachable(let detail): return "Cannot reach Ollama: \(detail)"
        case .httpStatus(let code, let body): return "Ollama returned HTTP \(code): \(body)"
        case .malformedResponse(let detail): return "Could not parse Ollama response: \(detail)"
        }
    }
}

struct OllamaModelInfo: Hashable, Identifiable {
    let name: String
    var id: String { name }
}

struct AnalysisOutcome: Sendable {
    let result: AnalysisResult
    let rawResponse: String
    let thinking: String?
}

actor OllamaClient {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    func listModels(baseURL: String) async throws -> [OllamaModelInfo] {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?
            .appendingPathComponent("api/tags") else {
            throw OllamaError.invalidURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OllamaError.unreachable("no HTTP response")
            }
            guard http.statusCode == 200 else {
                throw OllamaError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            struct TagsResponse: Decodable {
                struct Model: Decodable { let name: String }
                let models: [Model]
            }
            let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
            return decoded.models.map { OllamaModelInfo(name: $0.name) }
        } catch let err as OllamaError {
            throw err
        } catch {
            throw OllamaError.unreachable(error.localizedDescription)
        }
    }

    func capabilities(baseURL: String, model: String) async throws -> Set<String> {
        guard !model.isEmpty,
              let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?
                .appendingPathComponent("api/show") else {
            throw OllamaError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": model])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OllamaError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.unreachable("no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw OllamaError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        struct ShowResponse: Decodable { let capabilities: [String]? }
        let decoded = try JSONDecoder().decode(ShowResponse.self, from: data)
        return Set(decoded.capabilities ?? [])
    }

    func analyze(
        baseURL: String,
        model: String,
        prompt: String,
        imageJPEG: Data,
        timeout: TimeInterval,
        thinking: ThinkingMode,
        flagWord: String
    ) async throws -> AnalysisOutcome {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?
            .appendingPathComponent("api/generate") else {
            throw OllamaError.invalidURL
        }

        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "images": [imageJPEG.base64EncodedString()],
            "stream": false,
            "options": ["temperature": 0],
        ]
        if let thinkValue = thinking.apiValue {
            body["think"] = thinkValue
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OllamaError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.unreachable("no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw OllamaError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        struct GenerateResponse: Decodable {
            let response: String
            let thinking: String?
        }
        let outer: GenerateResponse
        do {
            outer = try JSONDecoder().decode(GenerateResponse.self, from: data)
        } catch {
            throw OllamaError.malformedResponse("outer envelope: \(error.localizedDescription)")
        }

        let raw = outer.response
        let trimmedFlag = flagWord.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFlagged = !trimmedFlag.isEmpty
            && raw.range(of: trimmedFlag, options: .caseInsensitive) != nil
        let reason = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        let result = AnalysisResult(keep: !isFlagged, reason: reason)
        return AnalysisOutcome(result: result, rawResponse: raw, thinking: outer.thinking)
    }

    func unload(baseURL: String, model: String) async {
        guard !model.isEmpty,
              let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?
                .appendingPathComponent("api/generate") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        let body: [String: Any] = ["model": model, "keep_alive": 0]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await session.data(for: request)
    }

    static let defaultPromptTemplate: String = """
    Look at this photo. Flag it if it matches: {criterion}.
    If it should be flagged, include the word "{flag_word}" in your reply.
    Otherwise, briefly say what you see.
    """

    static func buildPrompt(template: String, criterion: String, flagWord: String) -> String {
        let trimmedCriterion = criterion.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFlag = flagWord.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultPromptTemplate
            : template
        return effectiveTemplate
            .replacingOccurrences(of: "{criterion}", with: trimmedCriterion)
            .replacingOccurrences(of: "{flag_word}", with: trimmedFlag)
    }
}
