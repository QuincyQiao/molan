import Foundation

// 读一个 Markdown 文件，记住它的编码、BOM 和换行符；保存时按原样写回去。
enum MolanTextEncoding: String {
    case utf8, utf16le, utf16be, gb18030
}

struct MolanDecodedText {
    var text: String
    var encoding: MolanTextEncoding
    var bom: Bool
    var eol: String
}

enum MolanDocumentError: LocalizedError {
    case notWritable
    case noDocument
    case encodingFailed
    case changedOnDisk

    var errorDescription: String? {
        switch self {
        case .notWritable: return "这个文件是只读的，改不了。"
        case .noDocument: return "没有打开的文档。"
        case .encodingFailed: return "按原文件的编码存不回去。"
        case .changedOnDisk: return "文件在磁盘上已经被别的程序改过。"
        }
    }
}

final class MolanDocument {
    let url: URL
    private(set) var text: String
    private(set) var encoding: MolanTextEncoding
    private(set) var bom: Bool
    private(set) var eol: String
    private(set) var mtime: Date?
    var createsBackups = true

    var isWritable: Bool { FileManager.default.isWritableFile(atPath: url.path) }
    var isEditable: Bool { isWritable && !url.path.hasPrefix(Bundle.main.bundleURL.path) }

    init(url: URL) throws {
        self.url = url
        let data = try Data(contentsOf: url)
        let decoded = MolanText.detect(data)
        self.text = decoded.text
        self.encoding = decoded.encoding
        self.bom = decoded.bom
        self.eol = decoded.eol
        self.mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func json(settings: MolanSettings) -> [String: Any] {
        [
            "path": url.path,
            "name": url.lastPathComponent,
            "dir": url.deletingLastPathComponent().path,
            "home": MolanPaths.home,
            "text": text,
            "readOnly": !isEditable,
            "settings": settings.jsonForPage,
        ]
    }

    func write(_ newText: String, force: Bool = false) throws {
        guard isEditable else { throw MolanDocumentError.notWritable }
        let diskMtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if !force, let diskMtime, let mtime, abs(diskMtime.timeIntervalSince(mtime)) > 0.5 {
            throw MolanDocumentError.changedOnDisk
        }
        guard let data = MolanText.encode(newText, encoding: encoding, bom: bom, eol: eol) else {
            throw MolanDocumentError.encodingFailed
        }
        if createsBackups { backup() }
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
        text = newText
        mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // 每次覆盖前留一份，最多五份；出事了还能捞回来
    private func backup() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let dir = MolanPaths.backups.appendingPathComponent(backupKey)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let dest = dir.appendingPathComponent("\(f.string(from: Date())).md")
        try? FileManager.default.copyItem(at: url, to: dest)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else { return }
        let sorted = files.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        for old in sorted.dropFirst(5) { try? FileManager.default.removeItem(at: old) }
    }

    private var backupKey: String {
        var h: UInt64 = 5381
        for byte in url.path.utf8 { h = (h &* 33) &+ UInt64(byte) }
        return "\(url.deletingPathExtension().lastPathComponent)-\(String(h, radix: 16))"
    }
}
