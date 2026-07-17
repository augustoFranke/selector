import AppKit
import Foundation

enum LinkContextStatus {
    case fetching
    case ok
    case failed(String)
}

final class LinkContext {
    let id = UUID()
    let url: URL
    let sourceSelectionID: UUID
    private(set) var status: LinkContextStatus = .fetching
    private(set) var extractedText: String?
    private(set) var pageTitle: String?

    init(url: URL, sourceSelectionID: UUID) {
        self.url = url
        self.sourceSelectionID = sourceSelectionID
    }

    func markOK(title: String?, text: String) {
        self.pageTitle = title
        self.extractedText = text
        self.status = .ok
    }

    func markFailed(_ reason: String) {
        self.status = .failed(reason)
    }
}

enum LinkContextFetcher {
    private static let detector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    private static let maxBodyChars = 8000

    /// Returns the dominant URL in a selection if the selection is "exactly one URL or mostly one URL",
    /// per PLAN1 Prototype 4. Otherwise returns nil.
    static func dominantURL(in text: String) -> URL? {
        guard let detector else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let matches = detector.matches(in: trimmed, options: [], range: range)
        guard matches.count == 1,
              let match = matches.first,
              let url = match.url,
              url.scheme?.hasPrefix("http") == true
        else { return nil }

        let coverage = Double(match.range.length) / Double((trimmed as NSString).length)
        return coverage >= 0.8 ? url : nil
    }

    static func fetch(_ context: LinkContext,
                      session: URLSession = .shared,
                      completion: @escaping (LinkContext) -> Void) {
        var req = URLRequest(url: context.url)
        req.timeoutInterval = 15
        // A common UA so sites don't 403 a default URLSession agent.
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Selector/0.1", forHTTPHeaderField: "User-Agent")

        let task = session.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                let http = response as? HTTPURLResponse
                if let error {
                    context.markFailed(error.localizedDescription)
                } else if let http, http.statusCode >= 400 {
                    context.markFailed("HTTP \(http.statusCode)")
                } else if let data, !data.isEmpty {
                    let (title, text) = extractReadableText(from: data, mime: http?.mimeType)
                    if text.isEmpty {
                        context.markFailed("No readable text")
                    } else {
                        context.markOK(title: title, text: String(text.prefix(maxBodyChars)))
                    }
                } else {
                    context.markFailed("Empty response")
                }
                completion(context)
            }
        }
        task.resume()
    }

    private static func extractReadableText(from data: Data, mime: String?) -> (String?, String) {
        if mime?.hasPrefix("text/plain") == true, let s = String(data: data, encoding: .utf8) {
            return (nil, collapseWhitespace(s))
        }
        // NSAttributedString's HTML parser requires the main thread; callers already dispatch there.
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        if let attr = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return (parseTitle(from: data), collapseWhitespace(attr.string))
        }
        if let s = String(data: data, encoding: .utf8) {
            return (parseTitle(from: data), collapseWhitespace(stripTags(s)))
        }
        return (nil, "")
    }

    private static func parseTitle(from data: Data) -> String? {
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        guard let range = html.range(of: "<title[^>]*>([\\s\\S]*?)</title>", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let segment = String(html[range])
        guard let inner = segment.range(of: ">([\\s\\S]*?)<", options: .regularExpression) else { return nil }
        let raw = String(segment[inner]).dropFirst().dropLast()
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    private static func collapseWhitespace(_ s: String) -> String {
        s.replacingOccurrences(of: "[\\s\\u{00A0}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
