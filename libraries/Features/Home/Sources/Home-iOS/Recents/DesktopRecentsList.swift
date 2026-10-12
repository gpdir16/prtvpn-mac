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

#if os(macOS)

    import SwiftUI

    import ComposableArchitecture

    import Domain
    import HomeShared
    import Localization
    import SharedViews
    import Strings
    import Theme

    /// 사이드바 목록 맨 위에 들어가는 최근 연결 구역. 설정한 개수까지만 보여 주고, 비어 있으면 아무것도 그리지 않음.
    /// 행을 누르면 연결하고, 고정, 삭제는 우클릭 메뉴와 행 끝의 핀 버튼으로 함.
    public struct DesktopRecentsSection: View {
        let store: StoreOf<RecentsFeature>

        @AppStorage(RecentsFeature.limitKey) private var limit = RecentsFeature.defaultLimit

        public init(store: StoreOf<RecentsFeature>) {
            self.store = store
        }

        public var body: some View {
            let items = Array(store.recentConnectionList.prefix(max(0, limit)))
            if !items.isEmpty {
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Text(Localizable.homeRecentsRecentSection)
                            .font(.system(size: 11, weight: .semibold))
                        Spacer(minLength: 0)
                        Button {
                            store.send(.clear)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(Localizable.recentsClear)
                        .accessibilityLabel(Localizable.recentsClear)
                    }
                    .foregroundStyle(Color(.text, .hint))
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .padding(.top, 10)
                    .padding(.bottom, 2)

                    ForEach(items, id: \.self) { item in
                        DesktopRecentRow(item: item, send: { _ = store.send($0) })
                    }
                }
            }
        }
    }

    private struct DesktopRecentRow: View {
        let item: RecentConnection
        let send: (RecentsFeature.Action) -> Void

        @State private var isHovering = false

        var body: some View {
            HStack(spacing: 0) {
                Button {
                    send(.delegate(.connect(item.connection, isPinned: item.pinned)))
                } label: {
                    HStack(spacing: 10) {
                        FlagView(location: item.connection.location, flagSize: .desktopRecentsSize)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.connection.location.text(locale: .current))
                                .font(.system(size: 13))
                                .lineLimit(1)
                            if let subtext = item.connection.location.subtext(locale: .current) {
                                Text(subtext)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        if item.underMaintenance {
                            Image(systemName: "wrench.and.screwdriver")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else if isHovering {
                            Text(Localizable.connect)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.tint)
                        }
                    }
                    .padding(.leading, 10)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    send(item.pinned ? .unpin(item) : .pin(item))
                } label: {
                    Image(systemName: item.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                        .foregroundStyle(item.pinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .opacity(item.pinned || isHovering ? 1 : 0)
                        .frame(width: 30)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.pinned ? Localizable.actionHomeUnpin : Localizable.actionHomePin)
            }
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
            )
            .onHover { isHovering = $0 }
            .contextMenu {
                Button(Localizable.actionConnect) {
                    send(.delegate(.connect(item.connection, isPinned: item.pinned)))
                }
                Button(item.pinned ? Localizable.actionHomeUnpin : Localizable.actionHomePin) {
                    send(item.pinned ? .unpin(item) : .pin(item))
                }
                Divider()
                Button(Localizable.actionRemove, role: .destructive) {
                    send(.remove(item))
                }
            }
        }
    }

#endif
