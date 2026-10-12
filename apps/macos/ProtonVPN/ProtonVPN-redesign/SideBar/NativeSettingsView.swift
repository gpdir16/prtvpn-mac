//
//  Created on 2026-10-11.
//
//  Copyright (c) 2026 Proton AG
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

import Dependencies
import Domain
import Home
import LegacyCommon
import Localization
import Persistence
import Strings
import SwiftUI

/// 설정 창. 값의 저장과 재연결 확인 같은 동작은 기존 뷰 모델이 맡고, 화면만 시스템 양식(Form)으로 그림.
struct NativeSettingsView: View {
    let general: GeneralSettingsViewModel
    let connection: ConnectionSettingsViewModel
    let advanced: AdvancedSettingsViewModel
    let account: AccountViewModel
    let clearRecents: () -> Void
    let signOut: () -> Void

    let tab: SettingsTab
    /// 뷰 모델은 관찰 대상이 아니므로, 값이 바뀌면 이 숫자를 올려 다시 읽음
    @State private var revision = 0

    @AppStorage(RecentsFeature.limitKey) private var recentsLimit = RecentsFeature.defaultLimit
    @Dependency(\.propertiesManager) private var propertiesManager
    @State private var virtualServerPolicy = VirtualServerPolicy.current

    private static let recentsLimits = [0, 3, 5, 10, 20]

    var body: some View {
        Group {
            switch tab {
            case .general: generalTab
            case .connection: connectionTab
            case .advanced: advancedTab
            case .account: accountTab
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            let reload = { DispatchQueue.main.async { revision += 1 } }
            connection.reloadNeeded = reload
            connection.protocolPendingChanged = { _ in reload() }
            advanced.reloadNeeded = reload
            account.reloadNeeded = reload
        }
    }

    // MARK: - 일반

    private var generalTab: some View {
        Form {
            Section(Localizable.settingsSectionStartup) {
                Toggle(Localizable.startOnBoot, isOn: binding({ general.startOnBoot }, general.setStartOnBoot))
                Toggle(Localizable.startMinimized, isOn: binding({ general.startMinimized }, general.setStartMinimized))
            }
            Section(Localizable.settingsSectionNotifications) {
                Toggle(Localizable.systemNotifications, isOn: binding({ general.systemNotifications }, general.setSystemNotifications))
                Toggle(isOn: binding({ general.unprotectedNetworkNotifications }, general.setUnprotectedNetworkNotifications)) {
                    Text(Localizable.unprotectedNetwork)
                    Text(Localizable.unprotectedNetworkTooltip)
                }
            }
            Section(Localizable.homeRecentsRecentSection) {
                Picker(Localizable.recentsLimit, selection: $recentsLimit) {
                    ForEach(Self.recentsLimits, id: \.self) { count in
                        Text(count == 0 ? Localizable.recentsLimitNone : "\(count)").tag(count)
                    }
                }
                LabeledContent(Localizable.recentsClear) {
                    Button(Localizable.recentsClear, role: .destructive, action: clearRecents)
                }
                .labelsHidden()
            }
        }
    }

    // MARK: - 연결

    private var connectionTab: some View {
        Form {
            Section {
                Toggle(isOn: binding({ connection.autoConnect?.enabled ?? false }) { enabled in
                    try? connection.setAutoConnect(enabled ? 1 : 0)
                }) {
                    Text(Localizable.autoConnect)
                    Text(Localizable.autoConnectTooltip)
                }
                Picker(selection: binding({ connection.selectedProtocol }) { newValue in
                    connection.setProtocol(newValue) { _ in
                        DispatchQueue.main.async { revision += 1 }
                    }
                }) {
                    ForEach(connection.availableConnectionProtocols, id: \.self) { item in
                        Text(item.localizedDescription).tag(item)
                    }
                } label: {
                    Text(Localizable.protocol)
                    Text(Localizable.smartProtocolDescription)
                }
                featureToggle(
                    Localizable.vpnAcceleratorTitle,
                    state: connection.displayState(for: VPNAccelerator.self)
                ) { connection.setVpnAccelerator($0, completion: $1) }
            }

            Section {
                Picker(selection: $virtualServerPolicy) {
                    Text(Localizable.virtualServersAny).tag(VirtualServerPolicy.any)
                    Text(Localizable.virtualServersFallback).tag(VirtualServerPolicy.fallback)
                    Text(Localizable.virtualServersNever).tag(VirtualServerPolicy.never)
                    Text(Localizable.virtualServersOnly).tag(VirtualServerPolicy.only)
                } label: {
                    Text(Localizable.virtualServersTitle)
                    Text(Localizable.virtualServersDescription)
                }
                .onChange(of: virtualServerPolicy) { _, newValue in
                    VirtualServerPolicy.current = newValue
                }
            }

            Section {
                featureToggle(
                    Localizable.allowLanTitle,
                    subtitle: Localizable.settingsFirewallAllowLanFooter,
                    state: connection.displayState(for: ExcludeLocalNetworks.self)
                ) { connection.setAllowLANAccess($0, completion: $1) }
            } header: {
                Text(Localizable.killSwitch)
            }

            if connection.shouldShowPFNotifications {
                Section(Localizable.portForwarding) {
                    featureToggle(
                        Localizable.settingsPortForwardingNotificationsTitle,
                        subtitle: Localizable.settingsPortForwardingNotificationsInfo,
                        state: connection.displayState(for: PortForwardingNotifications.self)
                    ) { connection.setPortForwardingNotifications($0, completion: $1) }
                }
            }
        }
    }

    // MARK: - 고급

    private var advancedTab: some View {
        Form {
            Section {
                Toggle(isOn: binding({ advanced.alternativeRouting }, advanced.setAlternatveRouting)) {
                    Text(Localizable.troubleshootItemAltTitle)
                }
                if advanced.isNATTypeFeatureEnabled {
                    featureToggle(
                        Localizable.moderateNatTitle,
                        subtitle: Localizable.moderateNatExplanation
                            .replacingOccurrences(of: Localizable.moderateNatExplanationLink, with: ""),
                        state: advanced.natDisplayState
                    ) { advanced.setNatType(natType: $0 ? .moderateNAT : .strictNAT, completion: $1) }
                }
                if advanced.isSafeModeFeatureEnabled {
                    Toggle(isOn: binding({ !advanced.safeMode }) { allowed in
                        advanced.setSafeMode(safeMode: !allowed) { _ in
                            DispatchQueue.main.async { revision += 1 }
                        }
                    }) {
                        Text(Localizable.nonStandardPortsTitle)
                        Text(
                            Localizable.nonStandardPortsExplanation
                                .replacingOccurrences(of: Localizable.nonStandardPortsExplanationLink, with: "")
                        )
                    }
                }
            }
        }
    }

    // MARK: - 계정

    private var accountTab: some View {
        let _ = revision
        return Form {
            Section {
                LabeledContent(Localizable.username, value: account.username)
                LabeledContent(Localizable.accountPlan, value: account.planTitle ?? Localizable.unavailable)
            }
            Section {
                Button(Localizable.manageSubscription) { account.manageSubscriptionAction() }
                Button(Localizable.settingsSignOut, role: .destructive, action: signOut)
            }
        }
    }

    // MARK: - 도우미

    private func binding<Value>(_ get: @escaping () -> Value, _ set: @escaping (Value) -> Void) -> Binding<Value> {
        let _ = revision
        return Binding(
            get: get,
            set: { newValue in
                set(newValue)
                revision += 1
            }
        )
    }

    /// 요금제에 따라 쓸 수 없는 기능은 끈 채로 비활성화해 보여 줌
    @ViewBuilder
    private func featureToggle(
        _ title: String,
        subtitle: String? = nil,
        state: PaidFeatureDisplayState,
        set: @escaping (Bool, @escaping (Bool) -> Void) -> Void
    ) -> some View {
        let label = Group {
            Text(title)
            if let subtitle {
                Text(subtitle)
            }
        }
        switch state {
        case let .available(enabled, interactive):
            Toggle(isOn: binding({ enabled }) { newValue in
                set(newValue) { _ in
                    DispatchQueue.main.async { revision += 1 }
                }
            }) { label }
                .disabled(!interactive)
        case .upsell:
            Toggle(isOn: .constant(false)) { label }
                .disabled(true)
        case .disabled:
            EmptyView()
        }
    }
}
