import Foundation

struct ChatMessage { let role: String; var text: String }
struct APIError: LocalizedError { let message: String; var errorDescription: String? { message } }

/// Streaming chat client for Gemini's OpenAI-compatible endpoint. Works on iOS 12+.
/// Delegate runs on the main queue, so no locks are needed.
final class ChatClient: NSObject, URLSessionDataDelegate {
    static let defaultModel = "gemini-3.8-flash"
    private static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!

    /// Editable in the app (Key button) because free-tier models change.
    static var model: String {
        get {
            let m = UserDefaults.standard.string(forKey: "model")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return m.isEmpty ? defaultModel : m
        }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "model")
        }
    }

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 300
        c.waitsForConnectivity = true
        return URLSession(configuration: c, delegate: self, delegateQueue: .main)
    }()

    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var errorBody = Data()
    private var status = 200
    private var streamError: String?
    private var onDelta: ((String) -> Void)?
    private var onDone: ((Error?) -> Void)?

    func send(messages: [ChatMessage], apiKey: String,
              onDelta: @escaping (String) -> Void, onDone: @escaping (Error?) -> Void) {
        cancel()
        self.onDelta = onDelta
        self.onDone = onDone
        buffer.removeAll(); errorBody.removeAll(); status = 200; streamError = nil

        var req = URLRequest(url: ChatClient.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "model": ChatClient.model,
            "stream": true,
            "reasoning_effort": "low",   // faster replies
            "messages": messages.map { ["role": $0.role, "content": $0.text] }
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let t = session.dataTask(with: req)
        task = t
        t.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil; onDelta = nil; onDone = nil
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if dataTask === task, let http = response as? HTTPURLResponse { status = http.statusCode }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task else { return }
        if status != 200 { errorBody.append(data); return }
        buffer.append(data)
        // Line based: works for both \n and \r\n event separators.
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line: line)
        }
    }

    func urlSession(_ session: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        guard t === task else { return }
        if status == 200, !buffer.isEmpty { handle(line: buffer); buffer.removeAll() }
        var result: Error? = error
        if status != 200 {
            result = APIError(message: ChatClient.message(from: errorBody) ?? "HTTP \(status)")
        } else if let m = streamError {
            result = APIError(message: m)
        }
        let done = onDone
        task = nil; onDelta = nil; onDone = nil
        done?(result)
    }

    // MARK: SSE

    private func handle(line: Data) {
        guard let raw = String(data: line, encoding: .utf8) else { return }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("data:") else { return }
        let payload = s.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty || payload == "[DONE]" { return }
        guard let d = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) else { return }
        if let msg = ChatClient.errorMessage(in: obj) { streamError = msg; return }
        if let dict = obj as? [String: Any],
           let choices = dict["choices"] as? [[String: Any]],
           let delta = choices.first?["delta"] as? [String: Any],
           let text = delta["content"] as? String, !text.isEmpty {
            onDelta?(text)
        }
    }

    /// Gemini errors come as {"error":{...}} or [{"error":{...}}].
    private static func errorMessage(in obj: Any) -> String? {
        var first: Any = obj
        if let arr = obj as? [Any], let f = arr.first { first = f }
        guard let d = first as? [String: Any], let e = d["error"] as? [String: Any] else { return nil }
        return (e["message"] as? String) ?? "Request failed"
    }

    private static func message(from data: Data) -> String? {
        guard !data.isEmpty, let o = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return errorMessage(in: o)
    }
}
