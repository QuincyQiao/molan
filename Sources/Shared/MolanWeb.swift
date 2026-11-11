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
    static let backups = URL(fileURLWithPath: home)
        .appendingPathComponent("Library/Application Support/Molan/Backups")
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
    static func decode(_ data: Data) -> String { detect(data).text }

    // 读的时候把编码、BOM、换行符一起认出来，保存时原样写回
    static func detect(_ data: Data) -> MolanDecodedText {
        let text: String
        let encoding: MolanTextEncoding
        let bom: Bool

        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = String(data: data.dropFirst(3), encoding: .utf8) ?? String(decoding: data.dropFirst(3), as: UTF8.self)
            encoding = .utf8; bom = true
        } else if data.starts(with: [0xFF, 0xFE]) {
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? String(decoding: data, as: UTF8.self)
            encoding = .utf16le; bom = true
        } else if data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? String(decoding: data, as: UTF8.self)
            encoding = .utf16be; bom = true
        } else if let s = String(data: data, encoding: .utf8) {
            text = s; encoding = .utf8; bom = false
        } else {
            let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) {
                text = s; encoding = .gb18030; bom = false
            } else {
                text = String(decoding: data, as: UTF8.self); encoding = .utf8; bom = false
            }
        }
        return MolanDecodedText(text: text, encoding: encoding, bom: bom, eol: detectEOL(text))
    }

    static func encode(_ text: String, encoding: MolanTextEncoding, bom: Bool, eol: String) -> Data? {
        let lf = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let final = eol == "\n" ? lf : lf.replacingOccurrences(of: "\n", with: eol)
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        var body: Data?
        switch encoding {
        case .utf8: body = final.data(using: .utf8)
        case .utf16le: body = final.data(using: .utf16LittleEndian)
        case .utf16be: body = final.data(using: .utf16BigEndian)
        case .gb18030: body = final.data(using: String.Encoding(rawValue: gb))
        }
        guard var out = body else { return nil }
        if bom {
            switch encoding {
            case .utf8: out = Data([0xEF, 0xBB, 0xBF]) + out
            case .utf16le: out = Data([0xFF, 0xFE]) + out
            case .utf16be: out = Data([0xFE, 0xFF]) + out
            case .gb18030: break
            }
        }
        return out
    }

    static func detectEOL(_ text: String) -> String {
        let crlf = text.components(separatedBy: "\r\n").count - 1
        let withoutCRLF = text.replacingOccurrences(of: "\r\n", with: "")
        let lf = withoutCRLF.components(separatedBy: "\n").count - 1
        let cr = withoutCRLF.components(separatedBy: "\r").count - 1
        if crlf > 0 && crlf >= lf && crlf >= cr { return "\r\n" }
        if cr > lf { return "\r" }
        return "\n"
    }
}

final class MolanSchemeHandler: NSObject, WKURLSchemeHandler {
    let resources: URL
    var document: MolanDocument?
    var settings = MolanSettings()
    var viewMode = "read"
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
        let doc = document, settings = settings, resources = resources, viewMode = viewMode
        let id = ObjectIdentifier(task)
        queue.async { [weak self] in
            let reply = Self.respond(path: path, query: query, document: doc, settings: settings, resources: resources, viewMode: viewMode)
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

    private static func respond(path: String, query: [String: String], document: MolanDocument?, settings: MolanSettings, resources: URL, viewMode: String) -> Reply {
        if path == "/doc" {
            let target: MolanDocument?
            if let p = query["path"] {
                target = try? MolanDocument(url: URL(fileURLWithPath: p))
            } else {
                target = document
            }
            guard let target else { return .notFound() }
            var payload = target.json(settings: settings)
            payload["viewMode"] = viewMode
            return .json(payload)
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
private final class WeakMessageProxy: NSObject, WKScriptMessageHandlerWithReply {
    weak var target: MolanWeb?
    init(_ target: MolanWeb) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let target else { replyHandler(nil, "页面已关闭"); return }
        target.userContentController(c, didReceive: message, replyHandler: replyHandler)
    }
}

final class MolanWeb: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate {
    let webView: MolanWebView
    let handler: MolanSchemeHandler
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var document: MolanDocument?
    private(set) var isDirty = false
    private(set) var isEditing = false
    var preferredMode = "read" { didSet { handler.viewMode = preferredMode } }
    var onRendered: (() -> Void)?
    var onDirtyChange: ((Bool) -> Void)?
    var onModeChange: ((String) -> Void)?
    var onLocationChange: ((URL) -> Void)?
    var onConfirmNavigation: ((@escaping (Bool) -> Void) -> Void)?

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
        config.userContentController.addScriptMessageHandler(WeakMessageProxy(self), contentWorld: .page, name: "molan")
        webView.navigationDelegate = self
        webView.uiDelegate = self
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
        guard let doc = try? MolanDocument(url: file) else {
            handler.document = nil
            document = nil
            await loadPage(timeout: timeout)
            return
        }
        await show(doc, timeout: timeout)
    }

    func show(_ doc: MolanDocument, timeout: Double = 4) async {
        handler.document = doc
        document = doc
        isDirty = false
        isEditing = false
        onDirtyChange?(false)
        onModeChange?(preferredMode)
        await loadPage(timeout: timeout)
    }

    private func loadPage(timeout: Double) async {
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

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else {
            replyHandler(nil, nil)
            return
        }
        switch type {
        case "rendered":
            finishWaiting()
            onRendered?()
        case "open":
            if let s = body["url"] as? String, let url = URL(string: s), ["http", "https", "mailto", "ftp"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
        case "reveal":
            if let p = body["path"] as? String {
                let url = URL(fileURLWithPath: p)
                if body["dir"] as? Bool == true { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        case "copy":
            if let text = body["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case "location":
            if let p = body["path"] as? String { onLocationChange?(URL(fileURLWithPath: p)) }
        case "dirty":
            let value = body["dirty"] as? Bool ?? false
            if value != isDirty { isDirty = value; onDirtyChange?(value) }
        case "mode":
            let value = body["editing"] as? Bool ?? false
            isEditing = value
            let mode = body["mode"] as? String ?? (value ? "edit" : "read")
            if ["read", "edit", "split"].contains(mode) { onModeChange?(mode) }
        case "confirmNavigate":
            if let onConfirmNavigation {
                onConfirmNavigation { ok in replyHandler(["ok": ok], nil) }
            } else {
                replyHandler(["ok": !isDirty], nil)
            }
            return
        case "save":
            let text = body["text"] as? String ?? ""
            let force = body["force"] as? Bool ?? false
            guard let document else {
                replyHandler(["ok": false, "error": "没有打开的文档。"], nil)
                return
            }
            do {
                try document.write(text, force: force)
                isDirty = false
                onDirtyChange?(false)
                replyHandler(["ok": true], nil)
            } catch MolanDocumentError.changedOnDisk {
                replyHandler(["ok": false, "conflict": true], nil)
            } catch {
                replyHandler(["ok": false, "error": error.localizedDescription], nil)
            }
            return
        default:
            break
        }
        replyHandler(nil, nil)
    }

    // 页面切到别的文档（点链接、返回）时，主程序跟着换当前文件
    func adopt(_ doc: MolanDocument) {
        handler.document = doc
        document = doc
        isDirty = false
        onDirtyChange?(false)
    }

    func markClean() {
        isDirty = false
        onDirtyChange?(false)
    }

    func saveText(_ text: String, force: Bool = false) throws {
        guard let document else { throw MolanDocumentError.noDocument }
        try document.write(text, force: force)
        isDirty = false
        onDirtyChange?(false)
    }

    func editorText() async -> String? {
        let js = "const e = document.getElementById('editor'); if (!e) throw new Error('没有编辑框'); return e.value"
        do {
            let value = try await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
            return value as? String
        } catch {
            return nil
        }
    }

    func evaluate(_ js: String) {
        webView.evaluateJavaScript(js)
    }

    func saveFromPage() async -> Bool {
        (try? await webView.callAsyncJavaScript("return await molan.save()", arguments: [:], in: nil, contentWorld: .page)) as? Bool ?? false
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "好")
        if let window = webView.window {
            alert.beginSheetModal(for: window) { _ in completionHandler() }
        } else { alert.runModal(); completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "覆盖")
        alert.addButton(withTitle: "取消")
        if let window = webView.window {
            alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
        } else { completionHandler(alert.runModal() == .alertFirstButtonReturn) }
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
        isEditing = false
        isDirty = false
        onModeChange?("read")
        onDirtyChange?(false)
        webView.reload()
    }
}
