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

import Domain
import Foundation

/// 가상 서버(스마트 라우팅)를 서버 선택과 목록에 어떻게 쓸지 정하는 설정
public enum VirtualServerPolicy: String, CaseIterable, Identifiable, Sendable {
    /// 구분하지 않음
    case any
    /// 가상 서버만 씀
    case only
    /// 가상 서버는 쓰지 않음
    case never
    /// 물리 서버가 없는 곳에서만 가상 서버를 씀
    case fallback

    public var id: Self { self }

    public static let defaultsKey = "VirtualServerPolicy"
    /// 설정이 바뀌면 목록을 다시 읽도록 보내는 알림
    public static let didChangeNotification = Notification.Name("VirtualServerPolicyDidChange")

    public static var current: Self {
        get { Self(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .any }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }
}

extension ServerRepository {
    /// 모든 서버 질의에 가상 서버 설정을 적용한 저장소를 돌려줌.
    /// 서버를 ID 로 직접 지정한 질의(연결 복원, 특정 서버 연결)는 건드리지 않음.
    func applyingVirtualServerPolicy() -> ServerRepository {
        var repository = self
        let groups = groups, servers = servers, server = server

        @Sendable func isExplicit(_ filters: [VPNServerFilter]) -> Bool {
            filters.contains {
                switch $0 {
                case .logicalID, .endpointID, .virtual: true
                default: false
                }
            }
        }

        repository.groups = { filters, grouping, order in
            guard !isExplicit(filters) else { return groups(filters, grouping, order) }
            switch VirtualServerPolicy.current {
            case .any:
                return groups(filters, grouping, order)
            case .only:
                return groups(filters + [.virtual(true)], grouping, order)
            case .never:
                return groups(filters + [.virtual(false)], grouping, order)
            case .fallback:
                // 물리 서버가 있는 위치는 물리 서버만으로 만든 묶음을, 없는 위치는 원래 묶음을 씀
                let physical = Dictionary(
                    groups(filters + [.virtual(false)], grouping, order).map { ($0.kind, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                return groups(filters, grouping, order).map { physical[$0.kind] ?? $0 }
            }
        }
        repository.servers = { filters, order in
            guard !isExplicit(filters) else { return servers(filters, order) }
            switch VirtualServerPolicy.current {
            case .any:
                return servers(filters, order)
            case .only:
                return servers(filters + [.virtual(true)], order)
            case .never:
                return servers(filters + [.virtual(false)], order)
            case .fallback:
                let physical = servers(filters + [.virtual(false)], order)
                return physical.isEmpty ? servers(filters, order) : physical
            }
        }
        repository.server = { filters, order in
            guard !isExplicit(filters) else { return server(filters, order) }
            switch VirtualServerPolicy.current {
            case .any:
                return server(filters, order)
            case .only:
                return server(filters + [.virtual(true)], order)
            case .never:
                return server(filters + [.virtual(false)], order)
            case .fallback:
                return server(filters + [.virtual(false)], order) ?? server(filters, order)
            }
        }
        return repository
    }
}
