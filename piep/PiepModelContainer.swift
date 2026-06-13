//
//  PiepModelContainer.swift
//  piep
//
//  Created by Codex on 13.06.26.
//

import Foundation
import SwiftData

enum PiepModelContainer {
    static let cloudKitContainerIdentifier = "iCloud.org.offlepoffle1.piep"

    private static let syncSchema = Schema([
        BirdSpecies.self,
        BirdSession.self,
        SessionSpeciesObservation.self,
    ])

    private static let localImageSchema = Schema([
        BirdSpeciesImage.self,
    ])

    private static let fullSchema = Schema([
        BirdSpecies.self,
        BirdSpeciesImage.self,
        BirdSession.self,
        SessionSpeciesObservation.self,
    ])

    @MainActor
    static func make(isCloudSyncEnabled: Bool) -> ModelContainer {
        do {
            let syncConfiguration = ModelConfiguration(
                isCloudSyncEnabled ? "CloudData" : "LocalData",
                schema: syncSchema,
                cloudKitDatabase: isCloudSyncEnabled
                    ? .private(cloudKitContainerIdentifier)
                    : .none
            )
            let localImageConfiguration = ModelConfiguration(
                "LocalImages",
                schema: localImageSchema,
                cloudKitDatabase: .none
            )
            return try ModelContainer(
                for: fullSchema,
                configurations: syncConfiguration,
                localImageConfiguration
            )
        } catch {
            fatalError("SwiftData container could not be created: \(error)")
        }
    }
}
