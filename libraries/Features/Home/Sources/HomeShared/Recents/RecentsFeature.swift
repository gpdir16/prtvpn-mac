//
//  Created on 07/10/2024.
//
//  Copyright (c) 2024 Proton AG
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
import Domain
import Foundation
import OrderedCollections
import SwiftUI
import VPNAppCore
import VPNShared

@Reducer
public struct RecentsFeature {
    /// 최근 목록에 남길 개수를 담는 UserDefaults 키 (macOS 설정 화면에서 바꿈)
    public static let limitKey = "RecentsLimit"
    public static let defaultLimit = 5
    public static var limit: Int {
        UserDefaults.standard.object(forKey: limitKey) as? Int ?? defaultLimit
    }

    public typealias ActionSender = (Action) -> Void

    @ObservableState
    public struct State: Equatable {
        @SharedReader(.vpnConnectionStatus) public var vpnConnectionStatus: VPNConnectionStatus

        @SharedReader(.defaultConnectionPreference) private var defaultConnectionPreference
        @Shared(.recents) fileprivate var recents: OrderedSet<RecentConnection>

        /// List of recent connections, minus the default connection if its not pinned
        public var recentConnectionList: OrderedSet<RecentConnection> {
            @Dependency(\.connectionInventory) var presenter
            return presenter.recentConnectionList(
                defaultConnectionPreference: defaultConnectionPreference,
                recents: recents,
                currentConnection: vpnConnectionStatus.spec
            )
        }

        @SharedReader(.userTier) public var userTier: Int?

        public init() {
            @Dependency(\.recentsStorage) var recentsStorage
            $recents.withLock { $0 = recentsStorage.readFromStorage() }
        }
    }

    public enum Action {
        case connectionEstablished(ConnectionSpec)
        case pin(RecentConnection)
        case unpin(RecentConnection)
        case remove(RecentConnection)
        case clear
        case watchConnectionStatus
        case newConnectionStatus(VPNConnectionStatus)
        case upsellTapped(BannerType)

        case delegate(Delegate)

        @CasePathable
        public enum Delegate: Equatable {
            case connect(ConnectionSpec, isPinned: Bool)
        }
    }

    private enum CancelId {
        case watchConnectionStatus
    }

    @Dependency(\.recentsStorage) var recentsStorage
    @Dependency(\.date) var date
    @Dependency(\.pushAlert) var pushAlert

    public init() {}

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .watchConnectionStatus:
                return .publisher {
                    state
                        .$vpnConnectionStatus
                        .publisher
                        .removeDuplicates()
                        .receive(on: UIScheduler.shared)
                        .map(Action.newConnectionStatus)
                }
                .cancellable(id: CancelId.watchConnectionStatus, cancelInFlight: true)

            case let .upsellTapped(type):
                switch type {
                case .worldwideCover:
                    pushAlert(AllCountriesUpsellAlert())
                case .fasterBrowsing:
                    pushAlert(VPNAcceleratorUpsellAlert())
                case .streaming:
                    pushAlert(StreamingUpsellAlert())
                case .netshield:
                    pushAlert(NetShieldUpsellAlert())
                case .secureCore:
                    pushAlert(SecureCoreUpsellAlert())
                case .p2p:
                    pushAlert(P2PUpsellAlert())
                case .devices:
                    pushAlert(DevicesUpsellAlert())
                case .tor:
                    pushAlert(TorUpsellAlert())
                case .more:
                    pushAlert(CustomizationUpsellAlert())
                }

                return .none

            case let .newConnectionStatus(connectionStatus):
                guard case .connected = connectionStatus else { return .none }
                guard let spec = connectionStatus.spec else {
                    log.info("Unable to generate spec for connection status: \(connectionStatus)")
                    return .none
                }
                return .send(.connectionEstablished(spec))

            case let .connectionEstablished(spec):
                withAnimation {
                    state.$recents.withLock {
                        $0.updateList(with: spec)
                        #if os(macOS)
                            // 설정한 개수까지만 남김. 고정한 항목은 마지막까지 남김.
                            let limit = RecentsFeature.limit
                            while $0.count > limit {
                                if let index = $0.lastIndex(where: { !$0.pinned }) {
                                    $0.remove(at: index)
                                } else {
                                    $0.removeLast()
                                }
                            }
                        #endif
                    }
                }
                recentsStorage.saveToStorage(state.recents)

                return .none

            case .clear:
                withAnimation {
                    state.$recents.withLock { $0.removeAll() }
                }
                recentsStorage.saveToStorage(state.recents)
                return .none

            case let .pin(recent):
                withAnimation {
                    state.$recents.withLock { $0.pin(recent: recent, pinnedDate: date.now) }
                }
                recentsStorage.saveToStorage(state.recents)
                return .none

            case let .unpin(recent):
                withAnimation {
                    state.$recents.withLock { $0.unpin(recent: recent) }
                }
                recentsStorage.saveToStorage(state.recents)
                return .none

            case let .remove(recent):
                _ = withAnimation {
                    state.$recents.withLock { $0.remove(recent) }
                }
                recentsStorage.saveToStorage(state.recents)
                return .none

            case .delegate:
                return .none
            }
        }
    }
}
