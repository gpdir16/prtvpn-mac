//
//  Created on 04/05/2023.
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


import ComposableArchitecture
import Countries
import Dependencies
import Domain
import Home
import LegacyCommon
import SwiftUI
import Theme
import VPNAppCore

/// 메인 창의 루트 뷰. Windows 앱과 같은 구조로, 지도 위에 목록 패널과 기능 바가 떠 있음.
struct MainView: View {
    let homeStore: StoreOf<HomeFeature>
    let countriesViewModel: CountriesSectionViewModel
    let openSettings: () -> Void

    /// 프레젠터는 접근할 때마다 새로 만들어지므로 항목별로 하나씩 보관함
    private let presenters: [QuickSettingWidget: QuickSettingDropdownPresenter]

    @Dependency(\.propertiesManager) private var propertiesManager
    @Dependency(\.netShieldPropertyProvider) private var netShieldPropertyProvider
    @Dependency(\.portForwardingPropertyProvider) private var portForwardingPropertyProvider

    init(
        homeStore: StoreOf<HomeFeature>,
        countriesViewModel: CountriesSectionViewModel,
        openSettings: @escaping () -> Void
    ) {
        self.homeStore = homeStore
        self.countriesViewModel = countriesViewModel
        self.openSettings = openSettings
        self.presenters = [
            .netShield: countriesViewModel.netShieldPresenter,
            .killSwitch: countriesViewModel.killSwitchPresenter,
            .portForwarding: countriesViewModel.portForwardingPresenter,
            .secureCore: countriesViewModel.secureCorePresenter,
        ]
    }

    var body: some View {
        HomeDesktopView(
            store: homeStore,
            onSearch: { countriesViewModel.filterContent(forQuery: $0) },
            locations: {
                LocationListView(model: countriesViewModel.listModel) {
                    DesktopRecentsSection(store: homeStore.scope(state: \.recents, action: \.recents))
                }
            },
            widgets: {
                WidgetBarView(
                    widgets: widgets,
                    presenter: { presenters[$0]! },
                    isOn: isOn,
                    netShieldLevel: { netShieldPropertyProvider.getNetShieldType() },
                    openSettings: openSettings
                )
            }
        )
        .frame(minWidth: 860, minHeight: 600)
    }

    private var widgets: [QuickSettingWidget] {
        QuickSettingWidget.allCases.filter { widget in
            switch widget {
            case .netShield: countriesViewModel.isNetShieldEnabled
            case .portForwarding: VPNFeatureFlagType.portForwarding.enabled
            case .killSwitch, .secureCore: true
            }
        }
    }

    private func isOn(_ widget: QuickSettingWidget) -> Bool {
        switch widget {
        case .netShield: netShieldPropertyProvider.getNetShieldType() != .off
        case .killSwitch: DaemonFirewall.mode != .off
        case .portForwarding: portForwardingPropertyProvider.getPortForwarding() ?? false
        case .secureCore: propertiesManager.secureCoreToggle
        }
    }
}

extension MainView {
    /// 홈 화면 스토어를 만들고, 한 번만 보내야 하는 시작 액션들을 전달함
    static func makeHomeStore() -> StoreOf<HomeFeature> {
        // 빠른 연결은 항상 가장 최근에 연결한 곳으로 함 (기록이 없으면 가장 빠른 서버)
        @Shared(.defaultConnectionPreference) var defaultConnectionPreference
        $defaultConnectionPreference.withLock { $0 = .mostRecent }

        let store = StoreOf<HomeFeature>(initialState: .init()) {
            HomeFeature()
        }
        store.send(.onStart)
        store.send(.sharedProperties(.listen))
        store.send(.map(.observeConnectionState))
        // 최근 탭을 열지 않아도 연결 기록이 쌓이도록 처음부터 지켜봄
        store.send(.recents(.watchConnectionStatus))
        return store
    }
}
