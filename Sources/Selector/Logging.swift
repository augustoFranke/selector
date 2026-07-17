import ApplicationServices
import Foundation

enum Logger {
    private static let url = URL(fileURLWithPath: "/tmp/selector.log")

    static func log(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
            _ = try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

enum AccessibilityPermission {
    static func isTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
