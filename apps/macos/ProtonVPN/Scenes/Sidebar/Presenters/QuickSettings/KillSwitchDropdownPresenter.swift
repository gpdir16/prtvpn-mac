//
//  KillSwitchDropdownPresenter.swift
//  ProtonVPN - Created on 04/11/2020.
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
import Foundation
import LegacyCommon
import Sharing
import Strings
import Theme
import VPNAppCore

class KillSwitchDropdownPresenter: QuickSettingDropdownPresenter {
    @Dependency(\.appFeaturePropertyProvider) var featurePropertyProvider

    typealias Factory = AppStateManagerFactory & CoreAlertServiceFactory & VpnGatewayFactory

    private let factory: Factory

    @Dependency(\.propertiesManager) private var propertiesManager

    override var learnLink: String {
        VPNLink.killSwitchSupport.urlString
    }

    override var title: String {
        Localizable.killSwitch
    }

    init(_ factory: Factory) {
        self.factory = factory
        super.init(factory.makeVpnGateway(), appStateManager: factory.makeAppStateManager(), alertService: factory.makeCoreAlertService())
    }

    override var options: [QuickSettingDropdownOptionPresenter] {
        [option(.auto), option(.on), option(.lockdown), option(.off)]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        viewController?.dropdownDescription.attributedStringValue = Localizable.quickSettingsKillSwitchDescription.styled(font: .themeFont(.small), alignment: .left)
        viewController?.dropdownNote.attributedStringValue = Localizable.quickSettingsKillSwitchNote.styled(.weak, font: .themeFont(.small), alignment: .left)
        viewController?.dropdownUpgradeButton.isHidden = true

        if VPNFeatureFlagType.portForwarding.enabled {
            // (width - traling - leading) / number of buttons
            let oneButtonWidth = (UIConstants.Windows.sidebarWidth - 18 - 18) / 4
            viewController?.arrowHorizontalConstraint.constant = oneButtonWidth / 2
        } else {
            // (width - trailing - leading) / number of buttons
            let oneButtonWidth = (UIConstants.Windows.sidebarWidth - 18 - 18) / 3
            viewController?.arrowHorizontalConstraint.constant = oneButtonWidth
        }
    }

    // MARK: - Private

    // 방화벽은 터널과 독립적이라 모드를 바꿔도 재연결이 필요 없고, LAN 허용 여부는 데몬이 설정을 그대로 따르므로 충돌 경고도 없음.
    private func option(_ mode: FirewallMode) -> QuickSettingGenericOption {
        let title: String
        let detail: String
        switch mode {
        case .auto: (title, detail) = (Localizable.firewallModeAuto, Localizable.firewallModeAutoDescription)
        case .on: (title, detail) = (Localizable.firewallModeOn, Localizable.firewallModeOnDescription)
        case .lockdown: (title, detail) = (Localizable.firewallModeLockdown, Localizable.firewallModeLockdownDescription)
        case .off: (title, detail) = (Localizable.firewallModeOff, Localizable.firewallModeOffDescription)
        }
        let icon = mode == .off ? AppTheme.Icon.switchOff : AppTheme.Icon.switchOn
        return QuickSettingGenericOption(title, icon: icon, active: DaemonFirewall.mode == mode, detail: detail, selectCallback: { dismissCallback in
            // 예기치 않게 끊겨 자동 전환이 막고 있는 상태에서 벗어날 방법이 필요함:
            // 연결이 끊긴 채로 사용자가 모드를 직접 고르면 의도적으로 끊은 것으로 봄.
            if self.appStateManager.state.isDisconnected {
                DaemonFirewall.userWillDisconnect()
            }
            DaemonFirewall.mode = mode
            dismissCallback()
        })
    }
}
