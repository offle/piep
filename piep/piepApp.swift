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

    @AppStorage(AppSettings.appLanguageKey)
    private var appLanguage = AppSettings.defaultAppLanguage

    private let modelContainer: ModelContainer = {
        let schema = Schema([
            BirdSpecies.self,
            BirdSpeciesImage.self,
            BirdSession.self,
            SessionSpeciesObservation.self,
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            groupContainer: .none,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(
                for: schema,
                configurations: [configuration]
            )
        } catch {
            fatalError("Could not create local SwiftData container: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, Locale(identifier: appLanguage))
        }
        .modelContainer(modelContainer)
    }
}
