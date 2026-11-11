import AppKit
import WebKit

// 图标：纸色圆角方块上一滴墨，用代码画，构建时导出 1024 像素 PNG
enum IconMaker {
    static func write(to url: URL) {
        let size = 1024
        let cs = CGColorSpace(name: CGColorSpace.displayP3)!
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // 换成左上角原点，方便按设计稿的坐标画
        ctx.translateBy(x: 0, y: CGFloat(size))
        ctx.scaleBy(x: 1, y: -1)

        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

        // 底下一圈很淡的投影
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: CGColor(gray: 0, alpha: 0.28))
        ctx.addPath(squircle)
        ctx.setFillColor(CGColor(gray: 0.95, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        // 纸：上亮下略暖
        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()
        let paper = CGGradient(colorsSpace: cs, colors: [
            CGColor(srgbRed: 1.0, green: 0.996, blue: 0.985, alpha: 1),
            CGColor(srgbRed: 0.945, green: 0.93, blue: 0.9, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(paper, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

        // 墨滴落下的地方晕开的一圈淡墨
        let pool = CGGradient(colorsSpace: cs, colors: [
            CGColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 0.22),
            CGColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 0),
        ] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.translateBy(x: 512, y: 778)
        ctx.scaleBy(x: 1, y: 0.22)
        ctx.drawRadialGradient(pool, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 300, options: [])
        ctx.restoreGState()

        // 墨滴
        let drop = CGMutablePath()
        let cx: CGFloat = 512, top: CGFloat = 214, cy: CGFloat = 566, r: CGFloat = 178
        drop.move(to: CGPoint(x: cx, y: top))
        drop.addCurve(to: CGPoint(x: cx - r, y: cy), control1: CGPoint(x: cx - 40, y: top + 120), control2: CGPoint(x: cx - r, y: cy - 150))
        drop.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
        drop.addCurve(to: CGPoint(x: cx, y: top), control1: CGPoint(x: cx + r, y: cy - 150), control2: CGPoint(x: cx + 40, y: top + 120))
        drop.closeSubpath()

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 22), blur: 40, color: CGColor(srgbRed: 0.05, green: 0.06, blue: 0.1, alpha: 0.35))
        ctx.addPath(drop)
        ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(drop)
        ctx.clip()
        let ink = CGGradient(colorsSpace: cs, colors: [
            CGColor(srgbRed: 0.22, green: 0.25, blue: 0.32, alpha: 1),
            CGColor(srgbRed: 0.07, green: 0.08, blue: 0.1, alpha: 1),
            CGColor(srgbRed: 0.02, green: 0.02, blue: 0.03, alpha: 1),
        ] as CFArray, locations: [0, 0.55, 1])!
        ctx.drawRadialGradient(ink, startCenter: CGPoint(x: cx - 60, y: cy - 90), startRadius: 0,
                               endCenter: CGPoint(x: cx + 20, y: cy + 40), endRadius: 300, options: [.drawsAfterEndLocation])
        // 高光
        let gloss = CGGradient(colorsSpace: cs, colors: [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.translateBy(x: cx - 78, y: cy - 62)
        ctx.rotate(by: -0.5)
        ctx.scaleBy(x: 0.55, y: 1)
        ctx.drawRadialGradient(gloss, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 70, options: [])
        ctx.restoreGState()
        ctx.restoreGState()

        // 纸边一道极细的亮线
        ctx.addPath(squircle)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.6))
        ctx.setLineWidth(3)
        ctx.strokePath()
        ctx.restoreGState()

        guard let image = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

// 构建时的自测：路径查找、编码识别、真跑一遍 WebKit 渲染
@MainActor
enum SelfTest {
    static func run(resources: URL) async -> Bool {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("molan-selftest-\(getpid())")
        try? fm.createDirectory(at: tmp.appendingPathComponent("a/b/c"), withIntermediateDirectories: true)
        try? Data("# x".utf8).write(to: tmp.appendingPathComponent("a/top.md"))
        defer { try? fm.removeItem(at: tmp) }
        let base = tmp.appendingPathComponent("a/b/c").path
        let found = MolanSchemeHandler.resolve("top.md", from: base) as? [String: Any]
        check((found?["path"] as? String)?.hasSuffix("/a/top.md") == true, "往上逐级找文件")
        check(MolanSchemeHandler.resolve("nope.md", from: base) == nil, "找不到的返回空")
        check((MolanSchemeHandler.resolve("b", from: tmp.appendingPathComponent("a").path) as? [String: Any])?["dir"] as? Bool == true, "文件夹")

        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let gbData = "中文标题".data(using: String.Encoding(rawValue: gb))!
        check(MolanText.decode(gbData) == "中文标题", "GB18030 编码")
        check(MolanText.decode(Data([0xEF, 0xBB, 0xBF]) + Data("墨".utf8)) == "墨", "带 BOM 的 UTF-8")

        // 编码、BOM、换行符往返
        let samples: [(MolanTextEncoding, Bool)] = [(.utf8, false), (.utf8, true), (.utf16le, true), (.utf16be, true), (.gb18030, false)]
        for (enc, bom) in samples {
            guard let data = MolanText.encode("中文\n第二行", encoding: enc, bom: bom, eol: "\r\n") else {
                check(false, "编码往返 \(enc.rawValue)")
                continue
            }
            let back = MolanText.detect(data)
            check(back.text == "中文\r\n第二行" && back.encoding == enc && back.bom == bom && back.eol == "\r\n", "编码往返 \(enc.rawValue)")
        }

        // 保存写回
        let editURL = tmp.appendingPathComponent("edit.md")
        try? Data("旧文\n".utf8).write(to: editURL)
        if let doc = try? MolanDocument(url: editURL) {
            doc.createsBackups = false
            try? doc.write("新文\n")
            check(MolanText.decode((try? Data(contentsOf: editURL)) ?? Data()) == "新文\n", "保存写回")
        }

        let sample = resources.appendingPathComponent("sample.md")
        let web = MolanWeb(resources: resources)
        let window = offscreenWindow(for: web.webView, size: NSSize(width: 900, height: 900))
        var rendered = false
        web.onRendered = { rendered = true }
        await web.show(sample, timeout: 15)
        check(rendered, "页面在 15 秒内排完")
        let h1 = try? await web.webView.evaluateJavaScript("document.querySelectorAll('#doc h1').length") as? Int
        check(h1 == 1, "示例文档有一个一级标题")
        let tables = try? await web.webView.evaluateJavaScript("document.querySelectorAll('#doc .table-wrap').length") as? Int
        check(tables == 1, "表格")
        let math = try? await web.webView.evaluateJavaScript("document.querySelectorAll('#doc .katex').length") as? Int
        check((math ?? 0) > 0, "公式")

        // 编辑 → 保存，走真实的消息桥和文件写入
        if let editDoc = try? MolanDocument(url: editURL) {
            editDoc.createsBackups = false
            await web.show(editDoc, timeout: 15)
            _ = try? await web.webView.evaluateJavaScript("molan.setMode('edit'); 0")
            _ = try? await web.webView.evaluateJavaScript("const e = document.getElementById('editor'); e.value = '# 新标题\\n正文\\n'; e.dispatchEvent(new Event('input')); 0")
            // 切换视图必须保留缓冲区和脏状态，阅读预览也必须显示未保存的内容。
            _ = try? await web.webView.evaluateJavaScript("molan.setMode('split'); 0")
            let splitOK = try? await web.webView.evaluateJavaScript("document.body.classList.contains('split') && document.querySelector('#doc h1').textContent === '新标题'") as? Bool
            check(splitOK == true && web.isDirty, "双栏显示未保存内容")
            _ = try? await web.webView.evaluateJavaScript("molan.setMode('read'); molan.setMode('edit'); 0")
            check(await web.editorText() == "# 新标题\n正文\n" && web.isDirty, "三种视图切换不丢编辑内容")
            // 真实 input 触发防抖渲染，不借助模式切换。
            _ = try? await web.webView.evaluateJavaScript("molan.setMode('split'); e.value = '# 实时更新\\n正文\\n'; e.dispatchEvent(new Event('input')); 0")
            try? await Task.sleep(nanoseconds: 500_000_000)
            let liveTitle = try? await web.webView.evaluateJavaScript("document.querySelector('#doc h1').textContent") as? String
            check(liveTitle == "实时更新", "双栏输入后实时预览")
            // 中文输入法组字期间不重绘，确认候选后再更新。
            _ = try? await web.webView.evaluateJavaScript("e.dispatchEvent(new CompositionEvent('compositionstart')); e.value = '# 中文输入\\n'; e.dispatchEvent(new Event('input')); 0")
            try? await Task.sleep(nanoseconds: 350_000_000)
            let composingTitle = try? await web.webView.evaluateJavaScript("document.querySelector('#doc h1').textContent") as? String
            check(composingTitle == "实时更新", "中文组字期间不重绘")
            _ = try? await web.webView.evaluateJavaScript("e.dispatchEvent(new CompositionEvent('compositionend')); 0")
            try? await Task.sleep(nanoseconds: 500_000_000)
            let composedTitle = try? await web.webView.evaluateJavaScript("document.querySelector('#doc h1').textContent") as? String
            check(composedTitle == "中文输入", "中文确认后刷新预览")
            _ = try? await web.webView.evaluateJavaScript("molan.setMode('read'); 0")
            _ = try? await web.webView.callAsyncJavaScript("return await molan.save()", arguments: [:], in: nil, contentWorld: .page)
            check((try? String(contentsOf: editURL, encoding: .utf8)) == "# 中文输入\n" && !web.isDirty, "阅读视图也能保存编辑内容")
            _ = try? await web.webView.evaluateJavaScript("molan.setMode('edit'); e.value += '改动'; e.dispatchEvent(new Event('input')); e.value = '# 中文输入\\n'; e.dispatchEvent(new Event('input')); 0")
            check(!web.isDirty, "内容恢复保存版本时取消脏标记")
            web.preferredMode = "split"
            await web.show(editDoc, timeout: 15)
            let remembered = try? await web.webView.evaluateJavaScript("document.body.classList.contains('split')") as? Bool
            check(remembered == true, "重新打开文档保留双栏选择")
        }
        // 快速查看使用独立 Web 实例，保持只读阅读视图。
        let quickLook = MolanWeb(resources: resources)
        let quickWindow = offscreenWindow(for: quickLook.webView, size: NSSize(width: 900, height: 900))
        await quickLook.show(sample, timeout: 15)
        let quickReading = try? await quickLook.webView.evaluateJavaScript("!document.body.classList.contains('editing')") as? Bool
        check(quickReading == true, "快速查看仍使用阅读视图")
        quickWindow.orderOut(nil)
        window.orderOut(nil)

        if failures.isEmpty {
            print("自测通过")
            return true
        }
        print("自测没通过：" + failures.joined(separator: "、"))
        return false
    }

    static func offscreenWindow(for view: NSView, size: NSSize) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = view
        w.orderBack(nil)
        return w
    }
}

// 用和扩展同一套 WebKit 页面把文档渲染成图，调样子、验收用
@MainActor
enum Snapshot {
    static func run(resources: URL) async -> Bool {
        let rest = Array(args.drop(while: { $0 != "--snapshot" }).dropFirst())
        guard rest.count >= 2 else { print("用法：--snapshot 文档.md 输出.png"); return false }
        let input = URL(fileURLWithPath: rest[0]), output = URL(fileURLWithPath: rest[1])
        let width = Double(argValue("--width") ?? "") ?? 960
        let height = Double(argValue("--height") ?? "") ?? 1100
        let scroll = Double(argValue("--scroll") ?? "") ?? 0

        let web = MolanWeb(resources: resources)
        var s = MolanSettings.load()
        s.theme = args.contains("--dark") ? "dark" : "light"
        web.apply(s)
        let window = SelfTest.offscreenWindow(for: web.webView, size: NSSize(width: width, height: height))
        window.appearance = s.appearance
        let t0 = Date()
        await web.show(input, timeout: 20)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        if let mode = argValue("--mode"), ["read", "edit", "split"].contains(mode) {
            _ = try? await web.webView.evaluateJavaScript("molan.setMode('\(mode)'); 0")
        }
        if scroll > 0 { _ = try? await web.webView.evaluateJavaScript("window.scrollTo(0, \(scroll)); 0") }
        try? await Task.sleep(nanoseconds: UInt64((Double(argValue("--wait") ?? "") ?? 0.7) * 1_000_000_000))
        if let js = argValue("--eval") {
            let result = try? await web.webView.evaluateJavaScript(js)
            print(result.map { "\($0)" } ?? "nil")
        }
        guard let image = try? await web.webView.takeSnapshot(configuration: nil),
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("截图失败"); return false }
        do { try png.write(to: output) } catch { print(error); return false }
        print("\(output.path)  \(ms) ms")
        return true
    }
}
