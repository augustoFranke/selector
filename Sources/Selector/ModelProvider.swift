import Foundation

enum ProviderError: Error, LocalizedError {
    case missingAPIKey
    case http(status: Int, body: String)
    case rateLimited(retryAfter: String?)
    case transport(Error)
    case decoding(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key configured. Set one via the menu bar (Selector → Set Groq API Key…) or export GROQ_API_KEY."
        case .http(let status, let body):
            return "API error \(status): \(body.prefix(240))"
        case .rateLimited(let retryAfter):
            if let r = retryAfter { return "Rate limit hit. Retry after \(r)s." }
            return "Rate limit hit. Please wait and retry."
        case .transport(let err):
            return "Network error: \(err.localizedDescription)"
        case .decoding(let detail):
            return "Failed to parse model response: \(detail)"
        case .cancelled:
            return "Request cancelled."
        }
    }
}

struct ChatImage {
    let data: Data
    let mimeType: String

    var dataURL: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}

struct ChatMessage {
    let role: String
    let content: String
    let images: [ChatImage]

    init(role: String, content: String, images: [ChatImage] = []) {
        self.role = role
        self.content = content
        self.images = images
    }
}

protocol CancellableRequest {
    func cancel()
}

extension URLSessionTask: CancellableRequest {}

/// A streaming chat-completion backend the Ask Session talks to.
/// Vision routing stays a provider concern: `stream` picks the vision model
/// when any message carries images.
protocol ModelProvider: AnyObject {
    var hasAPIKey: Bool { get }
    var modelName: String { get }
    var visionModelName: String { get }
    func stream(messages: [ChatMessage],
                onDelta: @escaping (String) -> Void,
                onDone: @escaping (Result<Void, ProviderError>) -> Void)
    func cancel()
}

/// A TTS backend for SpeechService; falls back to the system voice when absent.
protocol SpeechProvider: AnyObject {
    var hasAPIKey: Bool { get }
    var ttsVoiceName: String { get }
    @discardableResult
    func synthesizeSpeech(text: String,
                          completion: @escaping (Result<Data, ProviderError>) -> Void) -> CancellableRequest?
}
