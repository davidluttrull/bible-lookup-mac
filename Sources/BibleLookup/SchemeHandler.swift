import BibleLookupCore
import Foundation
import WebKit

/// Serves the page at biblelookup://app/ and answers its /api requests in-process,
/// in place of the Python version's local web server (so no network port is opened).
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "biblelookup"
    static let home = URL(string: "\(scheme)://app/")!

    private let web = Bundle.main.resourceURL!.appendingPathComponent("Web")
    private var stopped = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = url.path.isEmpty ? "/" : url.path
        if path.hasPrefix("/api/") {
            var query: [String: String] = [:]
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] where query[item.name] == nil {
                query[item.name] = item.value ?? ""
            }
            let id = ObjectIdentifier(task)
            Task {
                let response: APIResponse
                do {
                    response = await (try AppModel.shared.service.value).handle(path: path, query: query)
                } catch {
                    let body = try? JSONSerialization.data(withJSONObject: ["error": "Couldn’t load the bundled Bibles: \(error)"])
                    response = APIResponse(status: 500, body: body ?? Data())
                }
                await MainActor.run {
                    guard self.stopped.remove(id) == nil else { return }
                    self.respond(task, url, response.status, "application/json; charset=utf-8", response.body)
                }
            }
            return
        }
        // static files; any other path is the page itself (it routes on ?q=)
        var file = web.appendingPathComponent("index.html")
        if path.hasPrefix("/static/") {
            let name = String(path.dropFirst("/static/".count))
            let candidate = web.appendingPathComponent(name).standardizedFileURL
            guard candidate.path.hasPrefix(web.standardizedFileURL.path + "/"),
                  FileManager.default.fileExists(atPath: candidate.path) else {
                respond(task, url, 404, "application/json", Data(#"{"error": "not found"}"#.utf8))
                return
            }
            file = candidate
        }
        let data = (try? Data(contentsOf: file)) ?? Data()
        respond(task, url, 200, mimeType(file.pathExtension), data)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    private func respond(_ task: WKURLSchemeTask, _ url: URL, _ status: Int, _ type: String, _ body: Data) {
        let headers = ["Content-Type": type, "Content-Length": "\(body.count)", "Cache-Control": "no-store"]
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    private func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        default: return "application/octet-stream"
        }
    }
}
