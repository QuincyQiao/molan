import AppKit
import UniformTypeIdentifiers
import WebKit

// 预览扩展和主程序共用：一个 WKWebView，页面从 molan:/// 读资源、文档和本地文件。
//   molan:///res/…            页面资源（扩展包里的 web/）
//   molan:///doc[?path=…]     当前文档或指定文档，JSON
//   molan:///resolve?base=&p= 反引号路径、维基链接：从 base 往上逐级找，返回找到的绝对路径
//   molan:///file/绝对路径     本地文件（图片）
// 页面发回来的消息：rendered、open（外链）、reveal（在访达里显示）、copy

enum MolanPaths {
    // 沙盒里 NSHomeDirectory() 是容器目录，这里要真正的家目录
    static let home: String = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }()
    static let settingsFile = URL(fileURLWithPath: home)
        .appendingPathComponent("Library/Application Support/Molan/settings.json")
}

struct MolanSettings: Codable, Equatable {
    var theme = "system"     // system / light / dark
    var fontSize = 16
    var width = "medium"     // narrow / medium / wide / full

    static func load() -> MolanSettings {
        guard let data = try? Data(contentsOf: MolanPaths.settingsFile),
              let s = try? JSONDecoder().decode(MolanSettings.self, from: data) else { return MolanSettings() }
        return s
    }

    func save() throws {
        let dir = MolanPaths.settingsFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: MolanPaths.settingsFile, options: .atomic)
    }

    var appearance: NSAppearance? {
        switch theme {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }

    var jsonForPage: [String: Any] { ["fontSize": fontSize, "width": width] }
}

enum MolanText {
    // UTF-8 优先；老文件可能是 GB18030 或 UTF-16
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let s = String(data: data.dropFirst(3), encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        return String(decoding: data, as: UTF8.self)
    }
}

final class MolanSchemeHandler: NSObject, WKURLSchemeHandler {
    let resources: URL
    var document: URL?
    var settings = MolanSettings()
    private var stopped = Set<ObjectIdentifier>()
    private let queue = DispatchQueue(label: "molan.scheme", qos: .userInitiated)

    init(resources: URL) {
        self.resources = resources
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = url.path
        let query = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let doc = document, settings = settings, resources = resources
        let id = ObjectIdentifier(task)
        queue.async { [weak self] in
            let reply = Self.respond(path: path, query: query, document: doc, settings: settings, resources: resources)
            DispatchQueue.main.async {
                guard let self, !self.stopped.contains(id) else { return }
                var headers = ["Content-Type": reply.type, "Cache-Control": "no-store"]
                headers["Content-Length"] = String(reply.body.count)
                let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
                task.didReceive(response)
                task.didReceive(reply.body)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    private struct Reply {
        var status = 200
        var type = "application/octet-stream"
        var body = Data()
        static func notFound() -> Reply { Reply(status: 404, type: "text/plain", body: Data("not found".utf8)) }
        static func json(_ obj: Any) -> Reply {
            let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("null".utf8)
            return Reply(type: "application/json; charset=utf-8", body: data)
        }
    }

    private static func respond(path: String, query: [String: String], document: URL?, settings: MolanSettings, resources: URL) -> Reply {
        if path == "/doc" {
            let target = query["path"].map { URL(fileURLWithPath: $0) } ?? document
            guard let target, let data = try? Data(contentsOf: target) else { return .notFound() }
            return .json([
                "path": target.path,
                "name": target.lastPathComponent,
                "dir": target.deletingLastPathComponent().path,
                "home": MolanPaths.home,
                "text": MolanText.decode(data),
                "settings": settings.jsonForPage,
            ])
        }
        if path == "/resolve" {
            let base = query["base"] ?? "/"
            let list = (query["p"].flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String]) ?? []
            return .json(list.map { resolve($0, from: base) ?? NSNull() })
        }
        if path.hasPrefix("/res/") {
            let rel = String(path.dropFirst(5))
            let file = resources.appendingPathComponent(rel).standardizedFileURL
            guard file.path.hasPrefix(resources.standardizedFileURL.path), let data = try? Data(contentsOf: file) else { return .notFound() }
            return Reply(type: mime(file), body: data)
        }
        if path.hasPrefix("/file/") {
            let file = URL(fileURLWithPath: String(path.dropFirst(5))).standardizedFileURL
            guard let data = try? Data(contentsOf: file) else { return .notFound() }
            return Reply(type: mime(file), body: data)
        }
        return .notFound()
    }

    // 从 base 往上逐级找，到家目录或根为止
    static func resolve(_ candidate: String, from base: String) -> Any? {
        let fm = FileManager.default
        func hit(_ p: String) -> [String: Any]? {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { return nil }
            return ["path": (p as NSString).standardizingPath, "dir": isDir.boolValue]
        }
        if candidate.hasPrefix("/") { return hit(candidate) }
        if candidate.hasPrefix("~/") { return hit(MolanPaths.home + candidate.dropFirst(1)) }
        var dir = base
        for _ in 0..<16 {
            if let h = hit((dir as NSString).appendingPathComponent(candidate)) { return h }
            if dir == MolanPaths.home || dir == "/" { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    private static func mime(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "woff2": return "font/woff2"
        case "svg": return "image/svg+xml"
        case "md": return "text/plain; charset=utf-8"
        default: return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}

// 主程序窗口可以把 Markdown 文件拖进来看；扩展里不设 onDropFile，照常
final class MolanWebView: WKWebView {
    var onDropFile: ((URL) -> Void)?
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx", "mdc", "qmd", "rmd", "txt"]

    private func droppedFile(_ info: NSDraggingInfo) -> URL? {
        guard onDropFile != nil,
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              let url = urls.first, Self.markdownExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        droppedFile(info) != nil ? .copy : super.draggingEntered(info)
    }

    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        droppedFile(info) != nil ? .copy : super.draggingUpdated(info)
    }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        if let url = droppedFile(info) { onDropFile?(url); return true }
        return super.performDragOperation(info)
    }
}

// WKUserContentController 会强引用 handler，中间垫一层免得循环引用
private final class WeakMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}

final class MolanWeb: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: MolanWebView
    let handler: MolanSchemeHandler
    private var waiting: CheckedContinuation<Void, Never>?
    var onRendered: (() -> Void)?

    static var resourcesInBundle: URL {
        // 扩展里资源在自己的包里；主程序去 PlugIns 里的扩展包找，同一份
        let own = Bundle.main.resourceURL!.appendingPathComponent("web")
        if FileManager.default.fileExists(atPath: own.path) { return own }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/MolanPreview.appex/Contents/Resources/web")
    }

    init(resources: URL = MolanWeb.resourcesInBundle) {
        handler = MolanSchemeHandler(resources: resources)
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: "molan")
        config.suppressesIncrementalRendering = true
        webView = MolanWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 1000), configuration: config)
        super.init()
        config.userContentController.add(WeakMessageProxy(self), name: "molan")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
    }

    func apply(_ settings: MolanSettings) {
        handler.settings = settings
        webView.appearance = settings.appearance
        if let data = try? JSONSerialization.data(withJSONObject: settings.jsonForPage), let json = String(data: data, encoding: .utf8) {
            webView.evaluateJavaScript("window.molan && molan.applySettings(\(json))")
        }
    }

    // 载入文档，等页面排完第一屏（最多等 timeout 秒）
    func show(_ file: URL, timeout: Double = 4) async {
        handler.document = file
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiting = c
            webView.load(URLRequest(url: URL(string: "molan:///res/index.html")!))
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finishWaiting() }
        }
    }

    private func finishWaiting() {
        waiting?.resume()
        waiting = nil
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "rendered":
            finishWaiting()
            onRendered?()
        case "open":
            if let s = body["url"] as? String, let url = URL(string: s), ["http", "https", "mailto", "ftp"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
        case "reveal":
            guard let p = body["path"] as? String else { return }
            let url = URL(fileURLWithPath: p)
            if body["dir"] as? Bool == true { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case "copy":
            if let text = body["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        default:
            break
        }
    }

    // 页面只能待在 molan:///res/index.html；别的跳转一律拦下，网页链接交给浏览器
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if url.scheme == "molan" { return decisionHandler(.allow) }
        if action.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}
