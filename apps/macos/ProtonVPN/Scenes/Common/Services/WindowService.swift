//
//  WindowService.swift
//  ProtonVPN - Created on 27.06.19.
//
//  Copyright (c) 2019 Proton Technologies AG
//
//  This file is part of ProtonVPN.
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
//

import AppKit
import Cocoa
import SwiftUI

import ComposableArchitecture
import Dependencies
import Home

import PMLogger

import Announcement
import BugReport
import LegacyCommon
import Modals
import VPNAppCore

import Ergonomics
import Strings

import Theme

protocol WindowServiceFactory {
    func makeWindowService() -> WindowService
}

protocol WindowService: WindowControllerDelegate {
    func setStatusMenuWindowController(_ controller: StatusMenuWindowController)

    func showIfPresent(windowController: (some NSWindowController).Type) -> Bool
    func closeIfPresent(windowController: (some NSWindowController).Type)

    func showLogin(viewModel: LoginViewModel)
    #if !REDESIGN
        func showSidebar(appStateManager: AppStateManager, vpnGateway: VpnGatewayProtocol)
    #endif

    func openAbout(factory: AboutViewController.Factory)
    func openAcknowledgements()
    func openSettingsWindow(viewModel: SettingsContainerViewModel, tabBarViewModel: SettingsTabBarViewModel, accountViewModel: AccountViewModel)
    func openProfilesWindow(viewModel: ProfilesContainerViewModel)
    func openReportBugWindow()
    func openPlutoniumWindow()
    func openSystemExtensionGuideWindow(origin: SystemExtensionTourAlert.Origin, cancelledHandler: @escaping () -> Void)
    func openSubuserAlertWindow(alert: SubuserWithoutConnectionsAlert)

    func bringWindowsToForeground() -> Bool
    func closeActiveWindows(except: [NSWindowController.Type])

    func presentKeyModal(viewController: NSViewController, activatingApp: Bool)
    func presentKeyModalOnActiveScreen(viewController: NSViewController, activatingApp: Bool)

    /// Check if window with view controller of the same class is already open.
    func isKeyModalPresent(viewController: NSViewController) -> Bool
}

extension WindowService {
    func closeActiveWindows() {
        closeActiveWindows(except: [])
    }
}

// this need to abstract class for common functions. for sharing code. ios/mac should have different implementation
final class WindowServiceImplementation: WindowService {
    typealias Factory = AnnouncementsViewModelFactory
        & AppStateManagerFactory
        & ConnectingOverlayViewModelFactory
        & CoreAlertServiceFactory
        & CountriesSectionViewModelFactory
        & CreateNewProfileViewModelFactory
        & DynamicBugReportManagerFactory
        & HeaderViewModelFactory
        & MapSectionViewModelFactory
        & NavigationServiceFactory
        & ProfileManagerFactory
        & SystemExtensionManagerFactory
        & VpnGatewayFactory
        & VpnManagerFactory

    private let factory: Factory

    private lazy var navService: NavigationService = factory.makeNavigationService()
    private lazy var vpnManager: VpnManagerProtocol = factory.makeVpnManager()
    @Dependency(\.bugReport) private var bugReportCreator
    @Dependency(\.propertiesManager) private var propertiesManager

    fileprivate var mainWindowController: WindowController?
    /// 설정 창에서 최근 목록을 지울 수 있도록 메인 화면의 스토어를 들고 있음
    private var homeStore: StoreOf<HomeFeature>?
    fileprivate var statusMenuWindowController: StatusMenuWindowController?
    fileprivate var activeWindowControllers = Set<WindowController>()

    init(factory: Factory) {
        self.factory = factory
    }

    func setStatusMenuWindowController(_ controller: StatusMenuWindowController) {
        controller.windowService = self
        statusMenuWindowController = controller
    }

    func showIfPresent<T: NSWindowController>(windowController _: T.Type) -> Bool {
        var success = false
        for controller in activeWindowControllers {
            if let controller = controller as? T {
                controller.showWindow(self)
                success = true
                break
            }
        }
        return success
    }

    func closeIfPresent<T: NSWindowController>(windowController _: T.Type) {
        for controller in activeWindowControllers {
            if let controller = controller as? T {
                controller.close()
            }
        }
    }

    func showLogin(viewModel: LoginViewModel) {
        NSApp.setActivationPolicy(.regular)

        if let windowController = mainWindowController {
            windowController.close()
        }

        let windowController = LoginWindowController(viewController: LoginViewController(viewModel: viewModel))
        windowController.delegate = self
        windowController.showWindow(self)
        windowController.window?.makeMain()

        mainWindowController = windowController
    }

    #if !REDESIGN
        func showSidebar(appStateManager: AppStateManager, vpnGateway: VpnGatewayProtocol) {
            NSApp.setActivationPolicy(.regular)

            if let windowController = mainWindowController {
                windowController.close()
            }

            let countriesViewModel = factory.makeCountriesSectionViewModel()
            let homeStore = MainView.makeHomeStore()
            self.homeStore = homeStore
            let mainView = MainView(
                homeStore: homeStore,
                countriesViewModel: countriesViewModel,
                openSettings: { [navService] in navService.openSettings(to: .general) }
            )
            let viewController = NSHostingController(rootView: mainView)
            // SwiftUI 쪽에서 선언한 도구 막대를 창에 그대로 올림
            viewController.sceneBridgingOptions = [.toolbars]

            // 목록 머리글의 정보 버튼은 기존 안내 화면을 메인 창의 시트로 띄움
            countriesViewModel.displayPremiumServices = { [weak viewController] in
                viewController?.presentAsSheet(FeaturesOverlayViewController(viewModel: PremiumFeaturesOverlayViewModel()))
            }
            countriesViewModel.displayGatewaysServices = { [weak viewController] in
                viewController?.presentAsSheet(FeaturesOverlayViewController(viewModel: GatewayFeaturesOverlayViewModel()))
            }

            let windowController = SidebarWindowController(viewController: viewController)
            windowController.delegate = self
            windowController.showWindow(self)
            windowController.window?.makeMain()

            mainWindowController = windowController
            // 기존 사이드바가 표시될 때 하던 것과 같이, 현재 연결 상태를 한 번 알려 화면들이 초기 상태를 받게 함
            vpnGateway.postConnectionInformation()
            showInitialModals()
        }

        func showInitialModals() {
            // TODO: VPNAPPL-2831 actually make sure we don't show what's new after a specified deadline
            propertiesManager.showWhatsNewModal = false

            guard propertiesManager.showWhatsNewModal else {
                return
            }
            propertiesManager.showWhatsNewModal = false

            presentKeyModal(viewController: ModalsFactory.whatsNewViewController(), activatingApp: false)
        }

    #endif

    func openAbout(factory: AboutViewController.Factory) {
        let controller = AboutViewController()
        controller.factory = factory
        let windowController = AboutWindowController(viewController: controller)
        windowController.delegate = self
        activeWindowControllers.insert(windowController)
        windowController.showWindow(self)
    }

    func openAcknowledgements() {
        let windowController = AcknowledgementsWindowController(viewController: AcknowledgementsViewController())
        windowController.delegate = self
        activeWindowControllers.insert(windowController)
        windowController.showWindow(self)
    }

    func openSettingsWindow(viewModel: SettingsContainerViewModel, tabBarViewModel: SettingsTabBarViewModel, accountViewModel: AccountViewModel) {
        NSApp.setActivationPolicy(.regular)

        let general = viewModel.generalSettingsViewModel
        let connection = viewModel.connectionSettingsViewModel
        let advanced = viewModel.advancedSettingsViewModel
        func pane(_ tab: SettingsTab, _ title: String, _ symbol: String) -> (title: String, symbol: String, viewController: NSViewController) {
            let view = NativeSettingsView(
                general: general,
                connection: connection,
                advanced: advanced,
                account: accountViewModel,
                clearRecents: { [weak self] in self?.homeStore?.send(.recents(.clear)) },
                signOut: { [navService] in navService.logOutRequested() },
                tab: tab
            )
            let controller = NSHostingController(rootView: view)
            // 탭을 바꾸면 창이 그 탭의 내용 크기로 맞춰지도록 함
            controller.sizingOptions = [.preferredContentSize]
            return (title, symbol, controller)
        }
        let windowController = SettingsWindowController(
            panes: [
                pane(.general, Localizable.general, "gearshape"),
                pane(.connection, Localizable.connection, "network"),
                pane(.advanced, Localizable.advanced, "slider.horizontal.3"),
                pane(.account, Localizable.account, "person.crop.circle"),
            ],
            selectedIndex: tabBarViewModel.activeTab.rawValue
        )
        windowController.delegate = self
        activeWindowControllers.insert(windowController)
        windowController.showWindow(self)
    }

    func openProfilesWindow(viewModel: ProfilesContainerViewModel) {
        NSApp.setActivationPolicy(.regular)

        let viewController = ProfilesContainerViewController(factory: factory, viewModel: viewModel)
        let windowController = ProfilesWindowController(viewController: viewController)
        windowController.delegate = self
        activeWindowControllers.insert(windowController)
        windowController.showWindow(self)
    }

    func openReportBugWindow() {
        NSApp.setActivationPolicy(.regular)

        let viewController: NSViewController
        let manager = factory.makeDynamicBugReportManager()

        let vc = bugReportCreator.createBugReportViewController(delegate: manager, colors: Colors())
        manager.closeBugReportHandler = { [weak self] in
            self?.closeWindow(withController: ReportBugWindowController.self)
        }
        viewController = vc
        viewController.title = Localizable.reportBug

        let windowController = ReportBugWindowController(viewController: viewController)
        windowController.delegate = self
        activeWindowControllers.insert(windowController)
        windowController.showWindow(self)
    }

    func openPlutoniumWindow() {
        NSApp.setActivationPolicy(.regular)
        let windowController = PlutoniumWindowController(factory: factory)
        activeWindowControllers.insert(windowController)
        windowController.showWindow(self)
        windowController.window?.positionWindow(size: Theme.Constants.settingsViewSize)
    }

    func openSystemExtensionGuideWindow(origin: SystemExtensionTourAlert.Origin, cancelledHandler: @escaping () -> Void) {
        let controller = SystemExtensionGuideViewController(
            origin: origin,
            cancelledHandler: cancelledHandler
        )
        controller.windowService = self
        let windowController = SysexGuideWindowController(viewController: controller)
        windowController.delegate = controller
        activeWindowControllers.insert(windowController)
        windowController.showWindow(self)
        windowController.window?.centerWindowOnScreen()
    }

    func openSubuserAlertWindow(alert: SubuserWithoutConnectionsAlert) {
        let controller = NSHostingController(rootView: Modals.NoConnectionsAvailableView(mode: alert.mode))
        controller.title = ""
        let windowController = SubuserAlertWindowController(viewController: controller)
        windowController.delegate = self
        activeWindowControllers.insert(windowController)
        windowController.showWindow(self)
    }

    func bringWindowsToForeground() -> Bool {
        guard let mainWindowController else {
            return false
        }

        NSApp.setActivationPolicy(.regular)
        activeWindowControllers.forEach { $0.window?.orderFront(self) }
        mainWindowController.window?.makeKeyAndOrderFront(self)
        NSRunningApplication.current.activate(options: [.activateAllWindows])

        return true
    }

    func closeWindow(withController controllerType: NSWindowController.Type) {
        activeWindowControllers
            .filter { vc in vc.isKind(of: controllerType) }
            .forEach { vc in
                Task { @MainActor in
                    vc.close()
                }
            }
        activeWindowControllers = activeWindowControllers.filter { vc in
            !vc.isKind(of: controllerType)
        }
    }

    func closeActiveWindows(except windowTypesToKeepOpen: [NSWindowController.Type]) {
        let controllersToClose = activeWindowControllers.filter { wc in
            !windowTypesToKeepOpen.contains { type in wc.isKind(of: type) }
        }

        controllersToClose.forEach { $0.close() }
        activeWindowControllers = activeWindowControllers.subtracting(controllersToClose)
    }

    func presentKeyModal(viewController: NSViewController) {
        presentKeyModal(viewController: viewController, activatingApp: false)
    }

    func presentKeyModal(viewController: NSViewController, activatingApp: Bool) {
        executeOnUIThread {
            let parent = self.mainWindowController?.contentViewController ?? self.statusMenuWindowController?.contentViewController
            guard let parent else { return }
            self.replaceOldKeyModal(with: viewController, in: parent)
            if activatingApp {
                NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
        }
    }

    func presentKeyModalOnActiveScreen(viewController: NSViewController, activatingApp: Bool) {
        executeOnUIThread {
            let window = NSWindow(contentViewController: viewController)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            let windowController = WindowController(window: window)
            windowController.delegate = self

            let activeScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }

            if let activeScreen {
                window.centerWindow(in: activeScreen)
            }

            if activatingApp {
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                window.makeKeyAndOrderFront(nil)
            }

            self.activeWindowControllers.insert(windowController)
        }
    }

    private func replaceOldKeyModal(with viewController: NSViewController, in parent: NSViewController) {
        closeKeyModalDuplicates(of: viewController, in: parent)
        parent.presentAsModalWindow(viewController)
    }

    private func closeKeyModalDuplicates(of viewController: NSViewController, in parent: NSViewController) {
        parent.presentedViewControllers?.forEach { presented in
            if presented == viewController {
                parent.dismiss(presented)
            }
        }
    }

    func isKeyModalPresent(viewController: NSViewController) -> Bool {
        let parent = mainWindowController?.contentViewController ?? statusMenuWindowController?.contentViewController

        guard let presentedViewControllers = parent?.presentedViewControllers else {
            return false
        }
        return presentedViewControllers.contains {
            type(of: $0) == type(of: viewController)
        }
    }
}

extension WindowServiceImplementation: WindowControllerDelegate {
    func windowCloseRequested(_ sender: WindowController) {
        if let mainWindowController, sender == mainWindowController {
            closeActiveWindows()
            mainWindowController.close()
            NSApp.setActivationPolicy(.accessory)
        } else {
            sender.close()
        }
    }

    func windowWillClose(_ sender: WindowController) {
        activeWindowControllers.remove(sender)
    }
}
