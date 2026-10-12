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


import Domain
import Strings
import SwiftUI
import Theme

/// 도구 막대의 빠른 설정 버튼들 (NetShield, 방화벽, 포트 포워딩, Secure Core)과 설정 버튼
/// 창 도구 막대에 놓이는 빠른 설정 버튼들. 켜진 기능은 강조색으로 표시함.
struct WidgetBarView: View {
    let widgets: [QuickSettingWidget]
    let presenter: (QuickSettingWidget) -> QuickSettingDropdownPresenter
    let isOn: (QuickSettingWidget) -> Bool
    let netShieldLevel: () -> NetShieldType
    let openSettings: () -> Void

    @State private var presentedWidget: QuickSettingWidget?
    /// 설정이 바뀐 뒤 아이콘 상태를 다시 읽기 위한 값
    @State private var refreshToken = 0

    var body: some View {
        HStack(spacing: 2) {
            ForEach(widgets) { widget in
                widgetButton(widget)
            }
            Divider()
                .frame(height: 16)
                .padding(.horizontal, 4)
            actionButton(
                title: Localizable.settingsTab,
                icon: AppTheme.Icon.cogWheel,
                accessibilityIdentifier: "SettingsButton",
                action: openSettings
            )
        }
        .id(refreshToken)
        // 설정은 팝오버에서 고른 직후가 아니라 조금 뒤(확인 창, 서버 응답 후)에 저장되기도 하므로,
        // 저장소가 바뀔 때마다 아이콘 상태를 다시 읽음. 팝오버가 열려 있는 동안에는 닫히지 않도록 미룸.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            if presentedWidget == nil {
                refreshToken += 1
            }
        }
        .onChange(of: presentedWidget) { _, presented in
            if presented == nil {
                refreshToken += 1
            }
        }
    }

    private func widgetButton(_ widget: QuickSettingWidget) -> some View {
        let isOn = isOn(widget)
        return Button {
            presentedWidget = widget
        } label: {
            Image(nsImage: widget.icon(isOn: isOn, netShieldLevel: netShieldLevel()))
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .frame(width: 28, height: 22)
        }
        .help(widget.title)
        .accessibilityLabel(widget.title)
        .accessibilityIdentifier(widget.accessibilityIdentifier)
        .popover(
            isPresented: Binding(
                get: { presentedWidget == widget },
                set: { if !$0, presentedWidget == widget { presentedWidget = nil } }
            ),
            arrowEdge: .bottom
        ) {
            QuickSettingPopover(presenter: presenter(widget), detail: widget.detail) {
                refreshToken += 1
            }
        }
    }

    private func actionButton(
        title: String,
        icon: NSImage,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(nsImage: icon)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .frame(width: 28, height: 22)
        }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
