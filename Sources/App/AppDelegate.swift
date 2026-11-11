import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: MainWindowController!
    private var pendingFiles: [URL] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        window = MainWindowController()
        window.showWindow(nil)
        if let url = pendingFiles.last { window.open(url) } else { window.showSample() }
        pendingFiles.removeAll()
        NSApp.activate()
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        guard let url = urls.last else { return }
        if let window { window.open(url); window.showWindow(nil) } else { pendingFiles.append(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let window, window.hasUnsavedChanges else { return .terminateNow }
        window.confirmSave { ok in
            sender.reply(toApplicationShouldTerminate: ok)
        }
        return .terminateLater
    }

    func applicationDidBecomeActive(_ note: Notification) {
        window?.refreshStatus()
    }

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于墨览", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "设置…", action: #selector(MainWindowController.showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏墨览", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出墨览", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: "墨览")

        let file = NSMenu(title: "文件")
        file.addItem(withTitle: "打开…", action: #selector(MainWindowController.openDocument(_:)), keyEquivalent: "o")
        file.addItem(withTitle: "保存", action: #selector(MainWindowController.saveDocument(_:)), keyEquivalent: "s")
        file.addItem(.separator())
        file.addItem(withTitle: "在访达中显示", action: #selector(MainWindowController.revealDocument(_:)), keyEquivalent: "R").keyEquivalentModifierMask = [.command, .shift]
        file.addItem(.separator())
        file.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: file, title: "文件")

        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "查找…", action: #selector(MainWindowController.findInDocument(_:)), keyEquivalent: "f")
        main.addItem(submenu: edit, title: "编辑")

        let view = NSMenu(title: "显示")
        view.addItem(withTitle: "阅读", action: #selector(MainWindowController.readMode(_:)), keyEquivalent: "1")
        view.addItem(withTitle: "源码", action: #selector(MainWindowController.sourceMode(_:)), keyEquivalent: "2")
        view.addItem(withTitle: "双栏", action: #selector(MainWindowController.splitMode(_:)), keyEquivalent: "3")
        view.addItem(.separator())
        view.addItem(withTitle: "返回", action: #selector(MainWindowController.goBack(_:)), keyEquivalent: "[")
        view.addItem(.separator())
        view.addItem(withTitle: "放大", action: #selector(MainWindowController.zoomIn(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "缩小", action: #selector(MainWindowController.zoomOut(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "实际大小", action: #selector(MainWindowController.zoomReset(_:)), keyEquivalent: "0")
        main.addItem(submenu: view, title: "显示")

        let win = NSMenu(title: "窗口")
        win.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(submenu: win, title: "窗口")
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        submenu.title = title
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

// 快速查看扩展是否在系统里、有没有被关掉
enum ExtensionStatus {
    case enabled, disabled, missing

    static func check() async -> ExtensionStatus {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            p.arguments = ["-m", "-i", "local.molan.preview"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return .missing }
            p.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard let line = out.split(separator: "\n").first(where: { $0.contains("local.molan.preview") }) else { return .missing }
            return line.trimmingCharacters(in: .init(charactersIn: " \t")).hasPrefix("-") ? .disabled : .enabled
        }.value
    }

    static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }
}
