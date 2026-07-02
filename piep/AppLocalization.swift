import Foundation

enum AppLocalization {
    nonisolated static var languageCode: String {
        let stored = UserDefaults.standard.string(forKey: AppSettings.appLanguageKey)
        return stored == "en" ? "en" : "de"
    }

    nonisolated static var locale: Locale {
        Locale(identifier: languageCode)
    }

    nonisolated static func text(_ key: String) -> String {
        guard languageCode != "de",
              let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            return key
        }

        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    nonisolated static func text(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }
}

enum BirdNameLocalization {
    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedLabels: [String: [String: String]] = [:]

    nonisolated static func commonName(
        scientificName: String,
        fallback: String
    ) -> String {
        labels(for: AppLocalization.languageCode)[scientificName] ?? fallback
    }

    nonisolated static var speechLanguage: String {
        AppLocalization.languageCode == "en" ? "en-US" : "de-DE"
    }

    nonisolated private static func labels(for languageCode: String) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cachedLabels[languageCode] {
            return cached
        }

        let filename = languageCode == "en" ? "en_us" : "de"
        let path = Bundle.main.path(
            forResource: filename,
            ofType: "txt",
            inDirectory: "BirdNET_v2/labels"
        ) ?? Bundle.main.path(
            forResource: filename,
            ofType: "txt",
            inDirectory: "labels"
        ) ?? Bundle.main.path(forResource: filename, ofType: "txt")

        guard let path,
              let content = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            cachedLabels[languageCode] = [:]
            return [:]
        }

        let labels = Dictionary(
            uniqueKeysWithValues: content
                .components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
                .map { line in
                    let parts = line.split(separator: "_", maxSplits: 1)
                    let scientificName = String(parts[0])
                    let commonName = parts.count > 1 ? String(parts[1]) : scientificName
                    return (scientificName, commonName)
                }
        )
        cachedLabels[languageCode] = labels
        return labels
    }
}

extension BirdSpecies {
    var localizedCommonName: String {
        BirdNameLocalization.commonName(
            scientificName: scientificName,
            fallback: germanName
        )
    }
}

extension SessionSpeciesObservation {
    var localizedCommonName: String {
        BirdNameLocalization.commonName(
            scientificName: scientificName,
            fallback: germanName
        )
    }
}

extension BirdDetection {
    var localizedCommonName: String {
        BirdNameLocalization.commonName(
            scientificName: scientificName,
            fallback: germanName
        )
    }
}

extension BirdMapObservation {
    var localizedCommonName: String {
        BirdNameLocalization.commonName(
            scientificName: scientificName,
            fallback: germanName
        )
    }
}

extension RawBirdDetectionSummary {
    var localizedCommonName: String {
        BirdNameLocalization.commonName(
            scientificName: scientificName,
            fallback: germanName
        )
    }
}

extension RawProfileTopDetection {
    var localizedCommonName: String {
        BirdNameLocalization.commonName(
            scientificName: scientificName,
            fallback: germanName
        )
    }
}

extension ExpertBenchmarkDetectionResult {
    var localizedCommonName: String {
        BirdNameLocalization.commonName(
            scientificName: scientificName,
            fallback: germanName
        )
    }
}

extension ExpertBenchmarkProfileComparisonRow {
    var localizedCommonName: String {
        BirdNameLocalization.commonName(
            scientificName: scientificName,
            fallback: germanName
        )
    }
}

extension BirdSpeciesSummary {
    var localizedCommonName: String {
        BirdNameLocalization.commonName(
            scientificName: scientificName,
            fallback: germanName
        )
    }
}

extension BirdImageLicenseEntry {
    var localizedCommonName: String {
        BirdNameLocalization.commonName(
            scientificName: scientificName,
            fallback: germanName
        )
    }
}
