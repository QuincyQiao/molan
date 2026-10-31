import AppKit

// 墨览主程序。平时只负责：把预览扩展带进系统、显示扩展状态、改设置、也能直接打开 Markdown 看。
// 命令行用法（构建脚本和自测用）：
//   Molan --make-icon 输出.png
//   Molan --self-test --res web/dist
//   Molan --snapshot 文档.md 输出.png --res web/dist [--dark] [--width 960] [--height 1100] [--scroll 像素]

let args = CommandLine.arguments

func argValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if let out = argValue("--make-icon") {
    IconMaker.write(to: URL(fileURLWithPath: out))
    exit(0)
}

let app = NSApplication.shared

if args.contains("--self-test") || args.contains("--snapshot") {
    app.setActivationPolicy(.prohibited)
    let res = argValue("--res").map { URL(fileURLWithPath: $0) } ?? MolanWeb.resourcesInBundle
    Task { @MainActor in
        let ok: Bool
        if args.contains("--self-test") {
            ok = await SelfTest.run(resources: res)
        } else {
            ok = await Snapshot.run(resources: res)
        }
        exit(ok ? 0 : 1)
    }
    app.run()
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
