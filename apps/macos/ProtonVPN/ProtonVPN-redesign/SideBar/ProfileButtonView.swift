//
//  Created on 15/05/2023.
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


import ProtonCoreUIFoundations
import SwiftUI
import Theme

/// 기능 바 버튼을 눌렀을 때 뜨는 선택 목록. 실제 동작은 기존 빠른 설정 프레젠터가 처리함.
struct QuickSettingPopover: View {
    let presenter: QuickSettingDropdownPresenter
    let detail: String
    let onChange: () -> Void

    /// 선택 후 옵션의 활성 상태를 다시 읽기 위한 값
    @State private var refreshToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: .themeSpacing8) {
            Text(presenter.title)
                .font(.headline)
                .padding(.horizontal, .themeSpacing8)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, .themeSpacing8)
            }
            Divider()
            ForEach(Array(presenter.options.enumerated()), id: \.offset) { _, option in
                optionRow(option)
            }
        }
        .padding(.themeSpacing12)
        .frame(width: 320)
        .id(refreshToken)
    }

    private func optionRow(_ option: QuickSettingDropdownOptionPresenter) -> some View {
        Button {
            option.selectCallback {
                DispatchQueue.main.async {
                    refreshToken += 1
                    onChange()
                }
            }
        } label: {
            HStack(alignment: .top, spacing: .themeSpacing8) {
                Image(nsImage: option.icon)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.system(size: 13))
                    if let detail = option.detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if option.active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(option.active ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
