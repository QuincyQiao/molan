import AppKit
import QuickLookUI

// 访达里按空格时系统起的预览扩展：每个文件一个控制器，读设置、载入文档、等第一屏排好再交给系统显示。
final class PreviewViewController: NSViewController, QLPreviewingController {
    private let web = MolanWeb()

    override func loadView() {
        view = web.webView
        preferredContentSize = NSSize(width: 960, height: 1100)
    }

    // 让网页直接收键盘：⌘F 查找、⌘C 拷贝、⌘[ 返回
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(web.webView)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        web.apply(MolanSettings.load())
        await web.show(url)
    }
}
