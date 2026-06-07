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
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [
            BirdSpecies.self,
            BirdSpeciesImage.self,
            BirdSession.self,
            SessionSpeciesObservation.self,
        ])
    }
}
