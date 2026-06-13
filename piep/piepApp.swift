//
//  piepApp.swift
//  piep
//
//  Created by Ole on 02.06.26.
//

import SwiftUI
import SwiftData

@main
struct piepApp: App {
    @AppStorage(AppSettings.iCloudSyncEnabledKey)
    private var isCloudSyncEnabled = AppSettings.defaultICloudSyncEnabled

    var body: some Scene {
        WindowGroup {
            ContentView()
                .id(isCloudSyncEnabled)
        }
        .modelContainer(PiepModelContainer.make(isCloudSyncEnabled: isCloudSyncEnabled))
    }
}
