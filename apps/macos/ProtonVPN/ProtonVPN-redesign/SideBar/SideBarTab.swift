//
//  Created on 07/05/2023.
//
//  Copyright (c) 2023 Proton AG
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


import AppKit
import Domain
import Strings
import Theme

/// 오른쪽 기능 바에 올라가는 빠른 설정 항목
enum QuickSettingWidget: CaseIterable, Identifiable {
    case netShield
    case killSwitch
    case portForwarding
    case secureCore

    var id: Self { self }

    var title: String {
        switch self {
        case .netShield: Localizable.netshieldTitle
        case .killSwitch: Localizable.killSwitch
        case .portForwarding: Localizable.portForwarding
        case .secureCore: Localizable.secureCore
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .netShield: "NetShieldWidget"
        case .killSwitch: "KillSwitchWidget"
        case .portForwarding: "PortForwardingWidget"
        case .secureCore: "SecureCoreWidget"
        }
    }

    /// 팝오버에서 제목 아래에 보여 주는 기능 설명
    var detail: String {
        switch self {
        case .netShield: Localizable.quickSettingsNetShieldDescription
        case .killSwitch: ""
        case .portForwarding: Localizable.quickSettingsPortForwardingDescription
        case .secureCore: Localizable.quickSettingsSecureCoreDescription
        }
    }

    /// 원래 앱에서 쓰던 아이콘. 켜짐/꺼짐(NetShield는 단계)에 따라 모양이 달라짐.
    func icon(isOn: Bool, netShieldLevel: NetShieldType = .off) -> NSImage {
        switch self {
        case .netShield: netShieldLevel.quickSettingsIcon
        case .killSwitch: isOn ? AppTheme.Icon.switchOn : AppTheme.Icon.switchOff
        case .portForwarding: isOn ? AppTheme.Icon.arrowsSwitch : AppTheme.Icon.arrowUpBounceLeft
        case .secureCore: isOn ? AppTheme.Icon.locks : AppTheme.Icon.lock
        }
    }
}
