//
//  StatusMenuWindowController.swift
//  ProtonVPN - Created on 27.06.19.
//
//  Copyright (c) 2019 Proton Technologies AG
//
//  This file is part of ProtonVPN.
//
//  ProtonVPN is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  ProtonVPN is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with ProtonVPN.  If not, see <https://www.gnu.org/licenses/>.
//

import AppKit
import Dependencies
import Domain
import LegacyCommon
import Strings
import Theme
import VPNAppCore

class StatusWindow: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}

// Responsible for the status icon itself and the window for the status bar app
final class StatusMenuWindowController: WindowController {
    private var windowModel: StatusMenuWindowModel?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusMenu = NSMenu()

    private let iconManager: StatusBarIconBlinker

    private var eventsMonitor: Any?

    var windowIsVisible: Bool {
        window?.isVisible == true
    }

    var lastOpenApplication: NSRunningApplication?

    weak var windowService: WindowService?

    override var contentViewController: NSViewController? {
        didSet {
            if let viewController = contentViewController {
                window = StatusWindow(contentViewController: viewController)
                setupWindow()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Not implemented")
    }

    override init(window: NSWindow?) {
        self.iconManager = StatusBarIconBlinker(statusItem: statusItem, statusIcon: .unknown)

        super.init(window: window)

        monitorsKeyEvents = true
    }

    deinit {
        eventsMonitor.map { NSEvent.removeMonitor($0) }
    }

    func update(with windowModel: StatusMenuWindowModel) {
        self.windowModel = windowModel

        setupIcon()

        self.windowModel?.contentChanged = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.setupIcon()
            }
        }

        // 메뉴 막대 아이콘은 작은 창을 띄우지 않고 메인 창을 앞으로 가져옴.
        // 버튼 액션으로 받아야 마우스뿐 아니라 손쉬운 사용(키보드, VoiceOver)으로 눌러도 동작함.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        // 오른쪽 클릭으로는 메뉴를 엶
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupIcon() {
        iconManager.setImage(windowModel?.statusIcon ?? .unknown)
        iconManager.isBlinking = windowModel?.isStatusIconBlinking ?? false
        NSApp.applicationIconImage = (windowModel?.appIcon ?? .active).image
    }

    @objc
    private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else {
            showMainWindow()
        }
    }

    /// 메뉴 막대 아이콘을 오른쪽 클릭했을 때의 메뉴
    private func showContextMenu() {
        guard let container = Container.sharedContainer as? DependencyContainer else { return }
        let isLoggedIn = container.makeAppSessionManager().sessionStatus == .established
        let state = container.makeAppStateManager().state
        let menu = NSMenu()

        if isLoggedIn {
            let status = NSMenuItem(
                title: state.isConnected ? Localizable.connectionStatusProtected : Localizable.connectionStatusUnprotected,
                action: nil,
                keyEquivalent: ""
            )
            status.isEnabled = false
            menu.addItem(status)
            menu.addItem(.separator())
        }

        menu.addItem(menuItem(Localizable.statusItemOpen, #selector(showMainWindow)))
        if isLoggedIn {
            if state.isDisconnected {
                menu.addItem(menuItem(Localizable.connect, #selector(connectFromMenu)))
            } else {
                menu.addItem(menuItem(Localizable.disconnect, #selector(disconnectFromMenu)))
            }
            menu.addItem(.separator())
            menu.addItem(menuItem(Localizable.statusItemSettings, #selector(openSettingsFromMenu)))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem(Localizable.statusItemQuit, #selector(quitFromMenu)))

        // 메뉴를 상시로 달아 두면 왼쪽 클릭에도 열리므로, 보여 주는 동안에만 달았다가 뗌
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc
    private func connectFromMenu() {
        (Container.sharedContainer as? VpnGatewayFactory)?.makeVpnGateway().quickConnect(trigger: .tray)
    }

    @objc
    private func disconnectFromMenu() {
        // 사용자가 직접 끊는 것이므로 자동 전환 방화벽이 풀리는 경로로 끊음
        Task {
            @Dependency(\.disconnectVPN) var disconnectVPN
            try? await disconnectVPN(.tray)
        }
    }

    @objc
    private func openSettingsFromMenu() {
        (Container.sharedContainer as? NavigationServiceFactory)?.makeNavigationService().openSettings(to: .general)
    }

    @objc
    private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    @objc
    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        (Container.sharedContainer as? NavigationServiceFactory)?.makeNavigationService().showApplication()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.button?.isHighlighted = false
        }
    }

    private func togglePopover() {
        if windowIsVisible {
            dismissPopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button, let frame = button.window?.frame else { return }

        button.isHighlighted = true
        showWindow(self, relativeTo: frame)
    }

    private func dismissPopover() {
        if windowIsVisible {
            close()
            statusItem.button?.isHighlighted = false
        }
    }

    private func showWindow(_ sender: Any?, relativeTo frame: CGRect) {
        super.showWindow(sender)

        guard let window else { return }

        let height: CGFloat = 436 // positions countries so that 3.5 rows are showing
        let width: CGFloat = 300
        var extensionFrame = CGRect(x: frame.minX, y: frame.minY - height, width: width, height: height)
        if let screenFrame = statusItem.button?.window?.screen?.visibleFrame, let buttonWidth = statusItem.button?.frame.width {
            let padding: CGFloat = 20
            if extensionFrame.maxX + padding > screenFrame.maxX {
                extensionFrame.origin.x -= (width - buttonWidth)
            }
        }
        window.setFrame(extensionFrame, display: true)
        window.makeKeyAndOrderFront(sender)
    }

    override func close() {
        window?.orderOut(nil)
    }

    private func setupWindow() {
        guard let window else {
            return
        }

        window.delegate = self
        window.acceptsMouseMovedEvents = true
        window.isOpaque = false
        window.backgroundColor = NSColor.clear
        window.hidesOnDeactivate = false
        window.hasShadow = true

        window.styleMask = .nonactivatingPanel
        window.level = .popUpMenu
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.appearance = NSAppearance(named: .darkAqua)
    }
}

extension StatusMenuWindowController {
    override func windowWillClose(_: Notification) {
        windowService?.windowWillClose(self)
        dismissPopover()
    }

    func windowDidResignKey(_: Notification) {
        dismissPopover()
    }
}

extension NSEvent {
    func isStatusItemClicked(event: NSEvent) -> NSStatusItem? {
        guard let window else { return nil }
        guard window.className.hasPrefix("NSStatusBar"), window.className.hasSuffix("Window") else { return nil }
        guard event.eventNumber != 1337 else { return nil } // Bartender app event (avoid Bartender events from being misinterpreted as clicks on our app icon)
        return window.value(forKey: "statusItem") as? NSStatusItem
    }
}

extension StatusIcon {
    var image: NSImage {
        var result: NSImage = switch self {
        case .connected: Theme.Asset.connected.image
        case .disconnected: Theme.Asset.disconnected.image
        case .connecting: Theme.Asset.idle.image
        case .unknown: Theme.Asset.emptyIcon.image
        }

        result = result
            .resize(newWidth: Self.size, newHeight: Self.size)
        result.isTemplate = true
        return result
    }
}

extension AppIcon {
    #if DEBUG // use Debug icon for staging builds
        static let appIconConnected = Theme.Asset.dynamicAppIconDebugConnected.image
        static let appIconDisconnected = Theme.Asset.dynamicAppIconDebugDisconnected.image
    #else
        static let appIconConnected = Theme.Asset.dynamicAppIconConnected.image
        static let appIconDisconnected = Theme.Asset.dynamicAppIconDisconnected.image
    #endif
    var image: NSImage {
        switch self {
        case .active:
            AppIcon.appIconConnected
        case .disconnected:
            AppIcon.appIconDisconnected
        }
    }
}

class StatusBarIconBlinker {
    private var statusItem: NSStatusItem
    private var statusIcon: StatusIcon

    private var emptyImage: NSImage = StatusIcon.unknown.image
    private var interval: TimeInterval = AppConstants.Time.statusIconBlink
    private var timer: Timer?

    public var isBlinking: Bool = false {
        didSet {
            if isBlinking, timer == nil {
                start()
                return
            }
            if !isBlinking, timer != nil {
                stop()
                return
            }
        }
    }

    public init(statusItem: NSStatusItem, statusIcon: StatusIcon) {
        self.statusItem = statusItem
        self.statusIcon = statusIcon
    }

    public func setImage(_ statusIcon: StatusIcon) {
        if statusIcon != self.statusIcon {
            self.statusIcon = statusIcon
            if statusItem.button?.image != emptyImage {
                statusItem.button?.image = statusIcon.image
            }
        }
    }

    private func start() {
        timer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(fireTimer), userInfo: nil, repeats: true)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        statusItem.button?.image = statusIcon.image
    }

    @objc
    func fireTimer() {
        if statusItem.button?.image == emptyImage {
            statusItem.button?.image = statusIcon.image
        } else {
            statusItem.button?.image = emptyImage
        }
    }
}
