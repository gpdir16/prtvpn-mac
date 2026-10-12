//
//  Created on 17/09/2024.
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
import CoreLocation
import Domain
import Ergonomics
import SVGView
import SwiftUI

public struct HomeMapView: View {
    let store: StoreOf<HomeMapFeature>

    private let mapBounds: CGRect
    private let availableHeight: CGFloat
    private let availableWidth: CGFloat

    @State private var pinMode: MapPin.Mode = .disconnected

    public init(store: StoreOf<HomeMapFeature>, availableHeight: CGFloat, availableWidth: CGFloat) {
        self.store = store
        self.availableHeight = availableHeight
        self.availableWidth = availableWidth
        self.mapBounds = SVGView.mapBounds
    }

    public var body: some View {
        ZStack {
            SVGView.map
            MapPin(mode: .constant(store.pinMode))
                .scaleEffect(1 / mapScale()) // pin scales together with the map, so we need to counter it to preserve the original size
                .offset(store.pinOffset)
                .opacity(store.shouldShowPin ? 1 : 0)
        }
        .frame(width: mapBounds.width, height: mapBounds.height)
        .scaleEffect(mapScale())
        .offset(mapOffset())
        .environment(\.layoutDirection, .leftToRight)
        #if os(macOS)
            // 스토어가 보내는 애니메이션에만 기대면 연결할 때나 사이드바를 열 때처럼 배치가 한 번에 바뀌는 경우
            // 지도가 뚝 끊겨 움직임. 배율과 위치가 바뀌면 방향에 상관없이 항상 부드럽게 옮김.
            .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: Placement(scale: mapScale(), offset: mapOffset()))
        #endif
    }

    #if os(macOS)
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private struct Placement: Equatable {
            let scale: CGFloat
            let offset: CGSize
        }
    #endif

    private func mapOffset() -> CGSize {
        guard let code = (store.mapState.code ?? store.userCountry)?.lowercased(),
              let node = SVGView.mapSVG.mainlandNode(code: code) else {
            return .zero
        }

        let scale = mapScale()
        #if os(macOS)
            // 핀(서버 위치)이 있으면 국가 외곽의 중심이 아니라 핀을 빈 영역의 정중앙에 둠
            if store.shouldShowPin, store.pinMode != .invisible, store.pinOffset != .zero {
                return .init(width: -store.pinOffset.width * scale, height: -store.pinOffset.height * scale)
            }
        #endif
        return .init(
            width: (mapBounds.midX - node.bounds().midX) * scale,
            height: Self.verticalShift + (mapBounds.midY - node.bounds().midY) * scale
        ) // move the map 40 points down to avoid connection status and netshield stats
    }

    private func mapScale() -> CGFloat {
        guard let code = (store.mapState.code ?? store.userCountry)?.lowercased(),
              let node = SVGView.mapSVG.mainlandNode(code: code) else {
            return wholeMapScale()
        }
        let scaleX = (availableWidth - 40) / node.bounds().width // 40 is the horizontal padding
        let scaleY = (availableHeight - Self.verticalPadding) / node.bounds().height // 150 is the vertical padding. We need it for connection status and netshield stats

        return min(min(scaleX, scaleY), 4) // max scale, useful for small countries
    }

    // macOS는 연결 패널을 뺀 빈 영역을 그대로 넘겨받으므로 따로 밀거나 크게 비울 필요가 없음
    #if os(macOS)
        private static let verticalShift: CGFloat = 0
        private static let verticalPadding: CGFloat = 80
    #else
        private static let verticalShift: CGFloat = 40
        private static let verticalPadding: CGFloat = 150
    #endif

    private func wholeMapScale() -> CGFloat {
        let scaleX = availableWidth / mapBounds.width
        let scaleY = availableHeight / mapBounds.height
        #if os(macOS)
            // 세계 지도는 빈 영역보다 조금 크게 그려 사이드바 유리 아래까지 이어지게 함
            return min(scaleX * 1.4, scaleY)
        #else
            return min(scaleX, scaleY)
        #endif
    }
}
