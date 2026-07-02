import Foundation

nonisolated struct WatchAnalyzedWindow: Sendable {
    let startSeconds: TimeInterval
    let detections: [BirdDetection]
}

enum WatchRecordingAnalyzer {

    nonisolated static func analyze(
        samples: [Float],
        profiles: [AudioAnalysisProfile],
        confidenceThreshold: Float,
        classify: ([Float]) -> [BirdDetection]
    ) -> [WatchAnalyzedWindow] {
        ExpertBenchmarkProcessor.analysisWindows(from: samples).map { window in
            var candidates: [BirdDetection] = []
            for profile in profiles {
                let preprocessing = AudioPreprocessor.process(
                    window.samples,
                    settings: profile.settings
                )
                guard preprocessing.shouldAnalyze else { continue }
                candidates.append(contentsOf: classify(preprocessing.samples))
            }

            return WatchAnalyzedWindow(
                startSeconds: window.startSeconds,
                detections: mergedDetectionsByBestConfidence(candidates).filter {
                    $0.confidence >= confidenceThreshold
                        && !$0.isExcludedHumanSound
                }
            )
        }
    }

    nonisolated private static func mergedDetectionsByBestConfidence(
        _ detections: [BirdDetection]
    ) -> [BirdDetection] {
        var bestBySpecies: [String: BirdDetection] = [:]
        for detection in detections {
            if let existing = bestBySpecies[detection.scientificName],
               existing.confidence >= detection.confidence
            {
                continue
            }
            bestBySpecies[detection.scientificName] = detection
        }
        return bestBySpecies.values.sorted { $0.confidence > $1.confidence }
    }
}
