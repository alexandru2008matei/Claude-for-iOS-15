import Foundation

struct ChatMessage { let role: String; var text: String }
struct APIError: LocalizedError { let message: String; var errorDescription: String? { message } }

/// Streaming Claude client. URLSessionDataDelegate + SSE parsing = works on iOS 12+.
/// All delegate callbacks run on the main queue (no locks needed, parsing is tiny).
final class ClaudeClient: NSObject, URLSessionDataDelegate {
    static let model = "claude-sonnet-5-5"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

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

        var req = URLRequest(url: ClaudeClient.endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("text/event-stream", forHTTPHeaderField: "accept")
        let body: [String: Any] = [
            "model": ClaudeClient.model,
            "max_tokens": 2048,
            "stream": true,
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
        let sep = Data([0x0A, 0x0A])
        while let r = buffer.range(of: sep) {
            let chunk = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<r.upperBound)
            parse(chunk)
        }
    }

    func urlSession(_ session: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        guard t === task else { return }
        var result: Error? = error
        if status != 200 {
            result = APIError(message: ClaudeClient.message(from: errorBody) ?? "HTTP \(status)")
        } else if let m = streamError {
            result = APIError(message: m)
        }
        let done = onDone
        task = nil; onDelta = nil; onDone = nil
        done?(result)
    }

    // MARK: SSE

    private func parse(_ chunk: Data) {
        guard let s = String(data: chunk, encoding: .utf8) else { return }
        for line in s.split(separator: "\n") where line.hasPrefix("data:") {
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let d = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            if type == "content_block_delta",
               let delta = obj["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                onDelta?(text)
            } else if type == "error", let e = obj["error"] as? [String: Any] {
                streamError = (e["message"] as? String) ?? "Stream error"
            }
        }
    }

    private static func message(from data: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let e = o["error"] as? [String: Any] else { return nil }
        return e["message"] as? String
    }
}
