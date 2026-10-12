//
//  KeychainConstants.swift
//  Core
//
//  Created by Jaroslav on 2021-06-22.
//  Copyright © 2021 Proton Technologies AG. All rights reserved.
//

import Foundation

public class KeychainConstants {
    // 공식 Proton VPN 앱의 키체인 항목(로그인 정보)과 섞이지 않도록 macOS에서는 별도 이름을 씀
    #if os(macOS)
        public static let appKeychain = "app.prtvpn.mac"
    #else
        public static let appKeychain = "ProtonVPN"
    #endif
}
