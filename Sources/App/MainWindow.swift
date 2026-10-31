import AppKit
import SwiftUI

final class SettingsModel: ObservableObject {
    @Published var settings: MolanSettings {
        didSet {
            guard settings != oldValue else { return }
            try? settings.save()
            onChange?(settings)
        }
    }
    var onChange: ((MolanSettings) -> Void)?

    init() { settings = MolanSettings.load() }
}

// 像 Safari 阅读模式的「Aa」：外观、字号、版心宽度
struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("", selection: $model.settings.theme) {
                Text("自动").tag("system")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 12) {
                Text("A").font(.system(size: 12))
                Slider(value: Binding(
                    get: { Double(model.settings.fontSize) },
                    set: { model.settings.fontSize = Int($0.rounded()) }
                ), in: 13...21, step: 1)
                Text("A").font(.system(size: 19))
            }
            .foregroundStyle(.secondary)

            Picker("", selection: $model.settings.width) {
                Text("窄").tag("narrow")
                Text("适中").tag("medium")
                Text("宽").tag("wide")
                Text("满宽").tag("full")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(18)
        .frame(width: 280)
    }
}

final class MainWindowController: NSWindowController, NSToolbarDelegate {
    private let web = MolanWeb()
    private let model = SettingsModel()
    private var current: URL?
    private let popover = NSPopover()
    private let statusButton = NSButton()
    private var settingsItem: NSToolbarItem?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 1060),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "墨览"
        window.minSize = NSSize(width: 420, height: 360)
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("MolanMain")
        if !window.setFrameUsingName("MolanMain") { window.center() }
        super.init(window: window)

        window.contentView = web.webView
        web.webView.onDropFile = { [weak self] url in self?.open(url) }
        web.apply(model.settings)
        model.onChange = { [weak self] s in self?.web.apply(s) }

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: SettingsView(model: model))

        let toolbar = NSToolbar(identifier: "MolanToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        statusButton.bezelStyle = .toolbar
        statusButton.isBordered = false
        statusButton.cell?.wraps = false
        statusButton.cell?.lineBreakMode = .byClipping
        statusButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusButton.target = self
        statusButton.action = #selector(statusClicked)
        refreshStatus()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: 文档

    func showSample() {
        let sample = MolanWeb.resourcesInBundle.appendingPathComponent("sample.md")
        current = nil
        window?.title = "墨览"
        window?.representedURL = nil
        Task { await web.show(sample) }
    }

    func open(_ url: URL) {
        current = url
        window?.title = url.lastPathComponent
        window?.representedURL = url
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        Task { await web.show(url) }
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!, .init(filenameExtension: "markdown")!, .plainText]
        panel.allowsMultipleSelection = false
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] resp in
            if resp == .OK, let url = panel.url { self?.open(url) }
        }
    }

    @objc func revealDocument(_ sender: Any?) {
        if let current { NSWorkspace.shared.activateFileViewerSelecting([current]) }
    }

    @objc func findInDocument(_ sender: Any?) { web.webView.evaluateJavaScript("molan.find()") }
    @objc func goBack(_ sender: Any?) { web.webView.evaluateJavaScript("molan.back()") }
    @objc func zoomIn(_ sender: Any?) { web.webView.magnification = min(web.webView.magnification + 0.1, 2.5) }
    @objc func zoomOut(_ sender: Any?) { web.webView.magnification = max(web.webView.magnification - 0.1, 0.6) }
    @objc func zoomReset(_ sender: Any?) { web.webView.magnification = 1 }

    @objc func showSettings(_ sender: Any?) {
        guard let window else { return }
        showWindow(nil)
        if popover.isShown { popover.performClose(nil); return }
        if let view = settingsItem?.view, view.window != nil {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else if let content = window.contentView {
            popover.show(relativeTo: NSRect(x: content.bounds.maxX - 40, y: content.bounds.maxY - 4, width: 1, height: 1), of: content, preferredEdge: .minY)
        }
    }

    // MARK: 扩展状态

    func refreshStatus() {
        Task { @MainActor in
            let status = await ExtensionStatus.check()
            let (color, text): (NSColor, String) = switch status {
            case .enabled: (.systemGreen, "快速查看已启用")
            case .disabled: (.systemOrange, "快速查看已关闭")
            case .missing: (.systemOrange, "快速查看未注册")
            }
            let dot = NSAttributedString(string: "●  ", attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 9)])
            let label = NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12)])
            let title = NSMutableAttributedString(attributedString: dot)
            title.append(label)
            statusButton.attributedTitle = title
            statusButton.invalidateIntrinsicContentSize()
            statusButton.toolTip = status == .enabled ? nil : "打开系统设置"
        }
    }

    @objc private func statusClicked() {
        ExtensionStatus.openSystemSettings()
    }

    // MARK: 工具栏

    private let statusID = NSToolbarItem.Identifier("status")
    private let settingsID = NSToolbarItem.Identifier("settings")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, statusID, settingsID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        if id == statusID {
            item.view = statusButton
            item.isBordered = false
        } else if id == settingsID {
            // 系统的 textformat 图标在中文系统里会变成「大小」两个字，这里直接写 Aa
            let button = NSButton(title: "", target: self, action: #selector(showSettings(_:)))
            button.attributedTitle = NSAttributedString(string: "Aa", attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
            button.bezelStyle = .toolbar
            item.view = button
            item.toolTip = "设置"
            settingsItem = item
        }
        return item
    }
}
