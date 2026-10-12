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
    import Dependencies

    import Domain
    import HomeShared
    import Localization
    import SharedViews
    import Strings
    import Theme
    import VPNAppCore

    /// 데스크톱용 메인 화면.
    /// 왼쪽은 시스템 사이드바(검색, 최근, 국가 목록)이고, 지도는 창 전체에 깔되 빈 영역의 중앙에 맞춤. 연결 상태 패널은 아래쪽에 떠 있음.
    /// 빠른 설정은 창 도구 막대에 둠.
    public struct HomeDesktopView<Locations: View, Widgets: View>: View {
        @Bindable var store: StoreOf<HomeFeature>

        private let onSearch: (String) -> Void
        private let locations: () -> Locations
        private let widgets: () -> Widgets

        @State private var searchText = ""
        /// 지도가 패널에 가려지지 않도록 패널 높이만큼 위쪽 영역에 맞춤
        @State private var panelHeight: CGFloat = 120
        @State private var isToolbarHovered = false

        private static var gradientHeight: CGFloat { 220 }
        private static var panelMaxWidth: CGFloat { 560 }
        private static var panelMargin: CGFloat { 20 }
        private static var toolbarHeight: CGFloat { 52 }

        public init(
            store: StoreOf<HomeFeature>,
            onSearch: @escaping (String) -> Void,
            @ViewBuilder locations: @escaping () -> Locations,
            @ViewBuilder widgets: @escaping () -> Widgets
        ) {
            self.store = store
            self.onSearch = onSearch
            self.locations = locations
            self.widgets = widgets
        }

        public var body: some View {
            NavigationSplitView {
                locations()
                    .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
            } detail: {
                content
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            widgets()
                        }
                    }
                    // 시스템 도구 막대 배경은 항상 숨김. 켰다 껐다 하면 배치가 다시 잡히며 깜빡이므로,
                    // 포인터를 올렸을 때 보이는 블러는 아래 content에서 직접 그려 투명도만 부드럽게 바꿈.
                    .toolbarBackground(.hidden, for: .windowToolbar)
                    .background(TitlebarHoverTracker(height: Self.toolbarHeight) { hovered in
                        withAnimation(.easeInOut(duration: 0.3)) { isToolbarHovered = hovered }
                    })
            }
            .searchable(text: $searchText, placement: .sidebar, prompt: Localizable.searchForCountry)
            .onChange(of: searchText) { _, query in
                onSearch(query)
            }
            .connectionDetailsSheet(store: $store)
            .changeServerSheet(store: $store)
            .whatsNewSheet(store: $store)
            .freeConnectionsInfoSheet(store: $store)
            .localAgentNoticeSheet(store: $store)
            .task { await store.send(.connectionStatus(.watchConnectionStatus)).finish() }
        }

        // MARK: - 지도와 연결 패널

        private var content: some View {
            ZStack(alignment: .bottom) {
                Color(.background)
                    .ignoresSafeArea()

                // 지도는 창 전체에 그려 시스템 사이드바와 도구 막대 아래로 이어지게 하되,
                // 중심은 안전 영역(사이드바 오른쪽, 도구 막대 아래) 가운데 패널 위에 남는 빈 영역의 중앙에 맞춤.
                GeometryReader { proxy in
                    let insets = proxy.safeAreaInsets
                    let mapWidth = proxy.size.width
                    // panelHeight에는 패널의 위아래 여백이 이미 들어 있음
                    let mapHeight = max(0, proxy.size.height - panelHeight)
                    GeometryReader { full in
                        HomeMapView(
                            store: store.scope(state: \.map, action: \.map),
                            availableHeight: mapHeight,
                            availableWidth: mapWidth
                        )
                        .frame(width: mapWidth, height: mapHeight)
                        .padding(.leading, insets.leading)
                        .padding(.top, insets.top)
                        .frame(width: full.size.width, height: full.size.height, alignment: .topLeading)
                    }
                    .ignoresSafeArea()
                }
                .allowsHitTesting(false)

                // 상태 색(보호됨 초록, 노출됨 빨강)은 지도 위에 덮어 지도까지 함께 물들임
                LinearGradient(
                    colors: [gradientColor.opacity(0.3), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: Self.gradientHeight)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
                .allowsHitTesting(false)

                // 도구 막대에 포인터를 올렸을 때만 나타나는 블러 띠. 아래쪽 경계는 서서히 풀어 줌.
                Rectangle()
                    .fill(.regularMaterial)
                    .mask(
                        LinearGradient(
                            stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: Self.toolbarHeight + 14)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea()
                    .opacity(isToolbarHovered ? 1 : 0)
                    .allowsHitTesting(false)

                VStack(spacing: 10) {
                    ConnectionStatusBanner(
                        store: store.scope(state: \.connectionStatus.connectionStatusBanner, action: \.connectionStatus.connectionStatusBanner)
                    )
                    .desktopGlass(cornerRadius: 12)
                    connectionPanel
                }
                .frame(maxWidth: Self.panelMaxWidth)
                .padding(Self.panelMargin)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
            }
        }

        private var cardStore: StoreOf<HomeConnectionCardFeature> {
            store.scope(state: \.connectionCard, action: \.connectionCard)
        }

        private var connectionPanel: some View {
            let card = cardStore
            let status = card.vpnConnectionStatus
            return VStack(spacing: 0) {
                HStack(spacing: 14) {
                    HStack(spacing: 12) {
                        FlagView(location: card.presentedSpec.location, flagSize: .defaultSize)
                        VStack(alignment: .leading, spacing: 2) {
                            protectionLabel
                            Text(locationTitle(card: card))
                                .font(.system(size: 17, weight: .semibold))
                                .lineLimit(1)
                            if let subtitle = locationSubtitle(card: card) {
                                Text(subtitle)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 6) {
                        connectButton(card: card, status: status)
                        if card.showChangeServerButton {
                            changeServerButton(card: card)
                        }
                    }
                    .frame(width: 150)
                }
                .padding(16)

                if case let .connected(_, actual?) = status {
                    Divider()
                    ConnectionFactsRow(actual: actual)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }
            .desktopGlass(cornerRadius: 18)
            .animation(.smooth(duration: 0.25), value: status.showingConnectButton)
        }

        private func locationTitle(card: StoreOf<HomeConnectionCardFeature>) -> String {
            card.presentedSpec.location.text(locale: .current)
        }

        private func locationSubtitle(card: StoreOf<HomeConnectionCardFeature>) -> String? {
            // 연결된 서버가 있으면 도시와 서버 이름을, 없으면 연결 대상의 보조 설명을 보여 줌
            if let server = card.presentedServer {
                let parts = [server.logical.city, server.logical.name].compactMap { $0 }.filter { !$0.isEmpty }
                if !parts.isEmpty {
                    return parts.joined(separator: ", ")
                }
            }
            return card.presentedSpec.location.subtext(locale: .current)
        }

        @ViewBuilder
        private func connectButton(card: StoreOf<HomeConnectionCardFeature>, status: VPNConnectionStatus) -> some View {
            let title = ConnectionCardModel().buttonText(for: status)
            let action = {
                switch status {
                case .disconnected, .disconnecting:
                    _ = card.send(.delegate(.connect(card.presentedSpec)))
                case .connected, .connecting, .resolving:
                    _ = card.send(.delegate(.disconnect))
                }
            }
            let label = Text(title).frame(maxWidth: .infinity)
            // 연결은 강조 버튼, 끊기, 취소는 보통 버튼으로 구분함
            if status.showingConnectButton {
                Button(action: action) { label }
                    .desktopProminentButton()
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("connect_button")
            } else {
                Button(action: action) { label }
                    .desktopPlainButton()
                    .controlSize(.large)
                    .accessibilityIdentifier("disconnect_button")
            }
        }

        @ViewBuilder
        private func changeServerButton(card: StoreOf<HomeConnectionCardFeature>) -> some View {
            switch card.serverChangeAvailability ?? .available {
            case .available:
                ChangeServerButtonLabel(
                    sendAction: { _ = card.send($0) },
                    changeServerAllowedDate: .distantPast
                )
            case let .unavailable(until, _, _):
                ChangeServerButtonLabel(
                    sendAction: { _ = card.send($0) },
                    changeServerAllowedDate: until
                )
            }
        }

        // MARK: - 보호 상태

        private var protectionState: ProtectionState {
            store.connectionStatus.protectionState
        }

        private var gradientColor: Color {
            switch protectionState {
            case .protected, .protectedSecureCore:
                .green
            case .unprotected:
                .red
            case .protecting, .resolving:
                .white
            }
        }

        private var protectionLabel: some View {
            HStack(spacing: 5) {
                switch protectionState {
                case .protected:
                    protectionTitle(Localizable.connectionStatusProtected, symbol: "lock.fill", color: .green)
                case .protectedSecureCore:
                    protectionTitle(Localizable.connectionStatusProtected, symbol: "lock.shield.fill", color: .green)
                case .unprotected:
                    protectionTitle(Localizable.connectionStatusUnprotected, symbol: "lock.open.fill", color: .red)
                case .protecting:
                    ProgressView().controlSize(.mini)
                    protectionTitle(Localizable.connectionStatusProtecting, symbol: nil, color: .secondary)
                case .resolving:
                    ProgressView().controlSize(.mini)
                    protectionTitle(Localizable.connectionStatusLoading, symbol: nil, color: .secondary)
                }
            }
        }

        @ViewBuilder
        private func protectionTitle(_ text: String, symbol: String?, color: Color) -> some View {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .textCase(.uppercase)
        }
    }

    // MARK: - 연결 상세 정보

    /// 연결된 동안 패널 아래쪽에 보여 주는 서버, IP, 프로토콜, 부하, 연결 시간
    private struct ConnectionFactsRow: View {
        let actual: VPNConnectionActual

        var body: some View {
            HStack(alignment: .top, spacing: 0) {
                fact(Localizable.hudVpnIp, actual.server.endpoint.exitIp, monospaced: true)
                separator
                fact(Localizable.hudProtocol, actual.vpnProtocol.localizedDescription)
                separator
                VStack(alignment: .leading, spacing: 3) {
                    caption(Localizable.hudLoad)
                    HStack(spacing: 6) {
                        Gauge(value: Double(actual.server.logical.load), in: 0 ... 100) { EmptyView() }
                            .gaugeStyle(.accessoryLinearCapacity)
                            .tint(loadColor)
                            .frame(width: 44)
                        Text("\(actual.server.logical.load)%")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                separator
                VStack(alignment: .leading, spacing: 3) {
                    caption(Localizable.hudDuration)
                    if let connectedDate = actual.connectedDate {
                        Text(connectedDate, style: .timer)
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                    } else {
                        Text("–").font(.system(size: 12, weight: .medium))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        private var loadColor: Color {
            switch actual.server.logical.load {
            case 90...: .red
            case 75 ..< 90: .orange
            default: .green
            }
        }

        private var separator: some View {
            Divider().frame(height: 28).padding(.horizontal, 10)
        }

        private func caption(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }

        private func fact(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
            VStack(alignment: .leading, spacing: 3) {
                caption(title)
                Text(value)
                    .font(.system(size: 12, weight: .medium, design: monospaced ? .monospaced : .default))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 유리 효과

    /// 창 제목 막대를 투명하게 만들고, 포인터가 창 위쪽 띠(도구 막대) 위에 있는지 알려 줌.
    /// 추적 영역을 창 프레임 뷰에 걸어 두므로 도구 막대 버튼 위에 있어도 끊기지 않음.
    private struct TitlebarHoverTracker: NSViewRepresentable {
        let height: CGFloat
        let onChange: (Bool) -> Void

        func makeNSView(context _: Context) -> TrackerView {
            let view = TrackerView()
            view.height = height
            view.onChange = onChange
            return view
        }

        func updateNSView(_ view: TrackerView, context _: Context) {
            view.height = height
            view.onChange = onChange
        }

        final class TrackerView: NSView {
            var height: CGFloat = 0
            var onChange: ((Bool) -> Void)?
            private var isHovered = false
            private var trackingArea: NSTrackingArea?
            private weak var trackedView: NSView?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let trackingArea { trackedView?.removeTrackingArea(trackingArea) }
                trackingArea = nil
                guard let window, let frameView = window.contentView?.superview else { return }
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                let area = NSTrackingArea(
                    rect: .zero,
                    options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                    owner: self
                )
                frameView.addTrackingArea(area)
                trackingArea = area
                trackedView = frameView
            }

            override func mouseEntered(with event: NSEvent) { update(event) }
            override func mouseMoved(with event: NSEvent) { update(event) }
            override func mouseExited(with _: NSEvent) { set(false) }

            private func update(_ event: NSEvent) {
                guard let window else { return }
                set(event.locationInWindow.y >= window.frame.height - height)
            }

            private func set(_ hovered: Bool) {
                guard hovered != isHovered else { return }
                isHovered = hovered
                onChange?(hovered)
            }
        }
    }

    public extension View {
        /// 지도 위에 떠 있는 패널 배경. macOS 26부터는 리퀴드 글라스를, 그 이전에는 머티리얼을 씀.
        @ViewBuilder
        func desktopGlass(cornerRadius: CGFloat) -> some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            if #available(macOS 26.0, *) {
                glassEffect(.regular, in: shape)
            } else {
                background(.regularMaterial, in: shape)
                    .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
            }
        }

        @ViewBuilder
        func desktopProminentButton() -> some View {
            if #available(macOS 26.0, *) {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.borderedProminent)
            }
        }

        @ViewBuilder
        func desktopPlainButton() -> some View {
            if #available(macOS 26.0, *) {
                buttonStyle(.glass)
            } else {
                buttonStyle(.bordered)
            }
        }
    }

#endif
