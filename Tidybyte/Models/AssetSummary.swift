import Foundation

enum MediaType: String, Sendable {
    case photo
    case video
    case audio
    case unknown
}

/// Where an asset most likely originated. Derived heuristically from PhotoKit
/// metadata (subtypes, location, original filename) — see
/// `PhotoLibraryService.detectOrigin`. Used by the Smart Categories tool to
/// surface media that wasn't captured with the camera (e.g. images saved from
/// messaging or social apps).
enum AssetOrigin: String, Sendable {
    case camera
    case savedFromApp
    case screenshot
    case unknown
}

struct AssetSummary: Identifiable, Sendable, Hashable {
    let id: String
    let mediaType: MediaType
    let creationDate: Date?
    let modificationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval
    let fileSize: Int64
    /// Byte length of the exact resource used by duplicate hashing. This stays
    /// separate from `fileSize`, which includes Live Photo companions and edits.
    let primaryResourceSize: Int64
    let filename: String?
    let isFavorite: Bool
    let isBurst: Bool
    let burstIdentifier: String?
    let isLivePhoto: Bool
    let isScreenshot: Bool
    let isLocallyAvailable: Bool
    var assetOrigin: AssetOrigin = .unknown

    init(
        id: String,
        mediaType: MediaType,
        creationDate: Date?,
        modificationDate: Date?,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: TimeInterval,
        fileSize: Int64,
        primaryResourceSize: Int64 = 0,
        filename: String?,
        isFavorite: Bool,
        isBurst: Bool,
        burstIdentifier: String?,
        isLivePhoto: Bool,
        isScreenshot: Bool,
        isLocallyAvailable: Bool,
        assetOrigin: AssetOrigin = .unknown
    ) {
        self.id = id
        self.mediaType = mediaType
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.fileSize = fileSize
        self.primaryResourceSize = primaryResourceSize
        self.filename = filename
        self.isFavorite = isFavorite
        self.isBurst = isBurst
        self.burstIdentifier = burstIdentifier
        self.isLivePhoto = isLivePhoto
        self.isScreenshot = isScreenshot
        self.isLocallyAvailable = isLocallyAvailable
        self.assetOrigin = assetOrigin
    }

    var resolution: String {
        "\(pixelWidth) × \(pixelHeight)"
    }

    var formattedDuration: String {
        guard duration > 0 else { return "" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    /// Human-readable size for labels/confirmations, tolerant of unavailable
    /// metadata: a 0 fileSize (iCloud-only or KVC-unreadable) renders as
    /// "Size unavailable" instead of a misleading "Zero KB" (SHARED-03).
    var displaySize: String {
        fileSize == 0 ? "Size unavailable" : fileSize.formattedFileSize
    }
}
