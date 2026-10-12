//
//  OsxUiAlertService.swift
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
import Domain
import Ergonomics
import Foundation
import LegacyCommon
import VPNAppCore

protocol UIAlertServiceFactory {
    func makeUIAlertService() -> UIAlertService
}

final class OsxUiAlertService: UIAlertService {
    typealias Factory = NavigationServiceFactory & WindowServiceFactory

    private let factory: Factory
    private let windowService: WindowService

    private lazy var navigationService: NavigationService = factory.makeNavigationService()

    private var currentAlerts = [SystemAlert]()

    public init(factory: Factory) {
        self.factory = factory
        self.windowService = factory.makeWindowService()
    }

    func displayAlert(_ alert: SystemAlert) {
        present(alert)
    }

    func displayNotificationStyleAlert(message _: String, type _: NotificationStyleAlertType, accessibilityIdentifier _: String?) {
        fatalError("Notification syle alerts unsupported on macOS")
    }

    private func present(_ alert: SystemAlert) {
        guard alertIsNew(alert) else {
            updateOldAlert(with: alert)
            return
        }

        currentAlerts.append(alert)

        let modalVC: NSViewController

        switch alert {
        case let userAccountUpdateAlert as UserAccountUpdateAlert:
            let userUpdateVC = UserAccountUpdateViewController(alert: userAccountUpdateAlert)
            alert.dismiss = { [weak self] in self?.dismissCompletion(alert) }
            modalVC = userUpdateVC
        case let expandableSystemAlert as ExpandableSystemAlert:
            let expandableViewModel = ExpandablePopupViewModel(expandableSystemAlert)
            expandableViewModel.dismissViewController = { [weak self] in self?.dismissCompletion(alert) }
            alert.dismiss = { [weak expandableViewModel] in expandableViewModel?.close() }
            modalVC = ExpandableContentPopupViewController(viewModel: expandableViewModel)
        default:
            // 제목, 본문, 버튼뿐인 일반 알림은 직접 그린 팝업 대신 시스템 알림으로 보여 줌
            if alert.canDismissAutomaticallyOnConnection {
                AppEvent.appStateManagerDisplayStateChange.unsubscribe(self)
                AppEvent.appStateManagerDisplayStateChange.subscribe(self, selector: #selector(appDisplayStateChanged))
            }
            presentNative(alert)
            return
        }

        if alert.displayOnActiveScreen, UserDefaults.standard.bool(forKey: AppConstants.UserDefaults.displayAlertsOnActiveScreen) {
            windowService.presentKeyModalOnActiveScreen(viewController: modalVC, activatingApp: alert.activatingApp)
        } else {
            windowService.presentKeyModal(viewController: modalVC, activatingApp: alert.activatingApp)
        }
    }

    /// 시스템 알림(NSAlert)으로 보여 줌. 메인 창이 보이면 그 창의 시트로, 아니면 독립된 알림 창으로 띄움.
    private func presentNative(_ alert: SystemAlert) {
        executeOnUIThread { [weak self] in
            guard let self else { return }
            let nsAlert = NSAlert()
            nsAlert.alertStyle = alert.isError ? .warning : .informational
            if let title = alert.title, !title.isEmpty {
                nsAlert.messageText = title
                nsAlert.informativeText = alert.message ?? ""
            } else {
                nsAlert.messageText = alert.message ?? ""
            }
            for action in alert.actions {
                let button = nsAlert.addButton(withTitle: action.title)
                switch action.style {
                case .destructive: button.hasDestructiveAction = true
                case .cancel: button.keyEquivalent = "\u{1b}"
                case .confirmative, .secondary: break
                }
            }

            // 같은 알림이 다시 들어오면 동작만 바뀔 수 있으므로, 버튼을 눌렀을 때의 동작을 그때 읽음
            let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                self?.dismissCompletion(alert)
                let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                guard alert.actions.indices.contains(index) else { return }
                alert.actions[index].handler?()
            }

            let parent = NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.attachedSheet == nil && !($0 is NSPanel) }
            if let parent {
                alert.dismiss = { [weak parent, weak nsAlert] in
                    guard let parent, let sheet = nsAlert?.window, parent.attachedSheet == sheet else { return }
                    // 버튼 번호가 아닌 값으로 닫아 어떤 동작도 실행되지 않게 함
                    parent.endSheet(sheet, returnCode: .abort)
                }
                if alert.activatingApp {
                    NSRunningApplication.current.activate(options: [.activateAllWindows])
                }
                nsAlert.beginSheetModal(for: parent, completionHandler: finish)
            } else {
                alert.dismiss = { NSApp.abortModal() }
                NSApp.activate(ignoringOtherApps: true)
                finish(nsAlert.runModal())
            }
        }
    }

    @objc
    private func appDisplayStateChanged(_ notification: Notification) {
        defer { AppEvent.appStateManagerDisplayStateChange.unsubscribe(self) }
        guard let appDisplayStateChanged = notification.object as? AppDisplayState, case .connected = appDisplayStateChanged else { return }
        currentAlerts.removeAll { alert in
            if alert.canDismissAutomaticallyOnConnection {
                alert.dismiss?()
                return true
            }
            return false
        }
    }

    private func alertIsNew(_ alert: SystemAlert) -> Bool {
        !currentAlerts.contains(where: { currentAlert -> Bool in
            return currentAlert.className == alert.className
        })
    }

    private func updateOldAlert(with newAlert: SystemAlert) {
        let oldAlert = currentAlerts.first { alert -> Bool in
            return alert.className == newAlert.className
        }

        // In particular this means the alert's completion handlers will be updated
        oldAlert?.actions = newAlert.actions
    }

    private func dismissCompletion(_ alert: SystemAlert) {
        currentAlerts.removeAll { currentAlert in
            currentAlert.className == alert.className
        }
    }
}
