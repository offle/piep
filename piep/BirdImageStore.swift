//
//  BirdImageStore.swift
//  piep
//
//  Created by Codex on 03.06.26.
//

import Foundation
import Observation
import UIKit

struct BirdImageDebugEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
}

struct CachedBirdImageInfo: Codable {
    let metadataVersion: Int
    let scientificName: String
    let title: String
    let credit: String
    let license: String
    let sourceURL: URL
    let fileName: String
}

@MainActor
@Observable
final class BirdImageStore {

    static let shared = BirdImageStore()

    private(set) var imageDebugEntries: [BirdImageDebugEntry] = []

    private static let metadataVersion = 2
    private let fileManager = FileManager.default
    private let session: URLSession
    private var inFlightTasks: [String: Task<CachedBirdImageInfo?, Never>] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    func image(for scientificName: String) async -> (image: UIImage, info: CachedBirdImageInfo)? {
        if let cached = cachedInfo(for: scientificName), let cachedUIImage = cachedImage(for: cached) {
            guard Self.isLikelyRealPhoto(
                title: cached.title,
                credit: cached.credit,
                sourceURL: cached.sourceURL
            ) else {
                log("Cache ignoriert, kein reales Foto: \(scientificName) -> \(cached.title)")
                removeCachedImage(for: cached)
                return await self.image(for: scientificName)
            }

            log("Cache-Hit: \(scientificName) -> \(cached.title)")
            return (cachedUIImage, cached)
        }

        let info: CachedBirdImageInfo?
        if let task = inFlightTasks[scientificName] {
            log("Warte auf laufenden Bildabruf: \(scientificName)")
            info = await task.value
        } else {
            log("Starte Bildabruf: \(scientificName)")
            let task = Task { [weak self] in
                await self?.fetchAndCacheImage(for: scientificName)
            }
            inFlightTasks[scientificName] = task
            info = await task.value
            inFlightTasks[scientificName] = nil
        }

        guard let info, let image = cachedImage(for: info) else {
            log("Kein Bild verfügbar: \(scientificName)")
            return nil
        }

        log("Bild geladen: \(scientificName) -> \(info.title)")
        return (image, info)
    }

    func images(for scientificName: String, maximumCount: Int) async -> [(image: UIImage, info: CachedBirdImageInfo)] {
        let limit = max(1, maximumCount)

        let cachedGallery = cachedGalleryInfo(for: scientificName)
            .filter {
                Self.isLikelyRealPhoto(
                    title: $0.title,
                    credit: $0.credit,
                    sourceURL: $0.sourceURL
                )
            }
            .compactMap { info -> (image: UIImage, info: CachedBirdImageInfo)? in
                guard let image = cachedImage(for: info) else {
                    return nil
                }

                return (image, info)
            }

        if cachedGallery.count >= limit {
            log("Galerie Cache-Hit: \(scientificName), \(cachedGallery.count) Bilder")
            return Array(cachedGallery.prefix(limit))
        }

        let firstAvailableImage: (image: UIImage, info: CachedBirdImageInfo)?
        if let cachedFirst = cachedGallery.first {
            firstAvailableImage = cachedFirst
        } else {
            firstAvailableImage = await image(for: scientificName)
        }

        if let first = firstAvailableImage {
            let downloaded = await fetchAndCacheImageGallery(
                for: scientificName,
                maximumCount: limit,
                fallbackFirstImage: first
            )
            if !downloaded.isEmpty {
                return Array(downloaded.prefix(limit))
            }

            return [first]
        }

        let downloaded = await fetchAndCacheImageGallery(
            for: scientificName,
            maximumCount: limit,
            fallbackFirstImage: nil
        )
        return Array(downloaded.prefix(limit))
    }

    func noteBundledImageUsed(for scientificName: String) {
        log("Gebündeltes Bild verwendet: \(scientificName)")
    }

    func clearImageCache() {
        inFlightTasks.removeAll()
        try? fileManager.removeItem(at: imageDirectory)
        log("Bildercache gelöscht")
    }

    func clearDebugLog() {
        imageDebugEntries.removeAll()
    }

    func cachedInfo(for scientificName: String) -> CachedBirdImageInfo? {
        guard let data = try? Data(contentsOf: metadataURL(for: scientificName)) else {
            return nil
        }

        guard
            let info = try? JSONDecoder().decode(CachedBirdImageInfo.self, from: data),
            info.metadataVersion == Self.metadataVersion
        else {
            return nil
        }

        return info
    }

    private func cachedGalleryInfo(for scientificName: String) -> [CachedBirdImageInfo] {
        guard let data = try? Data(contentsOf: galleryMetadataURL(for: scientificName)) else {
            return []
        }

        let infos = (try? JSONDecoder().decode([CachedBirdImageInfo].self, from: data)) ?? []
        return infos.filter { $0.metadataVersion == Self.metadataVersion }
    }

    private func cachedImage(for info: CachedBirdImageInfo) -> UIImage? {
        let url = imageDirectory.appendingPathComponent(info.fileName)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        return UIImage(data: data)
    }

    private func removeCachedImage(for info: CachedBirdImageInfo) {
        try? fileManager.removeItem(at: imageDirectory.appendingPathComponent(info.fileName))
        try? fileManager.removeItem(at: metadataURL(for: info.scientificName))
    }

    private func fetchAndCacheImage(for scientificName: String) async -> CachedBirdImageInfo? {
        guard let candidate = await findFreeCommonsImage(for: scientificName) else {
            log("Keine freie Commons-Kandidatin gefunden: \(scientificName)")
            return nil
        }

        do {
            log("Download: \(scientificName) <- \(candidate.title)")
            var request = URLRequest(url: candidate.downloadURL)
            request.setValue("piep/1.0 (iOS bird image cache)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                log("Download ohne HTTP-Antwort: \(scientificName)")
                return nil
            }

            guard 200..<300 ~= httpResponse.statusCode else {
                log("Download HTTP \(httpResponse.statusCode): \(scientificName)")
                return nil
            }

            guard UIImage(data: data) != nil else {
                log("Download ist kein lesbares Bild: \(scientificName), \(data.count) Bytes")
                return nil
            }

            try fileManager.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
            let fileName = "\(Self.slug(for: scientificName)).jpg"
            try data.write(to: imageDirectory.appendingPathComponent(fileName), options: .atomic)

            let info = CachedBirdImageInfo(
                metadataVersion: Self.metadataVersion,
                scientificName: scientificName,
                title: candidate.title,
                credit: candidate.credit,
                license: candidate.license,
                sourceURL: candidate.sourceURL,
                fileName: fileName
            )
            let metadataData = try JSONEncoder().encode(info)
            try metadataData.write(to: metadataURL(for: scientificName), options: .atomic)
            log("Gespeichert: \(scientificName) -> \(fileName), Lizenz \(candidate.license)")
            return info
        } catch {
            log("Bildabruf Fehler: \(scientificName) -> \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchAndCacheImageGallery(
        for scientificName: String,
        maximumCount: Int,
        fallbackFirstImage: (image: UIImage, info: CachedBirdImageInfo)?
    ) async -> [(image: UIImage, info: CachedBirdImageInfo)] {
        let candidates = await findFreeCommonsImages(
            for: scientificName,
            maximumCount: maximumCount
        )

        var results: [(image: UIImage, info: CachedBirdImageInfo)] = []
        var metadata: [CachedBirdImageInfo] = []
        var seenSources = Set<URL>()

        if let fallbackFirstImage {
            results.append(fallbackFirstImage)
            metadata.append(fallbackFirstImage.info)
            seenSources.insert(fallbackFirstImage.info.sourceURL)
        }

        do {
            try fileManager.createDirectory(at: imageDirectory, withIntermediateDirectories: true)

            for candidate in candidates where results.count < maximumCount {
                guard seenSources.insert(candidate.sourceURL).inserted else {
                    continue
                }

                var request = URLRequest(url: candidate.downloadURL)
                request.setValue("piep/1.0 (iOS bird image gallery cache)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await session.data(for: request)
                guard
                    let httpResponse = response as? HTTPURLResponse,
                    200..<300 ~= httpResponse.statusCode,
                    let image = UIImage(data: data)
                else {
                    log("Galerie Download übersprungen: \(scientificName) -> \(candidate.title)")
                    continue
                }

                let fileName = "\(Self.slug(for: scientificName))-\(results.count).jpg"
                try data.write(to: imageDirectory.appendingPathComponent(fileName), options: .atomic)

                let info = CachedBirdImageInfo(
                    metadataVersion: Self.metadataVersion,
                    scientificName: scientificName,
                    title: candidate.title,
                    credit: candidate.credit,
                    license: candidate.license,
                    sourceURL: candidate.sourceURL,
                    fileName: fileName
                )
                results.append((image, info))
                metadata.append(info)
            }

            if !metadata.isEmpty {
                let metadataData = try JSONEncoder().encode(metadata)
                try metadataData.write(to: galleryMetadataURL(for: scientificName), options: .atomic)
            }

            log("Galerie gespeichert: \(scientificName), \(results.count) Bilder")
            return results
        } catch {
            log("Galerie Fehler: \(scientificName) -> \(error.localizedDescription)")
            return results
        }
    }

    private func findFreeCommonsImage(for scientificName: String) async -> CommonsImageCandidate? {
        log("Suche Commons/Wikidata: \(scientificName)")
        for searchName in Self.searchNames(for: scientificName) {
            if let candidate = await searchCommonsCategory(for: scientificName, categoryName: searchName) {
                log("Kategorie-Treffer: \(scientificName) -> \(candidate.title)")
                return candidate
            }
        }

        for searchName in Self.searchNames(for: scientificName) {
            if let candidate = await searchWikidataImage(for: scientificName, taxonName: searchName) {
                log("Wikidata-Treffer: \(scientificName) -> \(candidate.title)")
                return candidate
            }
        }

        for searchName in Self.searchNames(for: scientificName) {
            let quotedSearchName = "\"\(searchName)\""
            if let candidate = await searchCommonsImage(for: scientificName, searchTerm: quotedSearchName) {
                log("Commons-Suche Treffer: \(scientificName) -> \(candidate.title)")
                return candidate
            }

            if let candidate = await searchCommonsImage(for: scientificName, searchTerm: searchName) {
                log("Commons-Suche Treffer: \(scientificName) -> \(candidate.title)")
                return candidate
            }
        }

        log("Suche ohne Treffer: \(scientificName)")
        return nil
    }

    private func findFreeCommonsImages(
        for scientificName: String,
        maximumCount: Int
    ) async -> [CommonsImageCandidate] {
        log("Suche Commons-Galerie: \(scientificName)")
        var candidates: [CommonsImageCandidate] = []
        var seenSources = Set<URL>()

        func append(_ newCandidates: [CommonsImageCandidate]) {
            for candidate in newCandidates.sorted(by: { $0.relevanceScore > $1.relevanceScore }) {
                guard seenSources.insert(candidate.sourceURL).inserted else {
                    continue
                }

                candidates.append(candidate)
            }
        }

        for searchName in Self.searchNames(for: scientificName) {
            append(await searchCommonsCategoryCandidates(for: scientificName, categoryName: searchName))
            if candidates.count >= maximumCount {
                break
            }
        }

        for searchName in Self.searchNames(for: scientificName) where candidates.count < maximumCount {
            append(await searchCommonsImageCandidates(for: scientificName, searchTerm: "\"\(searchName)\""))
            append(await searchCommonsImageCandidates(for: scientificName, searchTerm: searchName))
        }

        let sortedCandidates = candidates.sorted {
            if $0.relevanceScore != $1.relevanceScore {
                return $0.relevanceScore > $1.relevanceScore
            }

            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        log("Commons-Galerie Ergebnis: \(scientificName), \(sortedCandidates.count) Kandidaten")
        return Array(sortedCandidates.prefix(maximumCount))
    }

    private func searchCommonsCategory(for scientificName: String, categoryName: String) async -> CommonsImageCandidate? {
        await searchCommonsCategoryCandidates(for: scientificName, categoryName: categoryName).first
    }

    private func searchCommonsCategoryCandidates(
        for scientificName: String,
        categoryName: String
    ) async -> [CommonsImageCandidate] {
        guard var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php") else {
            return []
        }

        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "generator", value: "categorymembers"),
            URLQueryItem(name: "gcmtitle", value: "Category:\(categoryName)"),
            URLQueryItem(name: "gcmtype", value: "file"),
            URLQueryItem(name: "gcmlimit", value: "50"),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|extmetadata|mime|size"),
            URLQueryItem(name: "iiurlwidth", value: "640"),
        ]

        guard let url = components.url else {
            log("Kategorie-URL ungültig: \(categoryName)")
            return []
        }

        do {
            log("Kategorie suche: \(categoryName)")
            var request = URLRequest(url: url)
            request.setValue("piep/1.0 (iOS bird image cache)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                log("Kategorie ohne HTTP-Antwort: \(categoryName)")
                return []
            }

            guard 200..<300 ~= httpResponse.statusCode else {
                log("Kategorie HTTP \(httpResponse.statusCode): \(categoryName)")
                return []
            }

            let responseBody = try JSONDecoder().decode(CommonsSearchResponse.self, from: data)
            let pages = responseBody.query?.pages.map { Array($0.values) } ?? []
            let candidates = pages.compactMap {
                CommonsImageCandidate(
                    page: $0,
                    scientificNames: Self.searchNames(for: scientificName),
                    requiresScientificNameMatch: false
                )
            }
            log("Kategorie Ergebnis: \(categoryName), Seiten \(pages.count), Kandidaten \(candidates.count)")
            return candidates.sorted { $0.relevanceScore > $1.relevanceScore }
        } catch {
            log("Kategorie Fehler: \(categoryName) -> \(error.localizedDescription)")
            return []
        }
    }

    private func searchWikidataImage(for scientificName: String, taxonName: String) async -> CommonsImageCandidate? {
        guard var components = URLComponents(string: "https://query.wikidata.org/sparql") else {
            return nil
        }

        let escapedTaxonName = taxonName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let query = """
        SELECT ?image WHERE {
          ?taxon wdt:P225 "\(escapedTaxonName)";
                 wdt:P18 ?image.
        }
        LIMIT 1
        """
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "query", value: query),
        ]

        guard let url = components.url else {
            log("Wikidata-URL ungültig: \(taxonName)")
            return nil
        }

        do {
            log("Wikidata suche: \(taxonName)")
            var request = URLRequest(url: url)
            request.setValue("piep/1.0 (iOS bird image cache)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                log("Wikidata ohne HTTP-Antwort: \(taxonName)")
                return nil
            }

            guard 200..<300 ~= httpResponse.statusCode else {
                log("Wikidata HTTP \(httpResponse.statusCode): \(taxonName)")
                return nil
            }

            let responseBody = try JSONDecoder().decode(WikidataImageResponse.self, from: data)
            guard
                let imageURLString = responseBody.results.bindings.first?.image.value,
                let fileName = Self.commonsFileName(from: imageURLString)
            else {
                log("Wikidata ohne P18-Bild: \(taxonName)")
                return nil
            }

            log("Wikidata Bilddatei: \(taxonName) -> \(fileName)")
            return await commonsImageInfo(
                forFileName: fileName,
                scientificName: scientificName,
                requiresScientificNameMatch: false
            )
        } catch {
            log("Wikidata Fehler: \(taxonName) -> \(error.localizedDescription)")
            return nil
        }
    }

    private func commonsImageInfo(
        forFileName fileName: String,
        scientificName: String,
        requiresScientificNameMatch: Bool
    ) async -> CommonsImageCandidate? {
        guard var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php") else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "titles", value: "File:\(fileName)"),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|extmetadata|mime|size"),
            URLQueryItem(name: "iiurlwidth", value: "640"),
        ]

        guard let url = components.url else {
            log("Commons-Datei-URL ungültig: \(fileName)")
            return nil
        }

        do {
            log("Commons Dateiinfo: \(fileName)")
            var request = URLRequest(url: url)
            request.setValue("piep/1.0 (iOS bird image cache)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                log("Commons Dateiinfo ohne HTTP-Antwort: \(fileName)")
                return nil
            }

            guard 200..<300 ~= httpResponse.statusCode else {
                log("Commons Dateiinfo HTTP \(httpResponse.statusCode): \(fileName)")
                return nil
            }

            let responseBody = try JSONDecoder().decode(CommonsSearchResponse.self, from: data)
            let pages = responseBody.query?.pages.map { Array($0.values) } ?? []
            let candidates = pages.compactMap {
                CommonsImageCandidate(
                    page: $0,
                    scientificNames: Self.searchNames(for: scientificName),
                    requiresScientificNameMatch: requiresScientificNameMatch
                )
            }
            log("Commons Dateiinfo Ergebnis: \(fileName), Seiten \(pages.count), Kandidaten \(candidates.count)")
            return candidates.first
        } catch {
            log("Commons Dateiinfo Fehler: \(fileName) -> \(error.localizedDescription)")
            return nil
        }
    }

    private func searchCommonsImage(for scientificName: String, searchTerm: String) async -> CommonsImageCandidate? {
        await searchCommonsImageCandidates(for: scientificName, searchTerm: searchTerm).first
    }

    private func searchCommonsImageCandidates(
        for scientificName: String,
        searchTerm: String
    ) async -> [CommonsImageCandidate] {
        guard var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php") else {
            return []
        }

        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrnamespace", value: "6"),
            URLQueryItem(name: "gsrlimit", value: "20"),
            URLQueryItem(name: "gsrsearch", value: searchTerm),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|extmetadata|mime|size"),
            URLQueryItem(name: "iiurlwidth", value: "640"),
        ]

        guard let url = components.url else {
            log("Commons-Such-URL ungültig: \(searchTerm)")
            return []
        }

        do {
            log("Commons Volltextsuche: \(searchTerm)")
            var request = URLRequest(url: url)
            request.setValue("piep/1.0 (iOS bird image cache)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                log("Commons-Suche ohne HTTP-Antwort: \(searchTerm)")
                return []
            }

            guard 200..<300 ~= httpResponse.statusCode else {
                log("Commons-Suche HTTP \(httpResponse.statusCode): \(searchTerm)")
                return []
            }

            let responseBody = try JSONDecoder().decode(CommonsSearchResponse.self, from: data)
            let pages = responseBody.query?.pages.map { Array($0.values) } ?? []
            let candidates = pages.compactMap {
                CommonsImageCandidate(
                    page: $0,
                    scientificNames: Self.searchNames(for: scientificName),
                    requiresScientificNameMatch: true
                )
            }
            log("Commons-Suche Ergebnis: \(searchTerm), Seiten \(pages.count), Kandidaten \(candidates.count)")
            return candidates.sorted { $0.relevanceScore > $1.relevanceScore }
        } catch {
            log("Commons-Suche Fehler: \(searchTerm) -> \(error.localizedDescription)")
            return []
        }
    }

    private func log(_ message: String) {
        imageDebugEntries.insert(
            BirdImageDebugEntry(timestamp: Date(), message: message),
            at: 0
        )

        if imageDebugEntries.count > 120 {
            imageDebugEntries.removeLast(imageDebugEntries.count - 120)
        }
    }

    private static func searchNames(for scientificName: String) -> [String] {
        switch scientificName {
        case "Corvus monedula":
            return ["Corvus monedula", "Coloeus monedula"]
        case "Coloeus monedula":
            return ["Coloeus monedula", "Corvus monedula"]
        default:
            return [scientificName]
        }
    }

    private var imageDirectory: URL {
        let baseURL = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return (baseURL ?? fileManager.temporaryDirectory)
            .appendingPathComponent("BirdImages", isDirectory: true)
    }

    private func metadataURL(for scientificName: String) -> URL {
        imageDirectory.appendingPathComponent("\(Self.slug(for: scientificName)).json")
    }

    private func galleryMetadataURL(for scientificName: String) -> URL {
        imageDirectory.appendingPathComponent("\(Self.slug(for: scientificName))-gallery.json")
    }

    private static func slug(for scientificName: String) -> String {
        scientificName
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }
            .joined()
            .split(separator: "-")
            .joined(separator: "-")
    }

    private static func commonsFileName(from imageURLString: String) -> String? {
        guard
            let url = URL(string: imageURLString),
            let fileName = url.lastPathComponent.removingPercentEncoding,
            !fileName.isEmpty
        else {
            return nil
        }

        return fileName
    }

    private static func isLikelyRealPhoto(
        title: String,
        credit: String,
        sourceURL: URL
    ) -> Bool {
        let text = [
            title,
            credit,
            sourceURL.absoluteString.removingPercentEncoding ?? sourceURL.absoluteString,
        ]
        .joined(separator: " ")
        .lowercased()

        return !containsNonPhotoTerms(text)
    }

    fileprivate static func containsNonPhotoTerms(_ text: String) -> Bool {
        let blockedTerms = [
            "illustration",
            "illustrated",
            "drawing",
            "sketch",
            "artwork",
            "art work",
            "painting",
            "painted",
            "watercolor",
            "watercolour",
            "aquarell",
            "lithograph",
            "chromolithograph",
            "engraving",
            "etching",
            "book plate",
            "plate ",
            " plate",
            "print",
            "hand-coloured",
            "hand-colored",
            "hand coloured",
            "hand colored",
            "nederlandsche vogelen",
            "naturgeschichte",
            "natural history illustration",
            "taxidermy",
            "mounted specimen",
            "museum specimen",
            "skin",
            "skins",
        ]

        return blockedTerms.contains { text.contains($0) }
    }
}

private struct CommonsImageCandidate {
    let title: String
    let credit: String
    let license: String
    let sourceURL: URL
    let downloadURL: URL
    let relevanceScore: Int

    init?(
        page: CommonsSearchResponse.Page,
        scientificNames: [String],
        requiresScientificNameMatch: Bool
    ) {
        guard
            let imageInfo = page.imageinfo?.first,
            let downloadURL = imageInfo.thumburl ?? imageInfo.url,
            let sourceURL = imageInfo.descriptionurl,
            let license = imageInfo.licenseName,
            imageInfo.isSupportedPhoto,
            Self.isFreeLicense(license)
        else {
            return nil
        }

        let title = imageInfo.displayTitle ?? page.title.replacingOccurrences(of: "File:", with: "")
        let credit = imageInfo.artist ?? "Wikimedia Commons"
        let searchableText = [
            page.title,
            imageInfo.displayTitle,
            imageInfo.description,
            imageInfo.categories,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
        let unsuitableText = [
            page.title,
            imageInfo.displayTitle,
            imageInfo.description,
            imageInfo.categories,
            imageInfo.mime,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
        guard !Self.isUnsuitableBirdPhoto(unsuitableText) else {
            return nil
        }
        guard !BirdImageStore.containsNonPhotoTerms(unsuitableText) else {
            return nil
        }

        let matchingName = scientificNames.first {
            searchableText.contains($0.lowercased())
        }

        guard matchingName != nil || !requiresScientificNameMatch else {
            return nil
        }

        let lowercasedTitle = title.lowercased()
        let nameScore: Int
        if let matchingName {
            nameScore = lowercasedTitle.contains(matchingName.lowercased()) ? 4 : 3
        } else {
            nameScore = 2
        }

        self.title = title
        self.credit = credit
        self.license = license
        self.sourceURL = sourceURL
        self.downloadURL = downloadURL
        self.relevanceScore = nameScore
            + (Self.hasPhotoEvidence(searchableText) ? 3 : 0)
            + (searchableText.contains("quality") ? 2 : 0)
            + (searchableText.contains("featured") ? 1 : 0)
            + (imageInfo.width ?? 0 >= 900 ? 1 : 0)
    }

    private static func isFreeLicense(_ license: String) -> Bool {
        let normalized = license
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")

        guard
            !normalized.contains("noncommercial"),
            !normalized.contains("no derivatives"),
            !normalized.contains("fair use"),
            !normalized.contains("all rights")
        else {
            return false
        }

        return normalized.contains("public domain")
            || normalized.contains("cc0")
            || normalized.contains("cc by")
            || normalized.contains("creative commons attribution")
    }

    private static func isUnsuitableBirdPhoto(_ text: String) -> Bool {
        let blockedTerms = [
            ".wav",
            ".mp3",
            ".ogg",
            ".svg",
            "audio",
            "sound",
            "vocalization",
            "vocalisation",
            "range map",
            "distribution map",
            "iucn",
            "egg",
            "eggs",
            "nest",
        ]

        return blockedTerms.contains { text.contains($0) }
    }

    private static func hasPhotoEvidence(_ text: String) -> Bool {
        let photoTerms = [
            "photograph",
            "photo",
            "own work",
            "wildlife",
            "bird photos",
            "birds photographed",
            "photographs by",
            "quality image",
            "featured picture",
        ]

        return photoTerms.contains { text.contains($0) }
    }
}

private struct WikidataImageResponse: Decodable {
    let results: Results

    struct Results: Decodable {
        let bindings: [Binding]
    }

    struct Binding: Decodable {
        let image: ImageValue
    }

    struct ImageValue: Decodable {
        let value: String
    }
}

private struct CommonsSearchResponse: Decodable {
    let query: Query?

    struct Query: Decodable {
        let pages: [String: Page]?
    }

    struct Page: Decodable {
        let title: String
        let imageinfo: [ImageInfo]?
    }

    struct ImageInfo: Decodable {
        let url: URL?
        let thumburl: URL?
        let descriptionurl: URL?
        let mime: String?
        let width: Int?
        let height: Int?
        let extmetadata: [String: MetadataValue]?

        var isSupportedPhoto: Bool {
            guard let mime = mime?.lowercased() else {
                return true
            }

            return mime == "image/jpeg"
                || mime == "image/png"
                || mime == "image/webp"
        }

        var displayTitle: String? {
            clean(metadataValue("ObjectName"))
        }

        var description: String? {
            clean(metadataValue("ImageDescription"))
        }

        var categories: String? {
            clean(metadataValue("Categories"))
        }

        var artist: String? {
            clean(metadataValue("Artist"))
        }

        var credit: String? {
            clean(metadataValue("Credit"))
        }

        var licenseName: String? {
            clean(metadataValue("LicenseShortName"))
                ?? clean(metadataValue("UsageTerms"))
                ?? clean(metadataValue("License"))
        }

        private func metadataValue(_ key: String) -> String? {
            extmetadata?[key]?.value
        }

        private func clean(_ value: String?) -> String? {
            guard let value else {
                return nil
            }

            let withoutTags = value.replacingOccurrences(
                of: "<[^>]+>",
                with: "",
                options: .regularExpression
            )
            let decoded = withoutTags
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&#039;", with: "'")
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return decoded.isEmpty ? nil : decoded
        }
    }

    struct MetadataValue: Decodable {
        let value: String

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let string = try? container.decode(String.self, forKey: .value) {
                value = string
            } else if let double = try? container.decode(Double.self, forKey: .value) {
                value = String(double)
            } else if let bool = try? container.decode(Bool.self, forKey: .value) {
                value = String(bool)
            } else {
                value = ""
            }
        }

        private enum CodingKeys: String, CodingKey {
            case value
        }
    }
}
