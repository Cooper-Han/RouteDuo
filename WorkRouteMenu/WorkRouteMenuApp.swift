import AppKit
import Sparkle
import SwiftUI
import Foundation
import Network
import SystemConfiguration
import UserNotifications
import UniformTypeIdentifiers
import Darwin
import IOKit

// Request periodic destination updates so holding a drag at an edge keeps scrolling.
final class RouteAddressTableView: NSTableView {
    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingSource as? NSTableView === self,
           let scrollView = enclosingScrollView {
            let point = convert(sender.draggingLocation, from: nil)
            let visible = visibleRect
            let edge: CGFloat = 28
            let step: CGFloat
            if point.y < visible.minY + edge {
                step = -10
            } else if point.y > visible.maxY - edge {
                step = 10
            } else {
                step = 0
            }
            if step != 0 {
                let clip = scrollView.contentView
                let maxY = max(0, bounds.height - clip.bounds.height)
                let y = min(max(clip.bounds.origin.y + step, 0), maxY)
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                scrollView.reflectScrolledClipView(clip)
            }
        }
        return super.draggingUpdated(sender)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, UNUserNotificationCenterDelegate {
    private let routeRowPasteboardType = NSPasteboard.PasteboardType("com.cooper.RouteDuo.route-row")
    private var statusItem: NSStatusItem!
    private var updaterController: SPUStandardUpdaterController!
    private var automaticUpdateItem: NSMenuItem!
    private var updateTerminationPending = false
    private var enabledStatusImage: NSImage!
    private var disabledStatusImage: NSImage!
    private var aboutWindow: NSWindow?
    private weak var window: NSWindow?
    private var showingSettings = false
    private var routesTable: NSTableView!
    private var routeRows: [[String]] = [] // 地址、备注
    private var statusLabel: NSTextField!
    private var defaultNetworkLabel: NSTextField!
    private var toggleItem: NSMenuItem!
    private var helperButton: NSButton!
    private var helperConnection: NSXPCConnection?
    private var helperReady = false
    private var helperStatus = "正在检查辅助服务"
    private var helperHint: NSTextField?
    private var helperInstallationInProgress = false
    private var helperRequests: [UUID: (Bool, String) -> Void] = [:]

    private var switchNetworkButton: NSButton!
    private weak var serviceOrderEditor: ServiceOrderEditor?
    private var networkSwitchInProgress = false
    private var pendingNetworkOrder: [String]?
    private var expectedDefaultInterface: String?
    private var expectedDefaultName: String?
    private var switchVerification: DispatchWorkItem?

    private weak var removeAddressButton: NSButton?
    private var pendingUninstall = false
    private var pendingQuit = false
    private var launchAtLoginItem: NSMenuItem!
    private var autoEnableItem: NSMenuItem!
    private var routesEnabled = false
    private var enableInProgress = false
    private var disableInProgress = false
    private var routingSession = UUID()
    private var addressChangeCleanupPending = false
    private let addressChangeMessage = "分流地址已修改，分流已关闭，请重新启用。"
    private var autoEnablePausedForSession = false
    private var networkReconfigurationInProgress = false
    private var networkRefreshRequested = false
    private var pendingNetworkRefresh: DispatchWorkItem?
    private var pendingEnableSignature: String?
    private var pendingEnableIPs: [String] = []
    private var pendingBackgroundDomains: [String] = []
    private var pendingBackgroundTopology: NetworkTopology?
    private var networkMonitors: [NWPathMonitor] = []
    private let networkMonitorQueue = DispatchQueue(label: "com.cooper.WorkRouteMenu.network-monitor", qos: .utility)
    private var dynamicStore: SCDynamicStore?
    private var dynamicStoreSource: CFRunLoopSource?
    private let topologyLock = NSLock()
    private var cachedTopology: NetworkTopology?
    // 仅由串行网络监听队列更新，保留断开前的网络名称。
    private var lastAvailableTopology: NetworkTopology?
    private let dnsCacheLock = NSLock()
    private var dnsCache: [String: [String]] = [:]

    private let defaultsKey = "workDomains"
    private let appliedRoutesKey = "appliedRouteIPs"
    private let appliedNetworkSignatureKey = "appliedNetworkSignature"
    private let dnsCacheKey = "resolvedDomainCache"
    private let savedNetworkOrderKey = "savedNetworkServiceOrder"
    private let autoEnableKey = "autoEnableRoutes"
    private let defaultDomains = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 迁移旧版本：编辑后的暂停仅影响当前运行，不跨重启保存。
        UserDefaults.standard.removeObject(forKey: "autoEnablePausedAfterAddressEdit")
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("通知授权失败：%@", error.localizedDescription) }
        }
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 使用 macOS 菜单栏模板图标，由系统负责亮暗颜色；通过按钮透明度区分状态。
        enabledStatusImage = makeStatusImage()
        disabledStatusImage = enabledStatusImage
        // The helper cleans the previous connection's routes; persisted UI state
        // is never evidence that this process owns an active routing session.
        routesEnabled = false
        UserDefaults.standard.set(false, forKey: "routesEnabled")
        loadRows()
        dnsCache = UserDefaults.standard.dictionary(forKey: dnsCacheKey) as? [String: [String]] ?? [:]
        updateStatusIcon()
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "设置分流地址…", action: #selector(showSettings), keyEquivalent: ""))
        toggleItem = NSMenuItem(title: routesEnabled ? "关闭网络分流" : "启用网络分流", action: #selector(toggleRoutes), keyEquivalent: "")
        menu.addItem(toggleItem)
        toggleItem.isEnabled = true
        menu.addItem(.separator())
        launchAtLoginItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchAtLoginItem)
        autoEnableItem = NSMenuItem(title: "自动启用分流", action: #selector(toggleAutoEnable), keyEquivalent: "")
        autoEnableItem.target = self
        autoEnableItem.state = UserDefaults.standard.bool(forKey: autoEnableKey) ? .on : .off
        menu.addItem(autoEnableItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let updateItem = NSMenuItem(title: "检查更新…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = updaterController
        let aboutItem = NSMenuItem(title: "关于 RouteDuo…", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        automaticUpdateItem = NSMenuItem(title: "自动更新", action: #selector(toggleAutomaticUpdates), keyEquivalent: "")
        automaticUpdateItem.target = self
        menu.insertItem(automaticUpdateItem, at: menu.numberOfItems - 1)
        menu.insertItem(updateItem, at: menu.numberOfItems - 1)
        menu.insertItem(aboutItem, at: menu.numberOfItems - 1)
        menu.insertItem(.separator(), at: menu.numberOfItems - 1)
        statusItem.menu = menu
        updaterController.startUpdater()
        // One-time migration from releases that explicitly disallowed updates.
        // Subsequent launches preserve the user's Sparkle settings.
        if !UserDefaults.standard.bool(forKey: "automaticUpdatesMigration1") {
            updaterController.updater.automaticallyChecksForUpdates = true
            updaterController.updater.automaticallyDownloadsUpdates = true
            UserDefaults.standard.set(true, forKey: "automaticUpdatesMigration1")
        }
        automaticUpdateItem.state = updaterController.updater.automaticallyChecksForUpdates && updaterController.updater.automaticallyDownloadsUpdates ? .on : .off
        refreshHelperHealth()
        startNetworkMonitoring()
        refreshConfiguredDomainsInBackground()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // 从 Finder、开机启动或重复点击应用时，只要没有配置窗口，保持纯菜单栏模式。
        if !showingSettings, window?.isVisible != true, aboutWindow?.isVisible != true, NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @objc private func toggleAutomaticUpdates() {
        let updater = updaterController.updater
        let enable = !(updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates)
        updater.automaticallyChecksForUpdates = enable
        updater.automaticallyDownloadsUpdates = enable
        automaticUpdateItem.state = enable ? .on : .off
    }

    @objc private func showAbout() {
        func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: size, weight: weight)
            field.textColor = color
            field.alignment = .center
            return field
        }
        if aboutWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "关于 RouteDuo"
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.center()
            let content = NSVisualEffectView()
            content.material = .windowBackground
            content.blendingMode = .behindWindow
            panel.contentView = content
            let icon = NSImageView(image: NSApp.applicationIconImage)
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 88), icon.heightAnchor.constraint(equalToConstant: 88)])
            let title = label("RouteDuo", size: 23, weight: .semibold)
            let info = Bundle.main.infoDictionary ?? [:]
            let version = info["CFBundleShortVersionString"] as? String ?? ""
            let build = info["CFBundleVersion"] as? String ?? ""
            let versionLabel = label("版本 \(version)（\(build)）", size: 13, color: .secondaryLabelColor)
            let description = label("配置的地址走分流网络，其他流量走默认网络。", size: 13, color: .secondaryLabelColor)
            let link = NSTextField(labelWithString: "")
            link.attributedStringValue = NSAttributedString(string: "github.com/Cooper-Han/RouteDuo", attributes: [
                .link: URL(string: "https://github.com/Cooper-Han/RouteDuo")!,
                .font: NSFont.systemFont(ofSize: 13),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ])
            link.isSelectable = true
            link.allowsEditingTextAttributes = true
            link.alignment = .center
            link.setAccessibilityLabel("GitHub 仓库链接")
            let column = NSStackView(views: [icon, title, versionLabel, description, link])
            column.orientation = .vertical
            column.alignment = .centerX
            column.spacing = 14
            column.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(column)
            NSLayoutConstraint.activate([
                column.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                column.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                column.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
                column.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24)
            ])
            aboutWindow = panel
        }
        aboutWindow?.orderFront(nil)
        NSApp.setActivationPolicy(.regular)
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSettings() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.showSettings() }
            return
        }
        // 在整个激活过程保持明确意图，避免激活回调把 Dock 模式切回去。
        refreshHelperHealth()
        showingSettings = true
        if window == nil { buildWindow() }
        guard let settingsWindow = window else { showingSettings = false; return }
        loadRows()
        routesTable?.reloadData()
        // 先让窗口可见，再改变激活策略，系统不再经历“有 Dock、无窗口”的中间状态。
        settingsWindow.orderFront(nil)
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 620),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.title = "RouteDuo"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.minSize = NSSize(width: 640, height: 560)
        w.center()

        let content = NSVisualEffectView()
        content.material = .underWindowBackground
        content.blendingMode = .behindWindow
        content.state = .followsWindowActiveState
        w.contentView = content

        func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                   color: NSColor = .labelColor) -> NSTextField {
            let view = NSTextField(wrappingLabelWithString: text)
            view.font = .systemFont(ofSize: size, weight: weight)
            view.textColor = color
            view.translatesAutoresizingMaskIntoConstraints = false
            return view
        }
        func stack(_ views: [NSView], vertical: Bool = false, spacing: CGFloat = 12) -> NSStackView {
            let view = NSStackView(views: views)
            view.orientation = vertical ? .vertical : .horizontal
            view.alignment = vertical ? .leading : .centerY
            view.spacing = spacing
            view.translatesAutoresizingMaskIntoConstraints = false
            return view
        }
        func symbolButton(_ symbol: String, title: String, action: Selector) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!, target: self, action: action)
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = title
            button.setAccessibilityLabel(title)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 32), button.heightAnchor.constraint(equalToConstant: 30)])
            return button
        }

        let heading = label("网络分流", size: 26, weight: .bold)
        let subtitle = label("配置的地址走分流网络，其他流量走默认网络。", size: 13, color: .secondaryLabelColor)
        let header = stack([heading, subtitle], vertical: true, spacing: 6)
        content.addSubview(header)

        let networkIcon = NSImageView(image: NSImage(systemSymbolName: "network", accessibilityDescription: nil)!)
        networkIcon.contentTintColor = .controlAccentColor
        networkIcon.translatesAutoresizingMaskIntoConstraints = false
        networkIcon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        networkIcon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        defaultNetworkLabel = label(currentDefaultNetworkSummary(), size: 13, weight: .medium)
        defaultNetworkLabel.maximumNumberOfLines = 3
        let networkText = stack([label("当前网络", size: 11, weight: .semibold, color: .secondaryLabelColor), defaultNetworkLabel], vertical: true, spacing: 5)
        switchNetworkButton = NSButton(title: "设定服务顺序…", target: self, action: #selector(switchNetworks))
        switchNetworkButton.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "设定服务顺序")
        switchNetworkButton.imagePosition = .imageLeading
        if #available(macOS 26.0, *) {
            switchNetworkButton.bezelStyle = .glass
            switchNetworkButton.borderShape = .capsule
        } else {
            switchNetworkButton.bezelStyle = .rounded
        }
        switchNetworkButton.controlSize = .regular
        switchNetworkButton.font = .systemFont(ofSize: 12, weight: .regular)
        switchNetworkButton.image = switchNetworkButton.image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        switchNetworkButton.imageHugsTitle = true
        switchNetworkButton.toolTip = "拖动调整系统网络服务顺序；应用前会关闭分流"
        switchNetworkButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        switchNetworkButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            switchNetworkButton.heightAnchor.constraint(equalToConstant: 30),
            switchNetworkButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 116)
        ])
        content.addSubview(switchNetworkButton)
        let networkRow = stack([networkIcon, networkText], spacing: 14)
        let networkCard = NSView()
        networkCard.translatesAutoresizingMaskIntoConstraints = false
        networkCard.wantsLayer = true
        networkCard.layer?.cornerRadius = 14
        networkCard.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.06).cgColor
        networkCard.addSubview(networkRow)
        content.addSubview(networkCard)
        NSLayoutConstraint.activate([
            networkRow.leadingAnchor.constraint(equalTo: networkCard.leadingAnchor, constant: 18),
            networkRow.trailingAnchor.constraint(equalTo: networkCard.trailingAnchor, constant: -18),
            networkRow.topAnchor.constraint(equalTo: networkCard.topAnchor, constant: 16),
            networkRow.bottomAnchor.constraint(equalTo: networkCard.bottomAnchor, constant: -16)
        ])

        let sectionTitle = label("分流地址", size: 15, weight: .semibold)
        let add = symbolButton("plus", title: "添加地址", action: #selector(addRow))
        let remove = symbolButton("minus", title: "删除选中地址", action: #selector(removeRow))
        remove.isEnabled = false
        removeAddressButton = remove
        let more = NSPopUpButton(frame: .zero, pullsDown: true)
        more.bezelStyle = .accessoryBarAction
        more.isBordered = false
        more.addItem(withTitle: "")
        more.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多")
        more.toolTip = "导入或导出地址"
        more.addItem(withTitle: "导入分流地址…")
        more.lastItem?.target = self
        more.lastItem?.action = #selector(importRoutes)
        more.addItem(withTitle: "导出分流地址…")
        more.lastItem?.target = self
        more.lastItem?.action = #selector(exportRoutes)
        more.translatesAutoresizingMaskIntoConstraints = false
        more.setContentHuggingPriority(.required, for: .horizontal)
        more.setContentCompressionResistancePriority(.required, for: .horizontal)
        more.alignment = .center
        NSLayoutConstraint.activate([more.widthAnchor.constraint(equalToConstant: 42), more.heightAnchor.constraint(equalToConstant: 30)])
        let actions = stack([add, remove, more], spacing: 4)
        actions.alignment = .centerY
        actions.distribution = .fill
        actions.setCustomSpacing(4, after: remove)
        let actionContent = NSView()
        actionContent.addSubview(actions)
        let actionSurface: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 18
            if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
            glass.contentView = actionContent
            actionSurface = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.wantsLayer = true
            material.layer?.cornerRadius = 18
            material.addSubview(actionContent)
            actionContent.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                actionContent.leadingAnchor.constraint(equalTo: material.leadingAnchor),
                actionContent.trailingAnchor.constraint(equalTo: material.trailingAnchor),
                actionContent.topAnchor.constraint(equalTo: material.topAnchor),
                actionContent.bottomAnchor.constraint(equalTo: material.bottomAnchor)
            ])
            actionSurface = material
        }
        actionSurface.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sectionTitle)
        content.addSubview(actionSurface)
        NSLayoutConstraint.activate([
            actions.centerXAnchor.constraint(equalTo: actionContent.centerXAnchor),
            actions.centerYAnchor.constraint(equalTo: actionContent.centerYAnchor),
            actions.widthAnchor.constraint(equalToConstant: 114),
            actions.heightAnchor.constraint(equalToConstant: 30)
        ])

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 12
        scroll.layer?.masksToBounds = true
        routesTable = RouteAddressTableView(frame: .zero)
        routesTable.style = .inset
        routesTable.rowHeight = 38
        routesTable.intercellSpacing = NSSize(width: 12, height: 2)
        routesTable.delegate = self
        routesTable.dataSource = self
        routesTable.usesAlternatingRowBackgroundColors = false
        routesTable.backgroundColor = .controlBackgroundColor
        routesTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        routesTable.registerForDraggedTypes([routeRowPasteboardType])
        routesTable.setDraggingSourceOperationMask(.move, forLocal: true)
        routesTable.addTableColumn(makeColumn("address", title: "IP 地址或域名", width: 350))
        routesTable.addTableColumn(makeColumn("note", title: "备注", width: 220))
        scroll.documentView = routesTable
        content.addSubview(scroll)

        let hint = label("拖动可调整顺序 · 自动保存", size: 11, color: .tertiaryLabelColor)
        content.addSubview(hint)
        statusLabel = label("修改分流地址后会自动关闭分流，请手动重新启用。", size: 12, color: .secondaryLabelColor)
        statusLabel.maximumNumberOfLines = 2
        content.addSubview(statusLabel)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(divider)
        let serviceTitle = label("系统辅助服务", size: 13, weight: .medium)
        let serviceHint = label(helperStatus, size: 11, color: .secondaryLabelColor)
        helperHint = serviceHint
        let serviceText = stack([serviceTitle, serviceHint], vertical: true, spacing: 4)
        helperButton = NSButton(title: helperReady ? "管理辅助服务…" : (helperInstalled() ? "修复辅助服务" : "安装辅助服务"), target: self, action: #selector(helperButtonClicked))
        helperButton.bezelStyle = .rounded
        helperButton.controlSize = .regular
        helperButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(serviceText)
        content.addSubview(helperButton)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 52),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            switchNetworkButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            switchNetworkButton.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            networkCard.topAnchor.constraint(equalTo: switchNetworkButton.bottomAnchor, constant: 14),
            networkCard.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            networkCard.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            sectionTitle.topAnchor.constraint(equalTo: networkCard.bottomAnchor, constant: 26),
            sectionTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            actionSurface.centerYAnchor.constraint(equalTo: sectionTitle.centerYAnchor),
            actionSurface.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            actionSurface.widthAnchor.constraint(equalToConstant: 138),
            actionSurface.heightAnchor.constraint(equalToConstant: 36),
            scroll.topAnchor.constraint(equalTo: actionSurface.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 9),
            hint.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            divider.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 18),
            divider.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            serviceText.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 16),
            serviceText.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            serviceText.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
            helperButton.centerYAnchor.constraint(equalTo: serviceText.centerYAnchor),
            helperButton.trailingAnchor.constraint(equalTo: header.trailingAnchor)
        ])
        window = w
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window || closingWindow === aboutWindow else { return }
        if closingWindow === window { showingSettings = false }
        closingWindow.orderOut(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.showingSettings, self.window?.isVisible != true,
                  self.aboutWindow?.isVisible != true else { return }
            if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
        }
    }

    private func helperInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/Library/PrivilegedHelperTools/com.cooper.WorkRouteMenu.helper") &&
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.cooper.WorkRouteMenu.helper.plist")
    }

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.cooper.WorkRouteMenu.plist")
    }

    private func isLaunchAtLoginEnabled() -> Bool { FileManager.default.fileExists(atPath: launchAgentURL.path) }

    @objc private func toggleAutoEnable() {
        guard !networkSwitchInProgress else { return }
        let enabled = !UserDefaults.standard.bool(forKey: autoEnableKey)
        UserDefaults.standard.set(enabled, forKey: autoEnableKey)
        autoEnableItem.state = enabled ? .on : .off
        if enabled {
            autoEnablePausedForSession = false
            scheduleNetworkRefresh()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if !isLaunchAtLoginEnabled() {
                let appPath = Bundle.main.bundlePath
                let plist: [String: Any] = [
                    "Label": "com.cooper.WorkRouteMenu",
                    "ProgramArguments": ["/usr/bin/open", "-a", appPath],
                    "RunAtLoad": true,
                    "ProcessType": "Interactive"
                ]
                let directory = launchAgentURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: launchAgentURL, options: .atomic)
                statusLabel?.stringValue = "已开启开机自动启动。"
            } else {
                try? FileManager.default.removeItem(at: launchAgentURL)
                statusLabel?.stringValue = "已关闭开机自动启动。"
            }
        } catch {
            statusLabel?.stringValue = "设置开机启动失败：\(error.localizedDescription)"
            let alert = NSAlert()
            alert.messageText = "设置开机启动失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        launchAtLoginItem.state = isLaunchAtLoginEnabled() ? .on : .off
    }

    private func updateHelperButton() {
        helperButton?.title = helperReady ? "管理辅助服务…" : (helperInstalled() ? "修复辅助服务" : "安装辅助服务")
        helperButton?.isEnabled = !helperInstallationInProgress
        helperHint?.stringValue = helperStatus
    }

    @objc private func helperButtonClicked() {
        guard !networkSwitchInProgress, !enableInProgress, !disableInProgress, !helperInstallationInProgress else { return }
        guard helperReady else { installHelper(); return }
        let alert = NSAlert()
        alert.messageText = "管理辅助服务"
        alert.informativeText = "修复会清理当前分流路由并重新安装、注册辅助服务。卸载也会先关闭分流。"
        alert.addButton(withTitle: "修复辅助服务")
        alert.addButton(withTitle: "卸载辅助服务")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: installHelper()
        case .alertSecondButtonReturn: uninstallHelper()
        default: break
        }
    }

    private func helperVersionMatches() -> Bool {
        guard let bundled = Bundle.main.url(forResource: "com.cooper.WorkRouteMenu.helper", withExtension: nil),
              let expected = try? Data(contentsOf: bundled),
              let actual = try? Data(contentsOf: URL(fileURLWithPath: "/Library/PrivilegedHelperTools/com.cooper.WorkRouteMenu.helper")) else { return false }
        return expected == actual
    }

    private func refreshHelperHealth() {
        guard !helperInstallationInProgress, !enableInProgress, !disableInProgress,
              !networkReconfigurationInProgress, !networkSwitchInProgress else { return }
        guard helperInstalled(), helperVersionMatches() else {
            helperReady = false
            helperStatus = helperInstalled() ? "辅助服务需要更新，请点击修复" : "尚未安装辅助服务"
            updateHelperButton()
            return
        }
        helperStatus = "正在检查辅助服务"
        updateHelperButton()
        requestHelper(timeout: 5) { proxy, reply in proxy.healthCheck(withReply: reply) } completion: { [weak self] success, output in
            guard let self else { return }
            self.helperReady = success && output == "RouteDuoHelper/2"
            self.helperStatus = self.helperReady ? "辅助服务正常 · 已开启异常退出清理" : "辅助服务不可用，请点击修复：\(output)"
            self.updateHelperButton()
            if self.helperReady, !self.routesEnabled, !self.enableInProgress {
                UserDefaults.standard.removeObject(forKey: self.appliedRoutesKey)
                self.scheduleNetworkRefresh()
            }
        }
    }

    // One persistent XPC connection owns the routing session. Do not invalidate
    // after each request: disconnect is the helper's crash-cleanup signal.
    private func requestHelper(timeout: TimeInterval = 20,
                               invoke: (RouteHelperProtocol, @escaping (Bool, String) -> Void) -> Void,
                               completion: @escaping (Bool, String) -> Void) {
        precondition(Thread.isMainThread)
        let connection: NSXPCConnection
        if let current = helperConnection { connection = current }
        else {
            connection = NSXPCConnection(machServiceName: "com.cooper.WorkRouteMenu.helper", options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: RouteHelperProtocol.self)
            helperConnection = connection
            let disconnected = { [weak self, weak connection] in
                DispatchQueue.main.async {
                    guard let self, let connection, self.helperConnection === connection else { return }
                    self.failHelperSession("辅助服务连接已断开，请修复辅助服务后重试")
                }
            }
            connection.invalidationHandler = disconnected
            connection.interruptionHandler = disconnected
            connection.resume()
        }
        let id = UUID()
        helperRequests[id] = completion
        let reply: (Bool, String) -> Void = { [weak self] success, output in
            DispatchQueue.main.async {
                guard let callback = self?.helperRequests.removeValue(forKey: id) else { return }
                callback(success, output)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.helperRequests[id] != nil else { return }
            self.failHelperSession("操作超时，已停止本次分流会话；辅助服务正在清理路由，请修复后重试")
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.helperConnection === connection else { return }
                self.failHelperSession("辅助服务请求失败：\(error.localizedDescription)")
            }
        }) as? RouteHelperProtocol else {
            failHelperSession("无法连接辅助服务，请点击修复")
            return
        }
        invoke(proxy, reply)
    }

    private func failHelperSession(_ message: String) {
        let connection = helperConnection
        helperConnection = nil
        connection?.invalidate()
        helperReady = false
        helperStatus = message
        autoEnablePausedForSession = true
        let callbacks = Array(helperRequests.values)
        helperRequests.removeAll()
        callbacks.forEach { $0(false, message) }
        enableInProgress = false
        disableInProgress = false
        networkReconfigurationInProgress = false
        pendingQuit = false
        pendingUninstall = false
        if networkSwitchInProgress { finishNetworkSwitch(error: message) }
        finishAutomaticDisable(message: message)
        toggleItem?.isEnabled = true
        updateHelperButton()
        logServiceOrder(message)
        let alert = NSAlert()
        alert.messageText = "辅助服务操作未完成"
        alert.informativeText = message + "。可在设置窗口点击“修复辅助服务”。"
        alert.addButton(withTitle: "知道了")
        if let window, window.isVisible, window.attachedSheet == nil { alert.beginSheetModal(for: window) }
        else if window?.attachedSheet == nil { DispatchQueue.main.async { alert.runModal() } }
    }

    private func makeColumn(_ identifier: String, title: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        return column
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        button.image = routesEnabled ? enabledStatusImage : disabledStatusImage
        button.title = ""
        button.toolTip = routesEnabled ? "网络分流：已启用" : "网络分流：未启用"
        button.contentTintColor = nil
        button.alphaValue = routesEnabled ? 1.0 : 0.55
    }

    private func makeStatusImage() -> NSImage {
        guard let source = NSImage(named: "dual-port-status-icon") else { return NSImage() }
        // 保持原图比例：高度顶满，左右按比例留白，避免正方形图标被拉伸。
        let image = NSImage(size: NSSize(width: 22, height: 17))
        image.lockFocus()
        let sourceSize = source.size
        let scale = min(image.size.width / sourceSize.width, image.size.height / sourceSize.height)
        let drawSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let drawRect = NSRect(
            x: (image.size.width - drawSize.width) / 2,
            y: (image.size.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        source.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        image.unlockFocus()
        image.isTemplate = true
        image.accessibilityDescription = "网络分流"
        return image
    }

    private func loadRows() {
        let text = UserDefaults.standard.string(forKey: defaultsKey) ?? defaultDomains
        routeRows = text.split(separator: "\n").compactMap { raw in
            let parts = String(raw).split(separator: "|", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.count == 2 { return [normalize(parts[1]), parts[0]] }
            let address = normalize(parts[0]); return address.isEmpty ? nil : [address, ""]
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { routeRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, row < routeRows.count else { return nil }
        let identifier = tableColumn!.identifier
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField()
            field.identifier = identifier
            field.isBordered = false
            field.drawsBackground = false
            field.isEditable = true
            field.font = identifier.rawValue == "address" ? .monospacedSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 13)
            field.placeholderString = identifier.rawValue == "address" ? "例如 10.0.0.1 或 example.com" : "添加备注"
            field.usesSingleLineMode = true
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            // 保持单行文字的自然高度；固定较高的文本框会让字形在框内偏上。
            field.setContentHuggingPriority(.required, for: .vertical)
            field.setContentCompressionResistancePriority(.required, for: .vertical)
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.tag = row
        cell.textField?.stringValue = routeRows[row][id == "address" ? 0 : 1]
        return cell
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field.tag >= 0, field.tag < routeRows.count else { return }
        let index = field.identifier?.rawValue == "address" ? 0 : 1
        routeRows[field.tag][index] = field.stringValue
        saveRows()
    }

    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard let id = tableColumn?.identifier.rawValue, row < routeRows.count else { return }
        routeRows[row][id == "address" ? 0 : 1] = String(describing: object ?? "")
        saveRows()
    }

    @objc private func addRow() {
        guard let table = routesTable else { return }
        routeRows.append(["", ""])
        saveRows()
        table.reloadData()
        let row = routeRows.count - 1
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        updateRemoveButton()
    }

    @objc private func removeRow() {
        guard let table = routesTable else { return }
        guard window?.makeFirstResponder(table) != false else { return }
        let row = table.selectedRow
        guard row >= 0, row < routeRows.count else { return }
        routeRows.remove(at: row)
        saveRows()
        table.reloadData()
        updateRemoveButton()
    }

    private func updateRemoveButton() {
        removeAddressButton?.isEnabled = routesTable.selectedRow >= 0
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateRemoveButton() }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row >= 0, row < routeRows.count else { return nil }
        // 先提交正在编辑的单元格，避免移动后按旧行号保存编辑内容。
        guard tableView.window?.makeFirstResponder(tableView) != false else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: routeRowPasteboardType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropOperation == .above,
              info.draggingSource as? NSTableView === tableView else { return [] }
        tableView.setDropRow(min(max(row, 0), routeRows.count), dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard dropOperation == .above,
              info.draggingSource as? NSTableView === tableView,
              let value = info.draggingPasteboard.pasteboardItems?.first?.string(forType: routeRowPasteboardType),
              let sourceRow = Int(value), sourceRow >= 0, sourceRow < routeRows.count else { return false }

        var destinationRow = min(max(row, 0), routeRows.count)
        let moved = routeRows.remove(at: sourceRow)
        if sourceRow < destinationRow { destinationRow -= 1 }
        destinationRow = min(max(destinationRow, 0), routeRows.count)
        routeRows.insert(moved, at: destinationRow)
        saveRows()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: destinationRow), byExtendingSelection: false)
        if !addressChangeCleanupPending { statusLabel?.stringValue = "顺序已自动保存。" }
        updateRemoveButton()
        return true
    }

    private func showTransferError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "无法导入或导出分流地址"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    @objc private func exportRoutes() {
        guard window?.makeFirstResponder(routesTable) != false else { return }
        do {
            let records = entries().map { RouteAddressFile.Record(address: $0.address, note: $0.note) }
            let file = RouteAddressFile(version: 1, routes: records)
            try file.validate()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(file)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "RouteDuo-分流地址.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            statusLabel?.stringValue = "已导出 \(records.count) 条分流地址。"
        } catch { showTransferError(error.localizedDescription) }
    }

    @objc private func importRoutes() {
        guard window?.makeFirstResponder(routesTable) != false else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 5 * 1024 * 1024 else { throw RouteAddressFile.ValidationError("文件超过 5 MB，请检查文件是否正确。") }
            let file: RouteAddressFile
            do { file = try JSONDecoder().decode(RouteAddressFile.self, from: Data(contentsOf: url)) }
            catch { throw RouteAddressFile.ValidationError("文件格式不正确。请选择 RouteDuo 导出的 JSON 文件，需包含 version、routes，以及每条记录的 address 和 note。") }
            try file.validate()
            var known = Set(cleanedDomains().map { $0.lowercased() })
            var additions: [[String]] = []
            for record in file.routes {
                let address = record.address.trimmingCharacters(in: .whitespacesAndNewlines)
                if known.insert(address.lowercased()).inserted {
                    additions.append([address, record.note])
                }
            }
            routeRows.append(contentsOf: additions)
            saveRows()
            routesTable.reloadData()
            updateRemoveButton()
            if !addressChangeCleanupPending && !autoEnablePausedForSession {
                statusLabel?.stringValue = "已导入 \(additions.count) 条，跳过重复地址 \(file.routes.count - additions.count) 条。"
            }
        } catch { showTransferError(error.localizedDescription) }
    }

    private func saveRows() {
        // 比较地址集合，备注、排序和空行不改变分流目标。
        let previous = UserDefaults.standard.string(forKey: defaultsKey) ?? defaultDomains
        let oldAddresses = Set(previous.split(separator: "\n").compactMap { line -> String? in
            let address = normalize(String(line).components(separatedBy: "|").last ?? "").lowercased()
            return address.isEmpty ? nil : address
        })
        let values = entries()
        let newAddresses = Set(values.map { $0.address.lowercased() })
        UserDefaults.standard.set(values.map { "\($0.note) | \($0.address)" }.joined(separator: "\n"), forKey: defaultsKey)
        guard oldAddresses != newAddresses else {
            if !addressChangeCleanupPending { statusLabel?.stringValue = "已自动保存。" }
            return
        }
        routingSession = UUID()
        // 保留自动启用选项，编辑后仅在本次运行暂停，重启后重新按选项判断。
        autoEnablePausedForSession = true
        pendingBackgroundDomains = []
        pendingBackgroundTopology = nil
        if routesEnabled || enableInProgress || disableInProgress || networkReconfigurationInProgress || !appliedRouteIPs().isEmpty {
            addressChangeCleanupPending = true
            statusLabel?.stringValue = "分流地址已修改，正在清理路由…"
            finishAddressChangeCleanupIfReady()
        } else {
            statusLabel?.stringValue = "分流地址已保存，请手动启用分流。"
        }
        refreshConfiguredDomainsInBackground()
        scheduleNetworkRefresh()
    }

    private func finishAddressChangeCleanupIfReady() {
        guard addressChangeCleanupPending, !enableInProgress, !disableInProgress,
              !networkReconfigurationInProgress else { return }
        addressChangeCleanupPending = false
        disableRoutes(message: addressChangeMessage)
    }

    @objc private func saveDomains() {
        saveRows()
    }

    private func entries() -> [(note: String, address: String)] {
        routeRows.compactMap { row in
            guard row.count >= 2 else { return nil }
            let address = normalize(row[0]); guard !address.isEmpty else { return nil }
            return (row[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名" : row[1], address)
        }
    }

    private func cleanedDomains() -> [String] { entries().map { $0.address } }

    private func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("http://") { value.removeFirst(7) }
        if value.hasPrefix("https://") { value.removeFirst(8) }
        if let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
        // 路由按主机地址工作，端口和路径不参与路由。
        if let colon = value.lastIndex(of: ":"), value[..<colon].contains(".") {
            value = String(value[..<colon])
        }
        return value
    }

    private func startNetworkMonitoring() {
        stopNetworkMonitoring()
        helperConnection?.invalidate()
        let wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
        let wiredMonitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
        let generalMonitor = NWPathMonitor()
        for monitor in [wifiMonitor, wiredMonitor, generalMonitor] {
            monitor.pathUpdateHandler = { [weak self] _ in
                self?.scheduleNetworkRefresh()
            }
            monitor.start(queue: networkMonitorQueue)
            networkMonitors.append(monitor)
        }

        var context = SCDynamicStoreContext(version: 0,
                                            info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue().scheduleNetworkRefresh()
        }
        if let store = SCDynamicStoreCreate(nil, "RouteDuo.NetworkEvents" as CFString, callback, &context) {
            let patterns = [
                "State:/Network/Global/IPv4",
                "State:/Network/Service/.*/IPv4",
                "State:/Network/Service/.*/IPv6",
                "State:/Network/Interface/.*/Link",
                "Setup:/Network/Global/IPv4"
            ] as CFArray
            SCDynamicStoreSetNotificationKeys(store, nil, patterns)
            if let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                dynamicStore = store
                dynamicStoreSource = source
            }
        }
        scheduleNetworkRefresh()
    }

    private func stopNetworkMonitoring() {
        pendingNetworkRefresh?.cancel()
        pendingNetworkRefresh = nil
        networkMonitors.forEach { $0.cancel() }
        networkMonitors.removeAll()
        if let source = dynamicStoreSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        dynamicStoreSource = nil
        dynamicStore = nil
    }

    private func scheduleNetworkRefresh() {
        networkMonitorQueue.async { [weak self] in
            guard let self else { return }
            self.pendingNetworkRefresh?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.refreshNetworkState() }
            self.pendingNetworkRefresh = item
            self.networkMonitorQueue.asyncAfter(deadline: .now() + 0.8, execute: item)
        }
    }

    private func isAttachedAppleUSBNetwork(_ bsd: String) -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOEthernetInterface"), &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        while true {
            let interface = IOIteratorNext(iterator)
            guard interface != 0 else { break }
            defer { IOObjectRelease(interface) }
            let name = IORegistryEntryCreateCFProperty(interface, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            guard name == bsd else { continue }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(interface, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
            defer { IOObjectRelease(parent) }
            let driver = IORegistryEntryCreateCFProperty(parent, "CFBundleIdentifier" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String ?? ""
            return driver.hasPrefix("com.apple.") && driver.contains("AppleUSBEthernetHost")
        }
        return false
    }

    private func serviceConnectionStatus(id: String, bsd: String, enabled: Bool) -> String {
        guard enabled else { return "已停用" }
        let store = SCDynamicStoreCreate(nil, "RouteDuo.ServiceStatus" as CFString, nil, nil)
        var hasAddress = false
        var hasRouter = false
        for family in ["IPv4", "IPv6"] {
            let state = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Service/\(id)/\(family)" as CFString) as? [String: Any] }
            let addresses = state?["Addresses"] as? [String] ?? []
            hasAddress = hasAddress || !addresses.isEmpty
            hasRouter = hasRouter || (!(state?["Router"] as? String ?? "").isEmpty && !addresses.isEmpty)
        }
        let link = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Interface/\(bsd)/Link" as CFString) as? [String: Any] }
        // IFF_RUNNING 对虚拟网桥不代表物理链路已接通，不用它判断连接。
        if hasRouter { return "已连接" }
        if hasAddress || link?["Active"] as? Bool == true { return "待用" }
        if isAttachedAppleUSBNetwork(bsd) { return "设备已连接" }
        return "未连接"
    }

    private func refreshServiceOrderStatuses() {
        guard let editor = serviceOrderEditor,
              let prefs = SCPreferencesCreate(nil, "RouteDuo.StatusRefresh" as CFString, nil) else { return }
        editor.updateStatuses { item in
            guard let service = SCNetworkServiceCopy(prefs, item.id as CFString),
                  let interface = SCNetworkServiceGetInterface(service),
                  let bsd = SCNetworkInterfaceGetBSDName(interface) as String? else { return ("未连接", false) }
            let enabled = SCNetworkServiceGetEnabled(service)
            return (self.serviceConnectionStatus(id: item.id, bsd: bsd, enabled: enabled), enabled)
        }
    }

    private func helperServiceRegistered() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/com.cooper.WorkRouteMenu.helper"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 }
        catch { return false }
    }

    @objc private func switchNetworks() {
        guard !networkSwitchInProgress, !enableInProgress, !disableInProgress,
              !networkReconfigurationInProgress, !addressChangeCleanupPending,
              !pendingQuit, !pendingUninstall else {
            statusLabel?.stringValue = "当前操作尚未完成，请稍后再切换网络。"
            return
        }
        guard helperInstalled(), helperServiceRegistered() else {
            let alert = NSAlert()
            alert.messageText = "需要安装或修复辅助程序"
            alert.informativeText = "系统辅助服务未注册或不可用，无法保存服务顺序。点击修复会重新注册服务，完成后请重新设定顺序。"
            alert.addButton(withTitle: "安装或修复")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn { installHelper() }
            return
        }
        // 安装 App 不会替换 /Library 中已运行的旧辅助程序。
        if let bundled = Bundle.main.url(forResource: "com.cooper.WorkRouteMenu.helper", withExtension: nil),
           let packagedData = try? Data(contentsOf: bundled),
           let installedData = try? Data(contentsOf: URL(fileURLWithPath: "/Library/PrivilegedHelperTools/com.cooper.WorkRouteMenu.helper")),
           packagedData != installedData {
            let alert = NSAlert()
            alert.messageText = "需要更新辅助程序"
            alert.informativeText = "已安装的辅助程序与当前 App 版本不同，更新后才能保存服务顺序。更新需要管理员授权。"
            alert.addButton(withTitle: "更新辅助程序")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn { installHelper() }
            return
        }
        guard let preferences = SCPreferencesCreate(nil, "RouteDuo.Switch" as CFString, nil),
              let set = SCNetworkSetCopyCurrent(preferences),
              let ids = SCNetworkSetGetServiceOrder(set) as? [String],
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else {
            statusLabel?.stringValue = "无法读取系统网络服务，请稍后重试。"
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: services.compactMap { service -> (String, SCNetworkService)? in
            guard let id = SCNetworkServiceGetServiceID(service) as String? else { return nil }
            return (id, service)
        })
        let hardware = Set((SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []).compactMap { SCNetworkInterfaceGetBSDName($0) as String? })
        logServiceOrder("读取服务顺序 location=\(SCNetworkSetGetSetID(set) as String? ?? "unknown") order=\(ids)")
        for id in ids {
            guard let service = byID[id] else {
                logServiceOrder("服务 id=\(id) currentLocationMember=false")
                continue
            }
            let bsd = SCNetworkServiceGetInterface(service).flatMap { SCNetworkInterfaceGetBSDName($0) as String? } ?? "unknown"
            logServiceOrder("服务 id=\(id) name=\(SCNetworkServiceGetName(service) as String? ?? "unknown") interface=\(bsd) enabled=\(SCNetworkServiceGetEnabled(service)) currentLocationMember=true interfaceListed=\(hardware.contains(bsd))")
        }
        let rows = ids.compactMap { id -> ServiceOrderEditor.Service? in
            guard let service = byID[id], let name = SCNetworkServiceGetName(service) as String?,
                  let interface = SCNetworkServiceGetInterface(service), let bsd = SCNetworkInterfaceGetBSDName(interface) as String? else { return nil }
            let enabled = SCNetworkServiceGetEnabled(service)
            return ServiceOrderEditor.Service(id: id, name: name,
                status: serviceConnectionStatus(id: id, bsd: bsd, enabled: enabled), enabled: enabled)
        }
        guard rows.count == ids.count, !rows.isEmpty else {
            statusLabel?.stringValue = "无法读取完整网络服务列表，请稍后重试。"
            return
        }
        let editor = ServiceOrderEditor(services: rows)
        serviceOrderEditor = editor
        let alert = NSAlert()
        alert.messageText = "设定服务顺序"
        alert.informativeText = "拖动服务调整优先级，越靠上优先级越高。系统会优先使用可用的网络。应用时会先关闭分流，并暂停本次运行的自动启用。"
        alert.accessoryView = editor.view
        alert.addButton(withTitle: "应用")
        alert.buttons[0].keyEquivalent = "\r"
        let applyButton = alert.buttons[0]
        applyButton.isEnabled = false
        editor.onOrderChanged = { [weak applyButton] changed in
            applyButton?.isEnabled = changed
        }
        alert.addButton(withTitle: "取消")
        guard let parent = window else { return }
        parent.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 使用附属 sheet，避免独立模态窗口与应用/Dock 激活策略竞争。
        // completion 强持有 editor，直到用户确认，保留拖动后的数据源。
        alert.beginSheetModal(for: parent) { [weak self, editor] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.applyServiceOrder(editor.services.map { $0.id }, original: ids)
        }
    }

    private func applyServiceOrder(_ reordered: [String], original ids: [String]) {
        logServiceOrder("应用点击 original=\(ids) requested=\(reordered)")
        guard reordered != ids else {
            statusLabel?.stringValue = "服务顺序未改变。"
            return
        }
        // 编辑期间系统可能增删服务或更改顺序，拒绝覆盖外部变更。
        guard let freshPreferences = SCPreferencesCreate(nil, "RouteDuo.OrderCheck" as CFString, nil),
              let freshSet = SCNetworkSetCopyCurrent(freshPreferences),
              SCNetworkSetGetServiceOrder(freshSet) as? [String] == ids,
              let freshServices = SCNetworkSetCopyServices(freshSet) as? [SCNetworkService],
              Set(ids).isSubset(of: Set(freshServices.compactMap { SCNetworkServiceGetServiceID($0) as String? })),
              !enableInProgress, !disableInProgress, !networkReconfigurationInProgress,
              !addressChangeCleanupPending else {
            logServiceOrder("提交前检查失败 enable=\(enableInProgress) disable=\(disableInProgress) reconfigure=\(networkReconfigurationInProgress) editCleanup=\(addressChangeCleanupPending)")
            statusLabel?.stringValue = "网络状态或服务列表已变化，请重新打开服务顺序后再应用。"
            return
        }
        expectedDefaultInterface = nil
        expectedDefaultName = nil
        switchVerification?.cancel()
        UserDefaults.standard.set(ids, forKey: savedNetworkOrderKey)
        autoEnablePausedForSession = true
        networkSwitchInProgress = true
        // 辅助程序提交的是服务 ID 顺序，不是显示名称。
        pendingNetworkOrder = reordered
        routingSession = UUID()
        pendingBackgroundDomains = []
        pendingBackgroundTopology = nil
        switchNetworkButton?.isEnabled = false
        toggleItem?.isEnabled = false
        statusLabel?.stringValue = "正在关闭分流并清理路由…"
        if routesEnabled || !appliedRouteIPs().isEmpty {
            disableRoutes(message: "分流已关闭，正在调整系统网络顺序…", notifyOnDisable: false)
            // 无 IP 的关闭操作同步完成，不会进入 XPC 回调。
            if !disableInProgress { applyPendingNetworkOrder() }
        } else {
            applyPendingNetworkOrder()
        }
    }

    private func logServiceOrder(_ message: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RouteDuo")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("service-order.log")
        let data = Data("\(Date()) \(message)\n".utf8)
        if !FileManager.default.fileExists(atPath: url.path) { try? data.write(to: url) }
        else if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private func applyPendingNetworkOrder() {
        guard networkSwitchInProgress, let order = pendingNetworkOrder else { return }
        pendingNetworkOrder = nil
        statusLabel?.stringValue = "正在调整系统网络顺序…"
        logServiceOrder("发送辅助程序 order=\(order)")
        requestHelper { proxy, reply in proxy.setNetworkServiceOrder(order, withReply: reply) } completion: { [weak self] success, output in
            DispatchQueue.main.async {
                var error: String? = success ? nil : output
                if success {
                    let prefs = SCPreferencesCreate(nil, "RouteDuo.OrderReadback" as CFString, nil)
                    let actual = prefs.flatMap { SCNetworkSetCopyCurrent($0) }.flatMap { SCNetworkSetGetServiceOrder($0) as? [String] }
                    if actual != order { error = "系统服务顺序与所选顺序不一致，未确认保存成功" }
                }
                self?.finishNetworkSwitch(error: error)
            }
        }
    }

    private func finishNetworkSwitch(error: String?) {
        pendingNetworkOrder = nil
        networkSwitchInProgress = false
        switchNetworkButton?.isEnabled = true
        toggleItem?.isEnabled = !enableInProgress && !disableInProgress
        storeCachedTopology(nil)
        if let error {
            expectedDefaultInterface = nil
            expectedDefaultName = nil
            statusLabel?.stringValue = "保存失败：\(error)"
            logServiceOrder("保存失败：\(error)")
            if let parent = window, parent.attachedSheet == nil {
                let alert = NSAlert()
                alert.messageText = "服务顺序未保存"
                alert.informativeText = error
                alert.addButton(withTitle: "知道了")
                alert.beginSheetModal(for: parent)
            }
        } else {
            logServiceOrder("系统回读确认保存成功")
            statusLabel?.stringValue = "服务顺序已保存并验证，请手动启用分流。"
            verifySwitchedDefault(timedOut: false)
            if expectedDefaultInterface != nil {
                let verification = DispatchWorkItem { [weak self] in self?.verifySwitchedDefault(timedOut: true) }
                switchVerification = verification
                // 单次超时提示；正常通过网络事件完成确认，不循环轮询。
                DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: verification)
            }
        }
        scheduleNetworkRefresh()
    }

    private func verifySwitchedDefault(timedOut: Bool) {
        guard !networkSwitchInProgress, let expected = expectedDefaultInterface else { return }
        if primaryInterfaceName() == expected {
            switchVerification?.cancel()
            switchVerification = nil
            statusLabel?.stringValue = "默认网络已切换为 \(expectedDefaultName ?? expected)，请手动启用分流。"
            expectedDefaultInterface = nil
            expectedDefaultName = nil
        } else if timedOut {
            statusLabel?.stringValue = "优先级已调整，但 \(expectedDefaultName ?? expected) 尚未成为默认网络。请检查热点和 USB 连接；iPhone 可尝试关闭“需要时启用”。"
        }
    }

    private struct NetworkServiceSnapshot {
        let id: String
        let name: String
        let interface: String
        let ip: String
        let router: String
    }

    private struct NetworkTopology {
        let primaryInterface: String
        let primaryName: String
        let secondary: NetworkServiceSnapshot

        var signature: String {
            "\(primaryInterface)|\(secondary.interface)|\(secondary.ip)|\(secondary.router)"
        }
    }

    private func activeNetworkServices() -> [NetworkServiceSnapshot] {
        guard let preferences = SCPreferencesCreate(nil, "RouteDuo" as CFString, nil),
              let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else { return [] }
        let order: [String]
        if let set = SCNetworkSetCopyCurrent(preferences),
           let serviceOrder = SCNetworkSetGetServiceOrder(set) as? [String] {
            order = serviceOrder
        } else {
            order = services.compactMap { SCNetworkServiceGetServiceID($0) as String? }
        }
        let byID = Dictionary(uniqueKeysWithValues: services.compactMap { service -> (String, SCNetworkService)? in
            guard let id = SCNetworkServiceGetServiceID(service) as String? else { return nil }
            return (id, service)
        })
        guard let store = SCDynamicStoreCreate(nil, "RouteDuo.Snapshot" as CFString, nil, nil) else { return [] }
        return order.compactMap { id in
            guard let service = byID[id], SCNetworkServiceGetEnabled(service),
                  let interface = SCNetworkServiceGetInterface(service),
                  let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let state = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(id)/IPv4" as CFString) as? [String: Any],
                  let addresses = state["Addresses"] as? [String], let ip = addresses.first,
                  let router = state["Router"] as? String, !router.isEmpty else { return nil }
            let name = (SCNetworkServiceGetName(service) as String?) ?? displayName(for: bsdName)
            return NetworkServiceSnapshot(id: id, name: name, interface: bsdName, ip: ip, router: router)
        }
    }

    private func currentTopology() -> NetworkTopology? {
        guard let primary = primaryInterfaceName() else { return nil }
        let active = activeNetworkServices()
        guard let secondary = active.first(where: { $0.interface != primary }) else { return nil }
        let primaryName = active.first(where: { $0.interface == primary })?.name ?? displayName(for: primary)
        return NetworkTopology(primaryInterface: primary, primaryName: primaryName, secondary: secondary)
    }

    private func cachedTopologySnapshot() -> NetworkTopology? {
        topologyLock.lock()
        let value = cachedTopology
        topologyLock.unlock()
        return value
    }

    private func storeCachedTopology(_ topology: NetworkTopology?) {
        topologyLock.lock()
        cachedTopology = topology
        topologyLock.unlock()
    }

    private func primaryInterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "RouteDuo" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return nil }
        return value["PrimaryInterface"] as? String
    }

    private func displayName(for interfaceName: String) -> String {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return interfaceName }
        for interface in interfaces {
            if SCNetworkInterfaceGetBSDName(interface) as String? == interfaceName {
                return (SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?) ?? interfaceName
            }
        }
        return interfaceName
    }

    private func currentDefaultNetworkSummary() -> String {
        guard let name = primaryInterfaceName() else { return "当前默认网络：未连接" }
        if let topology = currentTopology() {
            return "当前默认网络：\(topology.primaryName)（\(name)）    分流网络：\(topology.secondary.name)（\(topology.secondary.interface)）"
        }
        return "当前默认网络：\(displayName(for: name))（\(name)）    分流网络：未连接"
    }

    private func refreshDefaultNetworkLabel() {
        defaultNetworkLabel?.stringValue = currentDefaultNetworkSummary()
    }

    private func networkPreflightMessage() -> String? {
        currentTopology() == nil ? "当前只检测到一个可用网络，请连接第二个网络后再启用分流。" : nil
    }

    private func refreshNetworkState() {
        let topology = currentTopology()
        let previousTopology = lastAvailableTopology
        if let topology { lastAvailableTopology = topology }
        storeCachedTopology(topology)
        let summary: String
        if let topology {
            summary = "当前默认网络：\(topology.primaryName)（\(topology.primaryInterface)）    分流网络：\(topology.secondary.name)（\(topology.secondary.interface)）"
        } else if let primary = primaryInterfaceName() {
            summary = "当前默认网络：\(displayName(for: primary))（\(primary)）    分流网络：未连接"
        } else {
            summary = "当前默认网络：未连接    分流网络：未连接"
        }
        DispatchQueue.main.async { [weak self] in
            self?.defaultNetworkLabel?.stringValue = summary
            self?.refreshServiceOrderStatuses()
            self?.verifySwitchedDefault(timedOut: false)
        }

        guard !disableInProgress, !addressChangeCleanupPending, !networkSwitchInProgress else { return }
        guard routesEnabled || UserDefaults.standard.bool(forKey: autoEnableKey) else { return }
        if !routesEnabled, UserDefaults.standard.bool(forKey: autoEnableKey), topology != nil, !enableInProgress {
            DispatchQueue.main.async { [weak self] in self?.enableRoutes(automatically: true) }
            return
        }
        guard routesEnabled else { return }
        guard !networkReconfigurationInProgress else {
            networkRefreshRequested = true
            return
        }
        guard let topology else {
            let activeInterfaces = Set(activeNetworkServices().map { $0.interface })
            var disconnectedNames: [String] = []
            if let previousTopology {
                if !activeInterfaces.contains(previousTopology.primaryInterface) {
                    disconnectedNames.append(previousTopology.primaryName)
                }
                if !activeInterfaces.contains(previousTopology.secondary.interface) {
                    disconnectedNames.append(previousTopology.secondary.name)
                }
            }
            let reason = disconnectedNames.isEmpty
                ? "当前没有两个可用网络"
                : "\(disconnectedNames.joined(separator: "、")) 已断开"
            let oldIPs = appliedRouteIPs()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.routesEnabled else { return }
                self.statusLabel?.stringValue = "\(reason)，正在清理分流路由…"
                if oldIPs.isEmpty {
                    self.finishAutomaticDisable(message: "\(reason)，网络分流已关闭。")
                } else {
                    self.disableRoutes(message: "\(reason)，旧路由已清理，网络分流已关闭。")
                }
            }
            return
        }

        let previousSignature = UserDefaults.standard.string(forKey: appliedNetworkSignatureKey)
        guard previousSignature != topology.signature else { return }
        networkReconfigurationInProgress = true
        let oldIPs = appliedRouteIPs()
        // 网络切换只需要把已经生效的路由搬到新网关，不重新等待 DNS。
        let newIPs = oldIPs
        guard !newIPs.isEmpty else {
            networkReconfigurationInProgress = false
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel?.stringValue = "网络已变化，但配置地址无法解析，分流保持原状态。"
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.routesEnabled, !self.addressChangeCleanupPending, !self.disableInProgress, !self.networkSwitchInProgress else {
                self?.networkReconfigurationInProgress = false
                self?.finishAddressChangeCleanupIfReady()
                return
            }
            self.statusLabel?.stringValue = "检测到默认网络已变化，正在清理旧路由并重新分流…"
            self.replaceRoutes(oldIPs: oldIPs, newIPs: newIPs, topology: topology)
        }
    }

    private func finishAutomaticDisable(message: String, notifyOnDisable: Bool = true) {
        let wasEnabled = routesEnabled
        routingSession = UUID()
        disableInProgress = false
        pendingBackgroundDomains = []
        pendingBackgroundTopology = nil
        routesEnabled = false
        networkReconfigurationInProgress = false
        UserDefaults.standard.set(false, forKey: "routesEnabled")
        UserDefaults.standard.removeObject(forKey: appliedNetworkSignatureKey)
        toggleItem?.title = "启用网络分流"
        updateStatusIcon()
        statusLabel?.stringValue = message
        if wasEnabled && notifyOnDisable {
            notifyDisabled(reason: message)
        }
        if pendingQuit {
            pendingQuit = false
            NSApp.terminate(nil)
        }
    }

    private func notifyEnabled(networkName: String) {
        let content = UNMutableNotificationContent()
        content.title = "网络分流已自动启用"
        content.body = "已连接到分流网络：\(networkName)"
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func notifyDisabled(reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "网络分流已关闭"
        content.body = reason
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("关闭通知发送失败：%@", error.localizedDescription) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    private func resolve(_ domain: String) -> [String] {
        let value = normalize(domain)
        if isIPv4Address(value) { return [value] }
        var hints = addrinfo(ai_flags: AI_DEFAULT, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(value, nil, &hints, &result) == 0 else { return [] }
        defer { freeaddrinfo(result) }
        var out: [String] = []; var p = result
        while let q = p { var host = [CChar](repeating: 0, count: Int(NI_MAXHOST)); getnameinfo(q.pointee.ai_addr, q.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST); out.append(String(cString: host)); p = q.pointee.ai_next }
        return Array(Set(out))
    }

    private func isIPv4Address(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard !part.isEmpty, let number = Int(part) else { return false }
            return number >= 0 && number <= 255
        }
    }

    private func resolveAll(_ addresses: [String], timeout: TimeInterval = 2.0) -> [String] {
        let normalized = Array(Set(addresses.map(normalize).filter { !$0.isEmpty }))
        var resolved = Set(normalized.filter(isIPv4Address))
        let domains = normalized.filter { !isIPv4Address($0) }
        guard !domains.isEmpty else { return resolved.sorted() }

        let group = DispatchGroup()
        let lock = NSLock()
        for domain in domains {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                defer { group.leave() }
                guard let self else { return }
                let values = self.resolve(domain)
                lock.lock()
                resolved.formUnion(values)
                lock.unlock()
            }
        }
        // DNS 异常不能无限阻塞启用操作；已配置的纯 IP 不会进入等待。
        _ = group.wait(timeout: .now() + timeout)
        lock.lock()
        let result = resolved.sorted()
        lock.unlock()
        return result
    }

    private func immediatelyAvailableIPs(_ addresses: [String]) -> (ips: [String], unresolvedDomains: [String]) {
        let normalized = Array(Set(addresses.map(normalize).filter { !$0.isEmpty }))
        var ips = Set(normalized.filter(isIPv4Address))
        var unresolved: [String] = []
        dnsCacheLock.lock()
        for domain in normalized where !isIPv4Address(domain) {
            if let cached = dnsCache[domain], !cached.isEmpty {
                ips.formUnion(cached)
            } else {
                unresolved.append(domain)
            }
        }
        dnsCacheLock.unlock()
        return (ips.sorted(), unresolved)
    }

    private func refreshConfiguredDomainsInBackground() {
        let domains = Array(Set(cleanedDomains().map(normalize).filter { !$0.isEmpty && !isIPv4Address($0) }))
        guard !domains.isEmpty else { return }
        for domain in domains {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let ips = self.resolve(domain)
                guard !ips.isEmpty else { return }
                self.dnsCacheLock.lock()
                self.dnsCache[domain] = ips
                let cache = self.dnsCache
                self.dnsCacheLock.unlock()
                UserDefaults.standard.set(cache, forKey: self.dnsCacheKey)
                self.scheduleNetworkRefresh()
            }
        }
    }

    private func resolveAndAppendRoutes(_ domains: [String], topology: NetworkTopology) {
        guard !domains.isEmpty else { return }
        let session = routingSession
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let resolved = self.resolveAll(domains, timeout: 4.0)
            guard !resolved.isEmpty, self.routesEnabled,
                  self.cachedTopologySnapshot()?.signature == topology.signature else { return }
            self.dnsCacheLock.lock()
            for domain in domains {
                let values = self.resolve(domain)
                if !values.isEmpty { self.dnsCache[domain] = values }
            }
            let cache = self.dnsCache
            self.dnsCacheLock.unlock()
            UserDefaults.standard.set(cache, forKey: self.dnsCacheKey)

            let existing = Set(self.appliedRouteIPs())
            let additions = resolved.filter { !existing.contains($0) }
            guard !additions.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.routesEnabled, !self.disableInProgress, !self.enableInProgress, !self.networkSwitchInProgress,
                      self.routingSession == session,
                      self.cachedTopologySnapshot()?.signature == topology.signature else { return }
                self.enableInProgress = true
                self.toggleItem?.isEnabled = false
                self.pendingEnableIPs = Array(existing.union(additions)).sorted()
                self.pendingEnableSignature = topology.signature
                self.runPrivileged(additions.map { "/sbin/route -n add -host \($0) \(topology.secondary.router) 2>/dev/null || /sbin/route -n change -host \($0) \(topology.secondary.router)" }, message: "已启用：\(existing.count + additions.count) 个 IP 走 \(topology.secondary.name)（\(topology.secondary.interface)）。")
            }
        }
    }

    private func appliedRouteIPs() -> [String] {
        UserDefaults.standard.stringArray(forKey: appliedRoutesKey) ?? []
    }

    private func rememberAppliedRoutes(_ ips: [String]) {
        UserDefaults.standard.set(Array(Set(ips)).sorted(), forKey: appliedRoutesKey)
    }

    private func replaceRoutes(oldIPs: [String], newIPs: [String], topology: NetworkTopology) {
        let deletes = oldIPs.map { "route -n delete -host \($0)" }
        let additions = newIPs.map { "route -n add -host \($0) \(topology.secondary.router)" }
        requestHelper { proxy, reply in proxy.replaceRoutes(deletes, with: additions, withReply: reply) } completion: { [weak self] success, output in
            DispatchQueue.main.async {
                guard let self else { return }
                self.networkReconfigurationInProgress = false
                if success {
                    self.rememberAppliedRoutes(newIPs)
                    UserDefaults.standard.set(topology.signature, forKey: self.appliedNetworkSignatureKey)
                    self.statusLabel?.stringValue = "网络已切换：\(newIPs.count) 个 IP 现走 \(topology.secondary.name)（\(topology.secondary.interface)）。"
                } else {
                    self.finishAutomaticDisable(message: "网络变化后重设路由失败，分流已关闭：\(output)")
                }
                self.finishAddressChangeCleanupIfReady()
                if self.networkRefreshRequested {
                    self.networkRefreshRequested = false
                    self.scheduleNetworkRefresh()
                }
            }
        }
    }

    private func runPrivileged(_ commands: [String], message: String, notifyOnDisable: Bool = true, notifyOnEnable: Bool = false) {
        let isDelete = commands.first?.contains(" delete ") == true
        let routes = commands.map { command in
            command.replacingOccurrences(of: "/sbin/route", with: "route")
                .components(separatedBy: " 2>/dev/null || ").first ?? command
        }
        let reply: (Bool, String) -> Void = { [weak self] success, output in
            DispatchQueue.main.async {
                self?.statusLabel?.stringValue = success ? message : "操作失败：\(output)"
                if success {
                    let wasEnabled = self?.routesEnabled == true
                    self?.routesEnabled = !isDelete
                    if isDelete {
                        UserDefaults.standard.removeObject(forKey: self?.appliedRoutesKey ?? "appliedRouteIPs")
                        UserDefaults.standard.removeObject(forKey: self?.appliedNetworkSignatureKey ?? "appliedNetworkSignature")
                        self?.networkReconfigurationInProgress = false
                    } else if let signature = self?.pendingEnableSignature {
                        self?.rememberAppliedRoutes(self?.pendingEnableIPs ?? [])
                        UserDefaults.standard.set(signature, forKey: self?.appliedNetworkSignatureKey ?? "appliedNetworkSignature")
                    }
                    UserDefaults.standard.set(self?.routesEnabled ?? false, forKey: "routesEnabled")
                    self?.toggleItem?.title = self?.routesEnabled == true ? "关闭网络分流" : "启用网络分流"
                    self?.updateStatusIcon()
                    if self?.routesEnabled == false && self?.pendingUninstall == true {
                        self?.pendingUninstall = false
                        self?.performUninstall()
                    }
                    if isDelete, wasEnabled, notifyOnDisable {
                        self?.notifyDisabled(reason: message)
                    } else if !isDelete, notifyOnEnable, self?.addressChangeCleanupPending != true {
                        self?.notifyEnabled(networkName: self?.cachedTopologySnapshot()?.secondary.name ?? "分流网络")
                    }
                    if isDelete && self?.pendingQuit == true {
                        self?.pendingQuit = false
                        NSApp.terminate(nil)
                    }
                } else if isDelete {
                    self?.pendingQuit = false
                    self?.pendingUninstall = false
                } else {
                    self?.finishAutomaticDisable(message: "启用失败：\(output)", notifyOnDisable: false)
                    UserDefaults.standard.removeObject(forKey: self?.appliedRoutesKey ?? "appliedRouteIPs")
                    UserDefaults.standard.removeObject(forKey: self?.appliedNetworkSignatureKey ?? "appliedNetworkSignature")
                }
                self?.pendingEnableSignature = nil
                self?.pendingEnableIPs = []
                self?.enableInProgress = false
                self?.disableInProgress = false
                self?.toggleItem?.isEnabled = true
                if isDelete {
                    self?.pendingBackgroundDomains = []
                    self?.pendingBackgroundTopology = nil
                }
                if success, !isDelete, let topology = self?.pendingBackgroundTopology {
                    let domains = self?.pendingBackgroundDomains ?? []
                    self?.pendingBackgroundDomains = []
                    self?.pendingBackgroundTopology = nil
                    self?.resolveAndAppendRoutes(domains, topology: topology)
                } else if !success {
                    self?.pendingBackgroundDomains = []
                    self?.pendingBackgroundTopology = nil
                }
                if isDelete, self?.networkSwitchInProgress == true {
                    if success { self?.applyPendingNetworkOrder() }
                    else { self?.finishNetworkSwitch(error: output) }
                }
                self?.finishAddressChangeCleanupIfReady()
            }
        }
        requestHelper { proxy, completion in
            if isDelete { proxy.deleteRoutes(routes, withReply: completion) }
            else { proxy.addRoutes(routes, withReply: completion) }
        } completion: { success, output in reply(success, output) }
    }

    @objc private func installHelper() {
        guard !helperInstallationInProgress else { return }
        autoEnablePausedForSession = true
        if routesEnabled || enableInProgress || disableInProgress || networkReconfigurationInProgress {
            guard !enableInProgress, !disableInProgress, !networkReconfigurationInProgress else {
                statusLabel?.stringValue = "请等待当前路由操作完成后再修复。"; return
            }
            requestHelper { proxy, reply in proxy.deleteRoutes([], withReply: reply) } completion: { [weak self] success, output in
                guard let self else { return }
                guard success else { self.statusLabel?.stringValue = "路由清理失败：\(output)"; return }
                self.finishAutomaticDisable(message: "分流已关闭，准备修复辅助服务。", notifyOnDisable: false)
                UserDefaults.standard.removeObject(forKey: self.appliedRoutesKey)
                self.installHelper()
            }
            return
        }
        helperInstallationInProgress = true
        helperReady = false
        helperStatus = "正在安装或修复辅助服务…"
        helperConnection?.invalidationHandler = nil
        helperConnection?.interruptionHandler = nil
        helperConnection?.invalidate()
        helperConnection = nil
        updateHelperButton()
        let temporaryScript = "/tmp/workroutemenu-install-helper.sh"
        // 辅助程序随 App 一起分发，不能依赖开发机上的工程目录。
        // 安装包已经安装过辅助程序时，也允许从系统位置重新安装。
        let bundledHelper = Bundle.main.url(forResource: "com.cooper.WorkRouteMenu.helper", withExtension: nil)?.path
        let bundledPlist = Bundle.main.url(forResource: "com.cooper.WorkRouteMenu.helper", withExtension: "plist")?.path
        let helperSource = bundledHelper ?? "/Library/PrivilegedHelperTools/com.cooper.WorkRouteMenu.helper"
        let plistSource = bundledPlist ?? "/Library/LaunchDaemons/com.cooper.WorkRouteMenu.helper.plist"
        let temporaryHelper = "/tmp/com.cooper.WorkRouteMenu.helper"
        let temporaryPlist = "/tmp/com.cooper.WorkRouteMenu.helper.plist"
        let script = """
        #!/bin/bash
        set -e
        test -f '\(temporaryHelper)'
        test -f '\(temporaryPlist)'
        launchctl bootout system/com.cooper.WorkRouteMenu.helper 2>/dev/null || true
        mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons
        cp '\(temporaryHelper)' /Library/PrivilegedHelperTools/com.cooper.WorkRouteMenu.helper
        chmod 755 /Library/PrivilegedHelperTools/com.cooper.WorkRouteMenu.helper
        chown root:wheel /Library/PrivilegedHelperTools/com.cooper.WorkRouteMenu.helper
        cp '\(temporaryPlist)' /Library/LaunchDaemons/com.cooper.WorkRouteMenu.helper.plist
        chmod 644 /Library/LaunchDaemons/com.cooper.WorkRouteMenu.helper.plist
        chown root:wheel /Library/LaunchDaemons/com.cooper.WorkRouteMenu.helper.plist
        launchctl enable system/com.cooper.WorkRouteMenu.helper
        launchctl bootstrap system /Library/LaunchDaemons/com.cooper.WorkRouteMenu.helper.plist
        launchctl print system/com.cooper.WorkRouteMenu.helper >/dev/null
        """
        do {
            try? FileManager.default.removeItem(atPath: temporaryHelper)
            try? FileManager.default.removeItem(atPath: temporaryPlist)
            try FileManager.default.copyItem(atPath: helperSource, toPath: temporaryHelper)
            try FileManager.default.copyItem(atPath: plistSource, toPath: temporaryPlist)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporaryHelper)
            try script.write(toFile: temporaryScript, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporaryScript)
        } catch {
            helperInstallationInProgress = false
            updateHelperButton()
            statusLabel?.stringValue = "无法准备安装程序：\(error.localizedDescription)"
            return
        }
        let appleScript = "do shell script \"/bin/bash /tmp/workroutemenu-install-helper.sh\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        do {
            try process.run()
            DispatchQueue.global().async {
                process.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    self.logServiceOrder("辅助程序安装 exit=\(process.terminationStatus) output=\(output)")
                    self.statusLabel?.stringValue = process.terminationStatus == 0 ? "辅助服务已安装并注册，可以重新设定服务顺序。" : "安装失败：\(output.trimmingCharacters(in: .whitespacesAndNewlines))"
                    self.helperInstallationInProgress = false
                    self.refreshHelperHealth()
                    try? FileManager.default.removeItem(atPath: temporaryScript)
                    try? FileManager.default.removeItem(atPath: temporaryHelper)
                    try? FileManager.default.removeItem(atPath: temporaryPlist)
                }
            }
        } catch {
            helperInstallationInProgress = false
            updateHelperButton()
            statusLabel?.stringValue = "无法启动安装：\(error.localizedDescription)"
        }
    }

    private func uninstallHelper() {
        if routesEnabled {
            pendingUninstall = true
            statusLabel?.stringValue = "正在关闭分流，随后卸载辅助服务…"
            disableRoutes(message: "已关闭网络分流。", notifyOnDisable: false)
            return
        }
        performUninstall()
    }

    private func performUninstall() {
        helperReady = false
        helperConnection?.invalidationHandler = nil
        helperConnection?.interruptionHandler = nil
        helperConnection?.invalidate()
        helperConnection = nil
        let script = """
        #!/bin/bash
        set -e
        launchctl bootout system/com.cooper.WorkRouteMenu.helper 2>/dev/null || true
        rm -f /Library/PrivilegedHelperTools/com.cooper.WorkRouteMenu.helper
        rm -f /Library/LaunchDaemons/com.cooper.WorkRouteMenu.helper.plist
        """
        let path = "/tmp/workroutemenu-uninstall-helper.sh"
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \"/bin/bash /tmp/workroutemenu-uninstall-helper.sh\" with administrator privileges"]
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            DispatchQueue.global().async {
                process.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    self.statusLabel?.stringValue = process.terminationStatus == 0 ? "辅助服务已卸载。" : "卸载失败：\(output.trimmingCharacters(in: .whitespacesAndNewlines))"
                    if process.terminationStatus == 0 { self.refreshHelperHealth() }
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
        } catch { statusLabel?.stringValue = "无法启动卸载：\(error.localizedDescription)" }
    }

    private func showMissingAddressesAlert() {
        // 先退出菜单的跟踪循环，再将提示带到前台，避免菜单点击看起来无响应。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.showSettings()
            let alert = NSAlert()
            alert.messageText = "请先添加分流地址"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "知道了")
            if let window = self.window {
                alert.beginSheetModal(for: window)
            }
        }
    }

    @objc private func toggleRoutes() {
        guard !enableInProgress, !disableInProgress, !networkSwitchInProgress else { return }
        if !routesEnabled && cleanedDomains().isEmpty {
            showMissingAddressesAlert()
            return
        }
        if !helperReady {
            let alert = NSAlert()
            alert.messageText = helperInstalled() ? "需要修复或更新辅助程序" : "需要安装辅助程序"
            alert.informativeText = "启用网络分流需要安装一次系统辅助程序。安装过程中 macOS 会请求管理员密码。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: helperInstalled() ? "修复辅助程序" : "安装辅助程序")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                installHelper()
            }
            return
        }
        if routesEnabled { disableRoutes() } else { enableRoutes() }
    }

    @objc private func enableRoutes(automatically: Bool = false) {
        guard !enableInProgress, !disableInProgress, !routesEnabled, !pendingQuit, !pendingUninstall else { return }
        if automatically && (!UserDefaults.standard.bool(forKey: autoEnableKey) || autoEnablePausedForSession) { return }
        guard !addressChangeCleanupPending, !networkSwitchInProgress else { return }
        let domains = cleanedDomains()
        guard !domains.isEmpty else {
            if !automatically { showMissingAddressesAlert() }
            return
        }
        guard helperReady else { return }
        UserDefaults.standard.set(entries().map { "\($0.note) | \($0.address)" }.joined(separator: "\n"), forKey: defaultsKey)
        // 网络监听已经维护最新拓扑；点击启用时直接使用缓存，避免重复检查和等待 DNS。
        let topology = cachedTopologySnapshot() ?? currentTopology()
        guard let topology else {
            if automatically { return }
            let alert = NSAlert(); alert.messageText = "暂时无法启用网络分流"; alert.informativeText = "当前只检测到一个可用网络，请连接第二个网络后再启用分流。"; alert.alertStyle = .warning; alert.addButton(withTitle: "知道了"); alert.runModal(); return
        }
        storeCachedTopology(topology)
        let available = immediatelyAvailableIPs(domains)
        guard !available.ips.isEmpty else {
            statusLabel?.stringValue = "网站地址正在后台解析，请稍后再试。"
            refreshConfiguredDomainsInBackground()
            return
        }
        if !automatically { autoEnablePausedForSession = false }
        routingSession = UUID()
        enableInProgress = true
        toggleItem?.isEnabled = false
        pendingEnableIPs = available.ips
        pendingEnableSignature = topology.signature
        pendingBackgroundDomains = available.unresolvedDomains
        pendingBackgroundTopology = available.unresolvedDomains.isEmpty ? nil : topology
        let message = available.unresolvedDomains.isEmpty
            ? "已启用：\(available.ips.count) 个 IP 走 \(topology.secondary.name)（\(topology.secondary.interface)）。"
            : "已启用：\(available.ips.count) 个 IP 已生效，网站地址将在后台补充。"
        runPrivileged(available.ips.map { "/sbin/route -n add -host \($0) \(topology.secondary.router) 2>/dev/null || /sbin/route -n change -host \($0) \(topology.secondary.router)" }, message: message, notifyOnEnable: automatically)
    }

    @objc private func disableRoutes() { disableRoutes(message: "已关闭网络分流。", notifyOnDisable: false) }

    private func disableRoutes(message: String, notifyOnDisable: Bool = true) {
        guard !disableInProgress else { return }
        routingSession = UUID()
        pendingBackgroundDomains = []
        pendingBackgroundTopology = nil
        let ips = appliedRouteIPs()
        guard !ips.isEmpty else {
            finishAutomaticDisable(message: message, notifyOnDisable: notifyOnDisable)
            if pendingUninstall {
                pendingUninstall = false
                performUninstall()
            }
            return
        }
        disableInProgress = true
        toggleItem?.isEnabled = false
        runPrivileged(ips.map { "/sbin/route -n delete -host \($0) 2>/dev/null || true" }, message: message, notifyOnDisable: notifyOnDisable)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !updateTerminationPending else { return .terminateLater }
        guard !networkSwitchInProgress, !enableInProgress, !disableInProgress, !networkReconfigurationInProgress else {
            statusLabel?.stringValue = "当前操作尚未完成，请稍后退出或安装更新。"
            return .terminateCancel
        }
        guard routesEnabled || !appliedRouteIPs().isEmpty else { return .terminateNow }
        updateTerminationPending = true
        autoEnablePausedForSession = true
        requestHelper { proxy, reply in proxy.deleteRoutes([], withReply: reply) } completion: { [weak self] success, output in
            guard let self else { sender.reply(toApplicationShouldTerminate: false); return }
            self.updateTerminationPending = false
            if success {
                UserDefaults.standard.removeObject(forKey: self.appliedRoutesKey)
                self.finishAutomaticDisable(message: "分流已关闭，准备退出或安装更新。", notifyOnDisable: false)
            } else {
                self.statusLabel?.stringValue = "无法确认路由清理完成，已取消退出：\(output)"
            }
            sender.reply(toApplicationShouldTerminate: success)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopNetworkMonitoring()
        helperConnection?.invalidate()
    }

    @objc private func quit() {
        guard !networkSwitchInProgress else {
            statusLabel?.stringValue = "正在切换系统网络，请完成后再退出。"
            return
        }
        guard !pendingQuit else { return }
        if routesEnabled || !appliedRouteIPs().isEmpty {
            pendingQuit = true
            disableRoutes(message: "已关闭网络分流，正在退出。", notifyOnDisable: false)
        } else {
            NSApp.terminate(nil)
        }
    }

}

@main
struct WorkRouteMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
