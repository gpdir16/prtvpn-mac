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

import Announcement
import Modals
import Strings
import SwiftUI
import Theme

/// 국가, 게이트웨이 목록. 상태는 전부 `LocationListModel` 하나에 있고, 행은 값만 받아 그림.
public struct LocationListView<Top: View>: View {
    @Bindable var model: LocationListModel
    /// 목록 맨 위(국가들 위)에 함께 스크롤되는 구역. 검색 중에는 숨김.
    private let top: () -> Top

    public init(model: LocationListModel, @ViewBuilder top: @escaping () -> Top) {
        self.model = model
        self.top = top
    }

    public var body: some View {
        Group {
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .task { model.start() }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !model.isSearching {
                    top()
                }
                if !model.gateways.isEmpty {
                    header(Localizable.locationsGateways) { model.displayGatewaysServices?() }
                    rows(model.gateways)
                }
                if model.isFreeTier {
                    header(Localizable.connectionsFreeWithCount(1)) { model.displayFreeConnectionsInfo?() }
                    fastestRow
                }
                header(Localizable.locationsAll(model.countries.count), accessory: { sortMenu }) {
                    model.displayPremiumServices?()
                }
                if model.isFreeTier {
                    banner
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)
                }
                rows(model.countries)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - 행

    @ViewBuilder
    private func rows(_ rows: [LocationRow]) -> some View {
        ForEach(rows) { row in
            let isExpanded = model.expandedID == row.id
            LocationRowView(
                row: row,
                isExpanded: isExpanded,
                isFreeTier: model.isFreeTier,
                onConnect: { model.connect(to: row.id) },
                onAccessory: { model.toggleExpansion(of: row.id) }
            )
            .equatable()
            if isExpanded {
                ForEach(model.children) { child in
                    childRow(child)
                }
            }
        }
    }

    @ViewBuilder
    private func childRow(_ child: LocationRow) -> some View {
        let view = LocationRowView(
            row: child,
            isExpanded: false,
            isFreeTier: model.isFreeTier,
            onConnect: { model.connect(to: child.id) },
            onAccessory: child.hasServerList ? { model.showServers(of: child.id) } : nil
        )
        .equatable()

        if child.hasServerList {
            // 펼친 국가의 도시 몇 개에만 붙으므로 팝오버를 행마다 달아도 부담이 없음
            view.popover(
                isPresented: Binding(
                    get: { model.serverListRowID == child.id },
                    set: { if !$0, model.serverListRowID == child.id { model.serverListRowID = nil } }
                ),
                arrowEdge: .trailing
            ) {
                ServerListPopover(model: model)
            }
        } else {
            view
        }
    }

    private var fastestRow: some View {
        Button {
            model.connectToFastest()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12))
                    .frame(width: 24)
                Text(Localizable.fastest)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: LocationRowView.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 머리글, 배너

    private func header(_ title: String, info: @escaping () -> Void) -> some View {
        header(title, accessory: { EmptyView() }, info: info)
    }

    private var sortMenu: some View {
        Menu {
            Picker(Localizable.locationsSortTitle, selection: $model.sort) {
                Text(Localizable.locationsSortAlphabetical).tag(LocationSort.alphabetical)
                Text(Localizable.locationsSortNearest).tag(LocationSort.nearest)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Localizable.locationsSortTitle)
        .accessibilityLabel(Localizable.locationsSortTitle)
    }

    private func header(
        _ title: String,
        @ViewBuilder accessory: () -> some View,
        info: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 0)
            accessory()
            Button(action: info) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Color(.text, .hint))
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var banner: some View {
        if let offer = model.offerBanner {
            OfferBannerView(viewModel: offer, onDismiss: { model.reloadOfferBanner() })
        } else {
            switch model.serverChangeAvailability {
            case .available:
                UpsellBannerView(viewModel: .init(
                    leftIcon: Modals.Asset.worldwideCoverage,
                    text: Localizable.freeBannerText
                ) {
                    model.displayUpsellModal?()
                })
            case .unavailable:
                UpsellBannerView(viewModel: .init(
                    leftIcon: Modals.Asset.wrongCountry,
                    text: Localizable.wrongCountryBannerText
                ) {
                    model.displayUpsellModal?()
                })
            }
        }
    }
}

// MARK: - 서버 목록 팝오버

private struct ServerListPopover: View {
    let model: LocationListModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.serverListTitle)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.top, 14)
            HStack {
                Text(Localizable.searchServers)
                Spacer(minLength: 0)
                Text(Localizable.connectionDetailsServerLoad)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 4)

            Divider()

            if let servers = model.serverList {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(servers) { server in
                            LocationRowView(
                                row: server,
                                isExpanded: false,
                                isFreeTier: model.isFreeTier,
                                onConnect: { model.connect(to: server.id) },
                                onAccessory: nil
                            )
                            .equatable()
                        }
                    }
                    .padding(8)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 300, height: 340)
    }
}
