import Foundation

enum GroqError: Error, LocalizedError {
    case missingAPIKey
    case http(status: Int, body: String)
    case rateLimited(retryAfter: String?)
    case transport(Error)
    case decoding(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "GROQ_API_KEY is not set. Launch via `make run-api` with the env var exported."
        case .http(let status, let body):
            return "Groq API error \(status): \(body.prefix(240))"
        case .rateLimited(let retryAfter):
            if let r = retryAfter { return "Groq rate limit hit. Retry after \(r)s." }
            return "Groq rate limit hit. Please wait and retry."
        case .transport(let err):
            return "Network error: \(err.localizedDescription)"
        case .decoding(let detail):
            return "Failed to parse Groq stream: \(detail)"
        case .cancelled:
            return "Request cancelled."
        }
    }
}

struct GroqImage {
    let data: Data
    let mimeType: String // e.g. "image/jpeg" or "image/png"

    var dataURL: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}

struct GroqMessage {
    let role: String
    let content: String
    let images: [GroqImage]

    init(role: String, content: String, images: [GroqImage] = []) {
        self.role = role
        self.content = content
        self.images = images
    }
}

final class GroqClient: NSObject, URLSessionDataDelegate {
    static let defaultModel = "llama-3.3-70b-versatile"
    static let defaultVisionModel = "meta-llama/llama-4-scout-17b-16e-instruct"
    static let defaultTTSModel = "playai-tts"
    static let defaultTTSVoice = "Fritz-PlayAI"
    static let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    static let ttsEndpoint = URL(string: "https://api.groq.com/openai/v1/audio/speech")!

    private let apiKey: String?
    private let model: String
    private let visionModel: String
    private let ttsModel: String
    private let ttsVoice: String
    private var session: URLSession!
    private var activeTask: URLSessionDataTask?
    private var buffer = Data()

    private var onDelta: ((String) -> Void)?
    private var onDone: ((Result<Void, GroqError>) -> Void)?

    init(apiKey: String? = ProcessInfo.processInfo.environment["GROQ_API_KEY"],
         model: String = ProcessInfo.processInfo.environment["SELECTOR_GROQ_MODEL"] ?? GroqClient.defaultModel,
         visionModel: String = ProcessInfo.processInfo.environment["SELECTOR_GROQ_VISION_MODEL"] ?? GroqClient.defaultVisionModel,
         ttsModel: String = ProcessInfo.processInfo.environment["SELECTOR_GROQ_TTS_MODEL"] ?? GroqClient.defaultTTSModel,
         ttsVoice: String = ProcessInfo.processInfo.environment["SELECTOR_GROQ_TTS_VOICE"] ?? GroqClient.defaultTTSVoice) {
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = (trimmedKey?.isEmpty == false) ? apiKey : nil
        self.model = model
        self.visionModel = visionModel
        self.ttsModel = ttsModel
        self.ttsVoice = ttsVoice
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue())
    }

    var hasAPIKey: Bool { apiKey != nil }
    var modelName: String { model }
    var visionModelName: String { visionModel }
    var ttsModelName: String { ttsModel }
    var ttsVoiceName: String { ttsVoice }

    func stream(messages: [GroqMessage],
                onDelta: @escaping (String) -> Void,
                onDone: @escaping (Result<Void, GroqError>) -> Void) {
        guard let apiKey else {
            onDone(.failure(.missingAPIKey))
            return
        }
        cancel()
        self.onDelta = onDelta
        self.onDone = onDone
        self.buffer = Data()

        let hasImages = messages.contains { !$0.images.isEmpty }
        let chosenModel = hasImages ? visionModel : model

        var req = URLRequest(url: GroqClient.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": chosenModel,
            "stream": true,
            "messages": messages.map(Self.encodeMessage)
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            onDone(.failure(.decoding(error.localizedDescription)))
            return
        }

        let task = session.dataTask(with: req)
        activeTask = task
        task.resume()
    }

    private static func encodeMessage(_ message: GroqMessage) -> [String: Any] {
        if message.images.isEmpty {
            return ["role": message.role, "content": message.content]
        }
        var parts: [[String: Any]] = [["type": "text", "text": message.content]]
        for image in message.images {
            parts.append([
                "type": "image_url",
                "image_url": ["url": image.dataURL]
            ])
        }
        return ["role": message.role, "content": parts]
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
    }

    /// One-shot, non-streaming Groq TTS call. Returns the audio bytes (WAV).
    /// Returns the underlying `URLSessionDataTask` so the caller can cancel mid-flight.
    @discardableResult
    func synthesizeSpeech(text: String,
                          completion: @escaping (Result<Data, GroqError>) -> Void) -> URLSessionDataTask? {
        guard let apiKey else { completion(.failure(.missingAPIKey)); return nil }
        var req = URLRequest(url: GroqClient.ttsEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": ttsModel,
            "voice": ttsVoice,
            "input": text,
            "response_format": "wav"
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(.decoding(error.localizedDescription)))
            return nil
        }

        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                let cancelled = (error as NSError).code == NSURLErrorCancelled
                completion(.failure(cancelled ? .cancelled : .transport(error)))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                if http.statusCode == 429 {
                    completion(.failure(.rateLimited(retryAfter: http.value(forHTTPHeaderField: "retry-after"))))
                    return
                }
                let bodyStr = String(data: data ?? Data(), encoding: .utf8) ?? ""
                completion(.failure(.http(status: http.statusCode, body: bodyStr)))
                return
            }
            guard let data, !data.isEmpty else {
                completion(.failure(.decoding("Empty TTS response")))
                return
            }
            completion(.success(data))
        }
        task.resume()
        return task
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode == 429 {
            finish(.failure(.rateLimited(retryAfter: http.value(forHTTPHeaderField: "retry-after"))))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let http = dataTask.response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            finish(.failure(.http(status: http.statusCode, body: body)))
            dataTask.cancel()
            return
        }
        buffer.append(data)
        drainSSEEvents()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let cancelled = (error as NSError).code == NSURLErrorCancelled
            finish(.failure(cancelled ? .cancelled : .transport(error)))
            return
        }
        drainSSEEvents() // final flush
        finish(.success(()))
    }

    private func drainSSEEvents() {
        // Split on double newline (event boundary)
        while let range = buffer.range(of: Data("\n\n".utf8)) {
            let eventData = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)
            guard let eventStr = String(data: eventData, encoding: .utf8) else { continue }
            for line in eventStr.split(separator: "\n") {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { continue }
                if let delta = parseDelta(payload) {
                    DispatchQueue.main.async { [weak self] in self?.onDelta?(delta) }
                }
            }
        }
    }

    private func parseDelta(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String else {
            return nil
        }
        return content
    }

    private func finish(_ result: Result<Void, GroqError>) {
        let cb = onDone
        onDone = nil
        onDelta = nil
        activeTask = nil
        DispatchQueue.main.async { cb?(result) }
    }
}
