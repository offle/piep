//
//  AppSettings.swift
//  piep
//
//  Created by Codex on 03.06.26.
//

import Foundation

enum AppSettings {
    nonisolated static let confidenceThresholdKey = "confidenceThreshold"
    nonisolated static let defaultConfidenceThreshold = 0.35
    nonisolated static let keepScreenOnWhileRecordingKey = "keepScreenOnWhileRecording"
    nonisolated static let defaultKeepScreenOnWhileRecording = true
    nonisolated static let birdImageMaximumCountKey = "birdImageMaximumCount"
    nonisolated static let defaultBirdImageMaximumCount = 5
    nonisolated static let minimumBirdImageMaximumCount = 1
    nonisolated static let maximumBirdImageMaximumCount = 15
    nonisolated static let iCloudSyncEnabledKey = "iCloudSyncEnabled"
    nonisolated static let defaultICloudSyncEnabled = false
    nonisolated static let audioBandpassEnabledKey = "audioBandpassEnabled"
    nonisolated static let defaultAudioBandpassEnabled = true
    nonisolated static let audioHighpassCutoffHzKey = "audioHighpassCutoffHz"
    nonisolated static let defaultAudioHighpassCutoffHz = 200.0
    nonisolated static let audioLowpassCutoffHzKey = "audioLowpassCutoffHz"
    nonisolated static let defaultAudioLowpassCutoffHz = 10_000.0
    nonisolated static let audioBandEnergyGateEnabledKey = "audioBandEnergyGateEnabled"
    nonisolated static let defaultAudioBandEnergyGateEnabled = false
    nonisolated static let audioMinimumBandRMSKey = "audioMinimumBandRMS"
    nonisolated static let defaultAudioMinimumBandRMS = 0.0008
    nonisolated static let audioProfileCount = 3

    nonisolated static var confidenceThreshold: Float {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: confidenceThresholdKey) != nil else {
            return Float(defaultConfidenceThreshold)
        }

        return Float(defaults.double(forKey: confidenceThresholdKey))
    }

    nonisolated static var keepScreenOnWhileRecording: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: keepScreenOnWhileRecordingKey) != nil else {
            return defaultKeepScreenOnWhileRecording
        }

        return defaults.bool(forKey: keepScreenOnWhileRecordingKey)
    }

    nonisolated static var birdImageMaximumCount: Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: birdImageMaximumCountKey) != nil else {
            return defaultBirdImageMaximumCount
        }

        return min(
            maximumBirdImageMaximumCount,
            max(minimumBirdImageMaximumCount, defaults.integer(forKey: birdImageMaximumCountKey))
        )
    }

    nonisolated static var iCloudSyncEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: iCloudSyncEnabledKey) != nil else {
            return defaultICloudSyncEnabled
        }

        return defaults.bool(forKey: iCloudSyncEnabledKey)
    }

    nonisolated static var audioPreprocessingSettings: AudioPreprocessingSettings {
        audioPreprocessingSettings(profileIndex: 1)
    }

    nonisolated static var enabledAudioProfileIndices: [Int] {
        (1...audioProfileCount).filter { audioProfileEnabled(profileIndex: $0) }
    }

    nonisolated static var audioAnalysisProfiles: [AudioAnalysisProfile] {
        enabledAudioProfileIndices.map {
                AudioAnalysisProfile(
                    label: audioProfileLabel(profileIndex: $0),
                    settings: audioPreprocessingSettings(profileIndex: $0)
                )
            }
    }

    nonisolated static func audioProfileLabel(profileIndex: Int) -> String {
        "Profil \(profileIndex)"
    }

    nonisolated static func audioProfileEnabledKey(profileIndex: Int) -> String {
        profileKey("enabled", profileIndex: profileIndex)
    }

    nonisolated static func audioBandpassEnabledKey(profileIndex: Int) -> String {
        profileIndex == 1
            ? audioBandpassEnabledKey
            : profileKey("bandpassEnabled", profileIndex: profileIndex)
    }

    nonisolated static func audioHighpassCutoffHzKey(profileIndex: Int) -> String {
        profileIndex == 1
            ? audioHighpassCutoffHzKey
            : profileKey("highpassCutoffHz", profileIndex: profileIndex)
    }

    nonisolated static func audioLowpassCutoffHzKey(profileIndex: Int) -> String {
        profileIndex == 1
            ? audioLowpassCutoffHzKey
            : profileKey("lowpassCutoffHz", profileIndex: profileIndex)
    }

    nonisolated static func audioBandEnergyGateEnabledKey(profileIndex: Int) -> String {
        profileIndex == 1
            ? audioBandEnergyGateEnabledKey
            : profileKey("bandEnergyGateEnabled", profileIndex: profileIndex)
    }

    nonisolated static func audioMinimumBandRMSKey(profileIndex: Int) -> String {
        profileIndex == 1
            ? audioMinimumBandRMSKey
            : profileKey("minimumBandRMS", profileIndex: profileIndex)
    }

    nonisolated static func defaultAudioProfileEnabled(profileIndex: Int) -> Bool {
        switch profileIndex {
        case 1, 2, 3:
            return true
        default:
            return false
        }
    }

    nonisolated static func defaultAudioBandpassEnabled(profileIndex: Int) -> Bool {
        defaultAudioBandpassEnabled
    }

    nonisolated static func defaultAudioHighpassCutoffHz(profileIndex: Int) -> Double {
        switch profileIndex {
        case 2:
            return 2_500
        case 3:
            return 50
        default:
            return defaultAudioHighpassCutoffHz
        }
    }

    nonisolated static func defaultAudioLowpassCutoffHz(profileIndex: Int) -> Double {
        switch profileIndex {
        case 2:
            return 16_000
        case 3:
            return 4_500
        default:
            return defaultAudioLowpassCutoffHz
        }
    }

    nonisolated static func defaultAudioBandEnergyGateEnabled(profileIndex: Int) -> Bool {
        defaultAudioBandEnergyGateEnabled
    }

    nonisolated static func defaultAudioMinimumBandRMS(profileIndex: Int) -> Double {
        defaultAudioMinimumBandRMS
    }

    nonisolated static func resetAudioProfileDefaults() {
        let defaults = UserDefaults.standard
        for profileIndex in 1...audioProfileCount {
            defaults.set(
                defaultAudioProfileEnabled(profileIndex: profileIndex),
                forKey: audioProfileEnabledKey(profileIndex: profileIndex)
            )
            defaults.set(
                defaultAudioBandpassEnabled(profileIndex: profileIndex),
                forKey: audioBandpassEnabledKey(profileIndex: profileIndex)
            )
            defaults.set(
                defaultAudioHighpassCutoffHz(profileIndex: profileIndex),
                forKey: audioHighpassCutoffHzKey(profileIndex: profileIndex)
            )
            defaults.set(
                defaultAudioLowpassCutoffHz(profileIndex: profileIndex),
                forKey: audioLowpassCutoffHzKey(profileIndex: profileIndex)
            )
            defaults.set(
                defaultAudioBandEnergyGateEnabled(profileIndex: profileIndex),
                forKey: audioBandEnergyGateEnabledKey(profileIndex: profileIndex)
            )
            defaults.set(
                defaultAudioMinimumBandRMS(profileIndex: profileIndex),
                forKey: audioMinimumBandRMSKey(profileIndex: profileIndex)
            )
        }
    }

    nonisolated static func saveAudioPreprocessingSettings(
        _ settings: AudioPreprocessingSettings,
        profileIndex: Int
    ) {
        let defaults = UserDefaults.standard
        defaults.set(
            settings.isBandpassEnabled,
            forKey: audioBandpassEnabledKey(profileIndex: profileIndex)
        )
        defaults.set(
            Double(settings.highpassCutoffHz),
            forKey: audioHighpassCutoffHzKey(profileIndex: profileIndex)
        )
        defaults.set(
            Double(settings.lowpassCutoffHz),
            forKey: audioLowpassCutoffHzKey(profileIndex: profileIndex)
        )
        defaults.set(
            settings.isBandEnergyGateEnabled,
            forKey: audioBandEnergyGateEnabledKey(profileIndex: profileIndex)
        )
        defaults.set(
            Double(settings.minimumBandRMS),
            forKey: audioMinimumBandRMSKey(profileIndex: profileIndex)
        )
    }

    nonisolated static func audioPreprocessingSettings(
        profileIndex: Int
    ) -> AudioPreprocessingSettings {
        let defaults = UserDefaults.standard
        return AudioPreprocessingSettings(
            isBandpassEnabled: boolValue(
                forKey: audioBandpassEnabledKey(profileIndex: profileIndex),
                defaultValue: defaultAudioBandpassEnabled(profileIndex: profileIndex),
                defaults: defaults
            ),
            highpassCutoffHz: floatValue(
                forKey: audioHighpassCutoffHzKey(profileIndex: profileIndex),
                defaultValue: defaultAudioHighpassCutoffHz(profileIndex: profileIndex),
                defaults: defaults
            ),
            lowpassCutoffHz: floatValue(
                forKey: audioLowpassCutoffHzKey(profileIndex: profileIndex),
                defaultValue: defaultAudioLowpassCutoffHz(profileIndex: profileIndex),
                defaults: defaults
            ),
            isBandEnergyGateEnabled: boolValue(
                forKey: audioBandEnergyGateEnabledKey(profileIndex: profileIndex),
                defaultValue: defaultAudioBandEnergyGateEnabled(profileIndex: profileIndex),
                defaults: defaults
            ),
            minimumBandRMS: floatValue(
                forKey: audioMinimumBandRMSKey(profileIndex: profileIndex),
                defaultValue: defaultAudioMinimumBandRMS(profileIndex: profileIndex),
                defaults: defaults
            )
        )
    }

    nonisolated private static func audioProfileEnabled(profileIndex: Int) -> Bool {
        boolValue(
            forKey: audioProfileEnabledKey(profileIndex: profileIndex),
            defaultValue: defaultAudioProfileEnabled(profileIndex: profileIndex),
            defaults: UserDefaults.standard
        )
    }

    nonisolated private static func profileKey(
        _ suffix: String,
        profileIndex: Int
    ) -> String {
        "audioProfile\(profileIndex)\(suffix.prefix(1).uppercased())\(String(suffix.dropFirst()))"
    }

    nonisolated private static func boolValue(
        forKey key: String,
        defaultValue: Bool,
        defaults: UserDefaults
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    nonisolated private static func floatValue(
        forKey key: String,
        defaultValue: Double,
        defaults: UserDefaults
    ) -> Float {
        guard defaults.object(forKey: key) != nil else {
            return Float(defaultValue)
        }

        return Float(defaults.double(forKey: key))
    }
}
