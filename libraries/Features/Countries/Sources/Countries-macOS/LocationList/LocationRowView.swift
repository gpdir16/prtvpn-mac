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

import SharedViews
import Strings
import SwiftUI
import Theme

/// 목록의 행 하나. 미리 계산된 `LocationRow` 값만 읽어 그리고, 값이 같으면 다시 그리지 않음.
struct LocationRowView: View, Equatable {
    static let height: CGFloat = 36

    let row: LocationRow
    let isExpanded: Bool
    let isFreeTier: Bool
    let onConnect: () -> Void
    /// 국가, 게이트웨이는 펼치기, 도시, 주는 서버 목록 열기. 없으면 보조 버튼을 그리지 않음.
    let onAccessory: (() -> Void)?

    @State private var isHovering = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.isExpanded == rhs.isExpanded && lhs.isFreeTier == rhs.isFreeTier
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onConnect) {
                HStack(spacing: 10) {
                    leading
                    titles
                    Spacer(minLength: 8)
                    trailing
                }
                .padding(.leading, row.depth == 0 ? 10 : 22)
                .padding(.trailing, onAccessory == nil ? 10 : 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)

            if let onAccessory {
                Button(action: onAccessory) {
                    Image(systemName: row.isExpandable ? "chevron.right" : "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(Color(.icon, isExpanded ? .normal : .weak))
                        .frame(width: 30)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.isExpandable ? "Expand \(row.title)" : "Servers in \(row.title)")
            }
        }
        .frame(height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
        )
        .onHover { isHovering = $0 }
    }

    // MARK: - 구성 요소

    @ViewBuilder
    private var leading: some View {
        switch row.leading {
        case let .flag(composition):
            FlagView(flag: composition, flagSize: .desktopRecentsSize)
                .frame(width: 24)
                .opacity(isDimmed ? 0.5 : 1)
        case .pin:
            Image(systemName: "mappin")
                .font(.system(size: 12))
                .foregroundStyle(Color(.icon, isDimmed ? .hint : .weak))
                .frame(width: 24)
        case .none:
            EmptyView()
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.title)
                .font(.system(size: 13))
                .foregroundStyle(Color(.text, isDimmed ? .hint : .normal))
                .lineLimit(1)
            if let subtitle = row.subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(.text, .weak))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if row.isUnderMaintenance {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 12))
                .foregroundStyle(Color(.icon, .weak))
        } else if isHovering, isFreeTier {
            Theme.Asset.vpnSubscriptionBadge.swiftUIImage
                .resizable()
                .scaledToFit()
                .frame(height: 16)
        } else if isHovering, case .features = row.trailing {
            Text(Localizable.connect)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(.text, .interactive))
        } else {
            switch row.trailing {
            case let .features(p2p, tor, smartRouting):
                if p2p || tor || smartRouting {
                    CityStateServerFeaturesView(hasP2P: p2p, hasTor: tor, hasSmartRouting: smartRouting, load: nil)
                        .scaleEffect(0.8, anchor: .trailing)
                        .foregroundStyle(Color(.icon, .hint))
                }
            case let .load(load):
                LoadView(load: load)
                    .font(.system(size: 12).monospacedDigit())
            }
        }
    }

    private var isDimmed: Bool {
        row.isUnderMaintenance || isFreeTier
    }

    private var help: String {
        if isFreeTier {
            return Localizable.upgradeToPlus
        }
        guard row.isUnderMaintenance else { return "" }
        return row.isExpandable ? Localizable.allServersInCountryUnderMaintenance : Localizable.serverUnderMaintenance
    }
}
