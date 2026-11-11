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

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    private let web = MolanWeb()
    private let model = SettingsModel()
    private var current: URL?
    private var currentEditable = false
    private var isClosing = false
    private let saveButton = NSButton()
    private let modeControl = NSSegmentedControl(labels: ["阅读", "源码", "双栏"], trackingMode: .selectOne, target: nil, action: nil)
    private var selectedMode = "read"
    private let viewModes = ["read", "edit", "split"]
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
        window.delegate = self

        window.contentView = web.webView
        web.webView.onDropFile = { [weak self] url in self?.open(url) }
        web.apply(model.settings)
        model.onChange = { [weak self] s in self?.web.apply(s) }
        let remembered = UserDefaults.standard.string(forKey: "MolanViewMode") ?? "read"
        web.preferredMode = viewModes.contains(remembered) ? remembered : "read"
        web.onDirtyChange = { [weak self] dirty in
            self?.window?.isDocumentEdited = dirty
            self?.updateControls()
        }
        web.onModeChange = { [weak self] mode in
            guard let self else { return }
            self.selectedMode = mode
            self.web.preferredMode = mode
            UserDefaults.standard.set(mode, forKey: "MolanViewMode")
            self.updateControls()
        }
        web.onLocationChange = { [weak self] url in self?.adopt(url) }
        web.onConfirmNavigation = { [weak self] completion in
            guard let self else { completion(false); return }
            self.confirmSave(completion)
        }

        modeControl.target = self
        modeControl.action = #selector(changeMode(_:))
        modeControl.selectedSegment = viewModes.firstIndex(of: web.preferredMode) ?? 0
        modeControl.setToolTip("阅读（⌘1）", forSegment: 0)
        modeControl.setToolTip("源码（⌘2）", forSegment: 1)
        modeControl.setToolTip("源码与实时预览（⌘3）", forSegment: 2)
        modeControl.setAccessibilityLabel("文档视图")
        saveButton.title = "保存"
        saveButton.toolTip = "保存修改（⌘S）"
        saveButton.target = self
        saveButton.action = #selector(saveDocument(_:))
        saveButton.bezelStyle = .toolbar
        saveButton.isEnabled = false

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
        currentEditable = false
        window?.title = "墨览"
        window?.representedURL = nil
        window?.isDocumentEdited = false
        updateControls()
        Task { await web.show(sample) }
    }

    func open(_ url: URL) {
        if web.isDirty {
            confirmSave { [weak self] ok in
                if ok { self?.openNow(url) }
            }
            return
        }
        openNow(url)
    }

    private func openNow(_ url: URL) {
        guard let doc = try? MolanDocument(url: url) else {
            presentError("打不开这个文件。", title: "打不开")
            return
        }
        current = url
        currentEditable = doc.isEditable
        window?.title = url.lastPathComponent
        window?.representedURL = url
        window?.isDocumentEdited = false
        updateControls()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        Task { await web.show(doc) }
    }

    // 页面里点了别的 md（维基链接、相对链接、返回），当前文件跟着换
    func adopt(_ url: URL) {
        if url.path.hasPrefix(Bundle.main.bundleURL.path) {
            current = nil
            currentEditable = false
            window?.title = "墨览"
            window?.representedURL = nil
            window?.isDocumentEdited = false
            if let doc = try? MolanDocument(url: url) { web.adopt(doc) }
            updateControls()
            return
        }
        if current?.standardizedFileURL == url.standardizedFileURL { return }
        guard let doc = try? MolanDocument(url: url) else { return }
        current = url
        currentEditable = doc.isEditable
        window?.title = url.lastPathComponent
        window?.representedURL = url
        window?.isDocumentEdited = false
        updateControls()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        web.adopt(doc)
        updateControls()
    }

    private func updateControls() {
        modeControl.selectedSegment = viewModes.firstIndex(of: selectedMode) ?? 0
        saveButton.isEnabled = currentEditable && web.isDirty
    }

    @objc private func changeMode(_ sender: NSSegmentedControl) {
        guard viewModes.indices.contains(sender.selectedSegment) else { return }
        web.evaluate("molan.setMode('\(viewModes[sender.selectedSegment])')")
    }

    @objc func readMode(_ sender: Any?) { web.evaluate("molan.setMode('read')") }
    @objc func sourceMode(_ sender: Any?) { web.evaluate("molan.setMode('edit')") }
    @objc func splitMode(_ sender: Any?) { web.evaluate("molan.setMode('split')") }

    @objc func saveDocument(_ sender: Any?) {
        if web.isDirty { web.evaluate("molan.save()") }
    }

    var hasUnsavedChanges: Bool { web.isDirty }

    // 关闭、退出、换文件前的“保存吗”
    func confirmSave(_ completion: @escaping (Bool) -> Void) {
        guard web.isDirty else { completion(true); return }
        guard let window else { completion(false); return }
        let alert = NSAlert()
        alert.messageText = "要保存对“\(current?.lastPathComponent ?? "文档")”的修改吗？"
        alert.informativeText = "如果不保存，刚才的修改会丢失。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.saveForClose { ok in completion(ok) }
            case .alertSecondButtonReturn:
                self.web.markClean()
                completion(true)
            default:
                completion(false)
            }
        }
    }

    private func saveForClose(_ completion: @escaping (Bool) -> Void) {
        Task { @MainActor in
            completion(await web.saveFromPage())
        }
    }

    private func presentError(_ message: String, title: String = "保存失败") {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isClosing { return false }
        if !web.isDirty { return true }
        isClosing = true
        confirmSave { [weak self] ok in
            guard let self else { return }
            self.isClosing = false
            if ok { sender.close() }
        }
        return false
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

    @objc func findInDocument(_ sender: Any?) { if !web.isEditing { web.webView.evaluateJavaScript("molan.find()") } }
    @objc func goBack(_ sender: Any?) { if !web.isEditing { web.webView.evaluateJavaScript("molan.back()") } }
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
    private let modeID = NSToolbarItem.Identifier("mode")
    private let saveID = NSToolbarItem.Identifier("save")
    private let settingsID = NSToolbarItem.Identifier("settings")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, statusID, modeID, saveID, settingsID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        if id == statusID {
            item.view = statusButton
            item.isBordered = false
            item.visibilityPriority = .low
        } else if id == modeID {
            item.label = "文档视图"
            item.view = modeControl
            item.visibilityPriority = .high
            item.isBordered = false
        } else if id == saveID {
            item.label = "保存"
            item.view = saveButton
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
