//
//  BirdImageCatalog.swift
//  piep
//
//  Created by Codex on 03.06.26.
//

import Foundation

struct BirdImageInfo {
    let scientificName: String
    let assetName: String
    let title: String
    let credit: String
    let license: String
    let sourceURL: URL
}

enum BirdImageCatalog {
    static func image(for scientificName: String) -> BirdImageInfo? {
        nil
    }
}
