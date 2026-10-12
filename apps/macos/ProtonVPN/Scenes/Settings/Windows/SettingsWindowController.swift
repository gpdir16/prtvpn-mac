//
//  SettingsWindowController.swift
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

import Cocoa
import LegacyCommon
import Strings

/// 설정 창. macOS 관례대로 도구 막대에 탭 아이콘이 놓이고, 탭마다 창 크기가 내용에 맞춰짐.
final class SettingsWindowController: WindowController {
    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Unsupported initializer")
    }

    /// - Parameter panes: 탭 순서대로 (제목, SF Symbol 이름, 내용)
    required init(panes: [(title: String, symbol: String, viewController: NSViewController)], selectedIndex: Int) {
        let tabViewController = NSTabViewController()
        tabViewController.tabStyle = .toolbar
        for pane in panes {
            let item = NSTabViewItem(viewController: pane.viewController)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            pane.viewController.title = pane.title
            tabViewController.addTabViewItem(item)
        }
        tabViewController.selectedTabViewItemIndex = selectedIndex

        let window = NSWindow(contentViewController: tabViewController)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        monitorsKeyEvents = true
    }
}
