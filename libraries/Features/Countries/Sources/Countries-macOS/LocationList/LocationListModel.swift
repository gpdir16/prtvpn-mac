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
import Combine
import ConnectionInventory
import CountriesShared
import Dependencies
import Domain
import Foundation
import LegacyCommon
import Localization
import Observation
import Persistence
import Sharing
import Strings
import Theme
import VPNAppCore

/// 화면에 그릴 행 하나. 제목, 국기, 아이콘 여부를 미리 계산해 두어, 행 뷰는 값만 읽어 그림.
/// (행을 그릴 때마다 지역화 문자열을 만들거나 저장소를 읽으면 스크롤이 끊김.)
public struct LocationRow: Identifiable, Equatable {
    public enum Leading: Equatable {
        case flag(FlagComposition)
        case pin
        case none
    }

    public enum Trailing: Equatable {
        /// P2P / Tor / 스마트 라우팅 아이콘
        case features(p2p: Bool, tor: Bool, smartRouting: Bool)
        /// 서버 부하 (%)
        case load(Int)
    }

    public let id: String
    public let title: String
    public let subtitle: String?
    public let leading: Leading
    public let trailing: Trailing
    public let isUnderMaintenance: Bool
    /// 0 = 국가, 게이트웨이, 1 = 그 아래 도시, 주, 서버
    public let depth: Int
    /// 펼쳐서 하위 항목을 볼 수 있는 행인지 (국가, 게이트웨이)
    public let isExpandable: Bool
    /// 서버 목록 팝오버를 열 수 있는 행인지 (도시, 주)
    public let hasServerList: Bool
}

/// 국가 목록 정렬 방식
public enum LocationSort: String, CaseIterable, Identifiable, Sendable {
    /// 이름순
    case alphabetical
    /// 현재 위치에서 가까운 순
    case nearest

    public var id: Self { self }

    static let defaultsKey = "LocationListSort"
}

@MainActor
@Observable
public final class LocationListModel {
    // MARK: - 화면 상태

    public private(set) var gateways: [LocationRow] = []
    public private(set) var countries: [LocationRow] = []
    /// 펼친 국가, 게이트웨이의 하위 행. 펼칠 때만 읽음.
    public private(set) var children: [LocationRow] = []
    public private(set) var expandedID: String?
    public private(set) var isLoading = true
    public private(set) var isFreeTier = false
    public private(set) var offerBanner: OfferBannerViewModel?
    /// 검색어가 있는 동안에는 최근 목록 같은 부가 구역을 숨김
    public private(set) var isSearching = false

    public var sort: LocationSort = LocationSort(
        rawValue: UserDefaults.standard.string(forKey: LocationSort.defaultsKey) ?? ""
    ) ?? .alphabetical {
        didSet {
            guard sort != oldValue else { return }
            UserDefaults.standard.set(sort.rawValue, forKey: LocationSort.defaultsKey)
            reload()
        }
    }

    /// 서버 목록 팝오버가 열려 있는 행과 그 내용
    public var serverListRowID: String?
    public private(set) var serverListTitle = ""
    public private(set) var serverList: [LocationRow]?

    // MARK: - 바깥으로 넘기는 동작

    @ObservationIgnored public var displayPremiumServices: (() -> Void)?
    @ObservationIgnored public var displayGatewaysServices: (() -> Void)?
    @ObservationIgnored public var displayUpsellModal: (() -> Void)?
    @ObservationIgnored public var displayFreeConnectionsInfo: (() -> Void)?

    // MARK: - 내부

    private enum Target {
        case group(ServerGroupInfo, secureCore: Bool)
        case server(ServerInfo, parentName: String)
    }

    @ObservationIgnored private var targets: [String: Target] = [:]
    @ObservationIgnored private var searchText = ""
    @ObservationIgnored private var secureCore = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var policyObservation: Task<Void, Never>?

    @ObservationIgnored @Dependency(\.serverRepository) private var repository
    @ObservationIgnored @Dependency(\.connectToVPN) private var connectToVPN
    @ObservationIgnored @Dependency(\.defaultConnectionStorage) private var defaultConnectionStorage
    @ObservationIgnored @Dependency(\.announcementManager) private var announcementManager
    @ObservationIgnored @Dependency(\.serverChangeAuthorizer) private var serverChangeAuthorizer
    @ObservationIgnored @Dependency(\.propertiesManager) private var propertiesManager

    public init() {}

    /// Secure Core 스위치와 요금제 변화를 지켜보며 목록을 불러옴. 한 번만 부르면 됨.
    public func start() {
        guard observation == nil else { return }
        // 가상 서버 설정이 바뀌면 목록에 보이는 위치도 달라짐
        policyObservation = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: VirtualServerPolicy.didChangeNotification).map({ _ in () }) {
                self?.reload()
            }
        }
        // 두 값을 한 흐름으로 합쳐 메인 액터에서 그대로 받음
        observation = Task { [weak self] in
            @SharedReader(.secureCoreToggle) var secureCoreToggle: Bool
            @SharedReader(.userTier) var userTier: Int?
            let changes = $secureCoreToggle.publisher.removeDuplicates().map { _ in () }
                .merge(with: $userTier.publisher.removeDuplicates().dropFirst().map { _ in () })
            for await _ in changes.values {
                self?.reload()
            }
        }
    }

    public var serverChangeAvailability: ServerChangeAuthorizer.ServerChangeAvailability {
        serverChangeAuthorizer.serverChangeAvailability()
    }

    // MARK: - 불러오기

    public func search(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        isSearching = !text.isEmpty
        reload(debounce: true)
    }

    public func reload(debounce: Bool = false) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self, !Task.isCancelled else { return }
            await load()
        }
    }

    public func reloadOfferBanner() {
        offerBanner = announcementManager.offerBannerViewModel { [announcementManager] announcement in
            announcementManager.markAsRead(notificationID: announcement.notificationID)
        }
    }

    private func load() async {
        @SharedReader(.secureCoreToggle) var secureCoreToggle: Bool
        @SharedReader(.userTier) var userTier: Int?
        let secureCore = secureCoreToggle
        let search = searchText
        let repository = repository
        let sort = sort
        // 좌표를 알 수 없으므로 사용자가 있는 국가의 서버 위치를 기준점으로 삼음
        let userCountry = propertiesManager.userLocation?.country ?? Locale.current.region?.identifier

        // 데이터베이스 질의와 정렬은 메인 스레드 밖에서 함
        let (countryGroups, gatewayGroups) = await Task.detached(priority: .userInitiated) {
            let countries = Self.groups(.country, search: search, secureCore: secureCore, repository: repository)
            return (
                Self.sorted(countries, by: sort, userCountry: userCountry, repository: repository),
                Self.groups(.gateway, search: search, secureCore: secureCore, repository: repository)
            )
        }.value
        guard !Task.isCancelled else { return }

        var targets: [String: Target] = [:]
        func rows(_ groups: [ServerGroupInfo]) -> [LocationRow] {
            groups.map { group in
                let row = Self.row(for: group, depth: 0, secureCore: secureCore)
                targets[row.id] = .group(group, secureCore: secureCore)
                return row
            }
        }
        let countries = rows(countryGroups)
        let gateways = rows(gatewayGroups)

        self.secureCore = secureCore
        self.targets = targets
        self.countries = countries
        self.gateways = gateways
        isFreeTier = userTier?.isFreeTier ?? false
        isLoading = false
        reloadOfferBanner()

        // 펼쳐 둔 항목이 새 목록에도 있으면 하위 행을 다시 읽고, 없으면 접음
        if let expandedID, targets[expandedID] != nil {
            loadChildren(of: expandedID)
        } else {
            expandedID = nil
            children = []
        }
    }

    private nonisolated static func groups(
        _ kind: VPNServerFilter.ServerTypeFilter,
        search: String,
        secureCore: Bool,
        repository: ServerRepository
    ) -> [ServerGroupInfo] {
        repository.getGroups(
            filteredBy: [
                .kind(kind),
                .isNotUnderMaintenance,
                .features(secureCore ? .secureCore : .standard),
                .matches(search),
                ProtocolFilters().supportedProtocolsFilter,
            ],
            groupedBy: .serverType
        )
    }

    private nonisolated static func sorted(
        _ groups: [ServerGroupInfo],
        by sort: LocationSort,
        userCountry: String?,
        repository: ServerRepository
    ) -> [ServerGroupInfo] {
        let byName = groups
            .map { (group: $0, name: displayName(of: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(\.group)
        guard sort == .nearest, let userCountry else { return byName }

        // 검색으로 걸러진 목록에는 사용자의 국가가 없을 수 있어 기준점은 전체 목록에서 찾음
        let origin = groups.first { $0.kind == .country(code: userCountry) }
            ?? repository.getGroups(filteredBy: [.kind(.country)], groupedBy: .serverType)
            .first { $0.kind == .country(code: userCountry) }
        guard let origin else { return byName }

        func distance(to group: ServerGroupInfo) -> Double {
            // 구면 위 두 점 사이의 거리 (하버사인). 순서만 필요하므로 반지름은 곱하지 않음.
            let lat1: Double = origin.latitude * Double.pi / 180
            let lat2: Double = group.latitude * Double.pi / 180
            let dLat: Double = lat2 - lat1
            let dLon: Double = (group.longitude - origin.longitude) * Double.pi / 180
            let sinLat: Double = sin(dLat / 2)
            let sinLon: Double = sin(dLon / 2)
            let a: Double = sinLat * sinLat + cos(lat1) * cos(lat2) * sinLon * sinLon
            return 2 * atan2(sqrt(a), sqrt(1 - a))
        }
        // 안정 정렬이 아니므로 거리가 같으면 이름순 위치로 가름
        var keyed: [(offset: Int, group: ServerGroupInfo, distance: Double)] = []
        for (offset, group) in byName.enumerated() {
            keyed.append((offset: offset, group: group, distance: distance(to: group)))
        }
        keyed.sort { lhs, rhs in
            if lhs.distance == rhs.distance {
                return lhs.offset < rhs.offset
            }
            return lhs.distance < rhs.distance
        }
        return keyed.map(\.group)
    }

    private nonisolated static func displayName(of group: ServerGroupInfo) -> String {
        switch group.kind {
        case let .country(code):
            ConnectionSpec.Location.country(code: code, order: .fastest).headerText(locale: .current) ?? group.kind.name
        default:
            group.kind.name
        }
    }

    // MARK: - 펼치기

    public func toggleExpansion(of id: String) {
        if expandedID == id {
            expandedID = nil
            children = []
            return
        }
        expandedID = id
        loadChildren(of: id)
    }

    private func loadChildren(of id: String) {
        guard case let .group(group, secureCore) = targets[id] else {
            children = []
            return
        }
        // 이전에 펼쳤던 항목의 하위 대상은 버림
        targets = targets.filter { if case .group = $0.value { !$0.key.hasPrefix(Self.childPrefix) } else { false } }

        var rows: [LocationRow] = []
        switch CityStateListType(groupInfo: group, search: searchText, secureCore: secureCore) {
        case let .cities(groups), let .states(groups):
            for child in groups {
                let row = Self.row(for: child, depth: 1, secureCore: secureCore)
                targets[row.id] = .group(child, secureCore: secureCore)
                rows.append(row)
            }
        case let .gateways(servers), let .secureCores(servers):
            for server in servers {
                let row = Self.row(for: server, idPrefix: Self.childPrefix)
                targets[row.id] = .server(server, parentName: group.kind.name)
                rows.append(row)
            }
        }
        children = rows
    }

    // MARK: - 서버 목록 팝오버

    public func showServers(of id: String) {
        guard case let .group(group, secureCore) = targets[id] else { return }
        targets = targets.filter { !$0.key.hasPrefix(Self.serverPrefix) }
        serverListTitle = group.kind.name
        serverList = nil
        serverListRowID = id

        let search = searchText
        let repository = repository
        Task { [weak self] in
            let servers = await Task.detached(priority: .userInitiated) {
                repository.getServers(
                    filteredBy: [
                        .kind(group.kind.serverTypeFilter),
                        .features(secureCore ? .secureCore : .standard),
                        .matches(search),
                        ProtocolFilters().supportedProtocolsFilter,
                    ],
                    orderedBy: .loadAscending
                )
            }.value
            guard let self, serverListRowID == id else { return }
            serverList = servers.map { server in
                let row = Self.row(for: server, idPrefix: Self.serverPrefix)
                self.targets[row.id] = .server(server, parentName: group.kind.name)
                return row
            }
        }
    }

    // MARK: - 연결

    public func connect(to id: String) {
        guard !isFreeTier else {
            displayUpsellModal?()
            return
        }
        guard let target = targets[id] else { return }

        let location: ConnectionSpec.Location
        let trigger: UserInitiatedVPNChange.VPNTrigger
        switch target {
        case let .group(group, secureCore):
            guard !group.isUnderMaintenance else { return }
            switch group.kind {
            case let .country(code):
                location = secureCore ? .secureCore(.anyHop(to: code, .fastest)) : group.kind.locationWithOrder()
                trigger = .countriesCountry
            case .gateway:
                location = group.kind.locationWithOrder()
                trigger = .countriesCountry
            case .city:
                location = group.kind.locationWithOrder()
                trigger = .countriesCity
            case .state:
                location = group.kind.locationWithOrder()
                trigger = .countriesState
            }
        case let .server(server, parentName):
            guard !server.logical.isUnderMaintenance else { return }
            if case .secureCore = server.logical.kind {
                location = .secureCore(.hop(to: server.logical.exitCountryCode, via: server.logical.entryCountryCode))
            } else {
                location = .exact(
                    .paid,
                    logicalID: server.logical.id,
                    number: server.logical.serverNameComponents.sequence,
                    subregion: parentName,
                    regionCode: server.logical.exitCountryCode
                )
            }
            trigger = .countriesServer
        }

        serverListRowID = nil
        let spec = ConnectionSpec(location: location, features: [])
        let connectionProtocol = (try? defaultConnectionStorage.getDefaultProtocol()) ?? .smartProtocol
        let connectToVPN = connectToVPN
        Task {
            do {
                try await connectToVPN(spec, connectionProtocol, trigger)
            } catch {
                log.error("Failed to connect to VPN from the location list: \(error)")
            }
        }
    }

    public func connectToFastest() {
        let spec = ConnectionSpec(location: .any(.fastest), features: [])
        let connectToVPN = connectToVPN
        Task {
            try? await connectToVPN(spec, nil, .quick)
        }
    }

    // MARK: - 행 만들기

    private nonisolated static let childPrefix = "child/"
    private nonisolated static let serverPrefix = "server/"

    private nonisolated static func row(for group: ServerGroupInfo, depth: Int, secureCore: Bool) -> LocationRow {
        let id: String
        let leading: LocationRow.Leading
        let location: ConnectionSpec.Location
        switch group.kind {
        case let .country(code):
            id = code
            leading = .flag(secureCore ? .withCurve(.country(code: code)) : .standard(.country(code: code)))
            location = .country(code: code, order: .fastest)
        case let .gateway(name):
            id = "gateway/\(name)"
            leading = .flag(.standard(.gateway))
            location = .gateway(name: name)
        case let .city(name, code):
            id = "\(childPrefix)\(code)/\(name)"
            leading = .pin
            location = .city(name: name, code: code, order: .fastest)
        case let .state(name, code):
            id = "\(childPrefix)\(code)/\(name)"
            leading = .pin
            location = .state(name: name, code: code, order: .fastest)
        }
        let title = depth == 0 ? (location.headerText(locale: .current) ?? group.kind.name) : group.kind.name
        return LocationRow(
            id: id,
            title: title,
            subtitle: nil,
            leading: leading,
            trailing: .features(
                p2p: group.featureUnion.contains(.p2p),
                tor: group.featureUnion.contains(.tor),
                smartRouting: group.supportsSmartRouting
            ),
            isUnderMaintenance: group.isUnderMaintenance,
            depth: depth,
            isExpandable: depth == 0,
            hasServerList: depth > 0
        )
    }

    private nonisolated static func row(for server: ServerInfo, idPrefix: String) -> LocationRow {
        let logical = server.logical
        var title = logical.name
        var subtitle: String?
        var leading = LocationRow.Leading.none
        switch logical.kind {
        case let .secureCore(entryCountryCode):
            let location = ConnectionSpec.Location.secureCore(.hop(to: logical.exitCountryCode, via: entryCountryCode))
            title = location.text(locale: .current)
            subtitle = location.subtext(locale: .current)
            leading = .flag(.stacked(bottom: .country(code: entryCountryCode), top: .country(code: logical.exitCountryCode)))
        case .gateway:
            leading = .flag(.standard(.country(code: logical.exitCountryCode)))
        case .country:
            break
        }
        return LocationRow(
            id: "\(idPrefix)\(logical.id)",
            title: title,
            subtitle: subtitle,
            leading: leading,
            trailing: .load(logical.load),
            isUnderMaintenance: logical.isUnderMaintenance,
            depth: idPrefix == childPrefix ? 1 : 0,
            isExpandable: false,
            hasServerList: false
        )
    }
}
