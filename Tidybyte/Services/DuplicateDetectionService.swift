import Photos
import UIKit
import Vision

struct DuplicateGroup: Identifiable, Sendable {
    let id: String
    let assets: [AssetSummary]
    let bestAssetId: String
    let type: DuplicateType
}

extension DuplicateGroup: Hashable {
    static func == (lhs: DuplicateGroup, rhs: DuplicateGroup) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum DuplicateType: String, Sendable {
    case exact
    case visual
}

/// Result of an exact duplicate scan: the groups plus how many assets were
/// skipped because they are not on this device (iCloud-only; DUP-03).
struct ExactDuplicateResult: Sendable {
    let groups: [DuplicateGroup]
    let skippedCount: Int
}

/// Order-independent pair key used by the visual pre-filter's candidate set.
struct PairKey: Hashable, Sendable {
    let a: String
    let b: String

    init(_ x: String, _ y: String) {
        if x < y {
            a = x
            b = y
        } else {
            a = y
            b = x
        }
    }
}

/// DUP-01/DUP-12: cheap perceptual pre-filter for the visual duplicate scan.
/// Every asset is hashed to a 64-bit "average hash" (8x8 grayscale luminance
/// grid, one bit per cell against the grid mean) alongside its feature print.
/// Pairs whose Hamming distance exceeds `maxHammingDistance` are pruned before
/// the expensive Vision distance call. The bound is a recall/cost tradeoff,
/// not an exact-equality gate: 12 of 64 bits tolerates small crops, status-bar
/// / UI drift, and brightness-contrast edits, while only ~1 in 4 million
/// random pairs pass (at the 12-bit bound), so the pairwise Vision work is
/// still reduced by orders of magnitude. Assets whose luminance grid failed
/// (sentinel hash 0) carry NO information and are never pruned — they pair
/// with everything and the real Vision comparison decides (see
/// `candidatePairs`).
enum VisualPreFilter {
    static let maxHammingDistance = 12

    /// Pairs within the Hamming bound still go through the real Vision
    /// comparison; only pairs beyond the bound are pruned. The sentinel (0)
    /// carries no hash information, so it is never pruned — matching
    /// `candidatePairs`'s rule (see the enum doc).
    static func shouldCompare(_ lhs: UInt64, _ rhs: UInt64) -> Bool {
        if lhs == 0 || rhs == 0 { return true }
        return hammingDistance(lhs, rhs) <= maxHammingDistance
    }

    static func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    /// Downsample to an 8x8 device-gray grid; the returned 64 values are the
    /// per-cell mean luminance (0...255).
    static func luminanceGrid(from image: CGImage) -> [UInt8]? {
        let width = 8
        let height = 8
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height)
        return Array(UnsafeBufferPointer(start: bytes, count: width * height))
    }

    /// One bit per cell: 1 when the cell luminance is at/above the grid mean.
    /// A uniform grid hashes to all-ones, so 0 is never produced naturally and
    /// serves as the "no hash available" sentinel in the scan.
    static func hash64(from grid: [UInt8]) -> UInt64 {
        guard !grid.isEmpty else { return 0 }
        let mean = UInt64(grid.reduce(0) { $0 + UInt64($1) }) / UInt64(grid.count)
        var hash: UInt64 = 0
        for (index, cell) in grid.prefix(64).enumerated() {
            if UInt64(cell) >= mean {
                hash |= 1 << UInt64(index)
            }
        }
        return hash
    }

    /// All candidate pairs whose Hamming distance is within the bound, without
    /// comparing every pair: each hash is split into eight 8-bit chunks. If two
    /// hashes differ in at most `maxHammingDistance` (12) bits total, at least
    /// one chunk differs in at most 1 bit, so bucketing each chunk's 1-bit
    /// neighborhood surfaces every in-bound pair; the Hamming re-check below
    /// keeps the returned set exact. Assets with the 0 sentinel hash
    /// (luminance grid failed) are paired with every other asset: no
    /// information means no pruning.
    static func candidatePairs(_ hashes: [String: UInt64]) -> Set<PairKey> {
        guard hashes.count > 1 else { return [] }
        // Eight 8-bit chunks with a 1-bit radius are complete for the 12-bit
        // bound (a pair within the bound has some chunk differing in <= 1 bit)
        // at a fraction of the cost of wider chunks: 72 bucket lookups per
        // asset instead of ~2,800.
        let chunkCount = 8
        let chunkWidth = 8
        let chunkRadius = 1
        var buckets: [Int: [String]] = [:]
        var pairs = Set<PairKey>()
        // The radius-1 neighborhood is 9 values per 8-bit chunk value (at most
        // 256 distinct per chunk), so the memoization stays tiny and the
        // enumeration runs once per distinct value, not once per asset.
        var nearCache: [Int: [Int]] = [:]

        for (id, hash) in hashes {
            for chunk in 0..<chunkCount {
                let value = Int((hash >> UInt64(chunkWidth * chunk)) & 0xFF)
                let baseKey = chunk * (1 << chunkWidth)
                let near = nearCache[value] ?? {
                    let values = nearValues(to: value, radius: chunkRadius, width: chunkWidth)
                    nearCache[value] = values
                    return values
                }()
                for candidate in near {
                    let key = baseKey + candidate
                    if let earlier = buckets[key] {
                        for other in earlier where other != id {
                            guard let otherHash = hashes[other] else { continue }
                            if hammingDistance(hash, otherHash) <= maxHammingDistance {
                                pairs.insert(PairKey(id, other))
                            }
                        }
                    }
                }
                buckets[baseKey + value, default: []].append(id)
            }
        }

        // Sentinel: an asset with hash 0 has NO hash — it must never be pruned,
        // so pair it with every other asset and let the Vision comparison
        // decide. (Grid failures are rare; the cost is a handful of extra
        // pairwise comparisons, and the alternative — silently dropping
        // potentially-duplicate assets — is worse.)
        let sentinelIds = hashes.compactMap { $0.value == 0 ? $0.key : nil }
        for sentinel in sentinelIds {
            for (id, _) in hashes where id != sentinel {
                pairs.insert(PairKey(sentinel, id))
            }
        }
        return pairs
    }

    /// Converts the unordered candidate set into the original PhotoKit order.
    /// The visual scan can then visit only candidate edges instead of walking
    /// every possible pair and asking the set whether each one survived.
    static func candidateIndicesByAnchor(
        assetIds: [String],
        candidates: Set<PairKey>
    ) -> [[Int]] {
        var indexByID: [String: Int] = [:]
        for (index, id) in assetIds.enumerated() where indexByID[id] == nil {
            indexByID[id] = index
        }
        var result = Array(repeating: [Int](), count: assetIds.count)

        for pair in candidates {
            guard let first = indexByID[pair.a], let second = indexByID[pair.b] else { continue }
            let anchor = min(first, second)
            let candidate = max(first, second)
            result[anchor].append(candidate)
        }

        for index in result.indices {
            result[index].sort()
        }
        return result
    }

    /// Every `width`-bit value within Hamming distance `radius` (inclusive).
    static func nearValues(to value: Int, radius: Int, width: Int = 16) -> [Int] {
        var result: [Int] = [value]
        if radius >= 1 {
            for bit in 0..<width {
                result.append(value ^ (1 << bit))
            }
        }
        if radius >= 2 {
            for first in 0..<width {
                for second in (first + 1)..<width {
                    result.append(value ^ (1 << first) ^ (1 << second))
                }
            }
        }
        if radius >= 3 {
            for first in 0..<width {
                for second in (first + 1)..<width {
                    for third in (second + 1)..<width {
                        result.append(value ^ (1 << first) ^ (1 << second) ^ (1 << third))
                    }
                }
            }
        }
        return result
    }
}

actor DuplicateDetectionService {
    private let photoService: PhotoLibraryService
    private let visionService: VisionAnalysisService

    init(photoService: PhotoLibraryService, visionService: VisionAnalysisService) {
        self.photoService = photoService
        self.visionService = visionService
    }

    // MARK: - Exact Duplicate Detection

    /// DUP-03: splits assets into locally-available candidates for exact
    /// hashing and iCloud-only assets that would have to be downloaded. Pure so
    /// the counting logic is unit-testable without PhotoKit.
    static func splitByLocalAvailability(
        _ assets: [AssetSummary]
    ) -> (candidates: [AssetSummary], skipped: Int) {
        var candidates: [AssetSummary] = []
        var skipped = 0
        for asset in assets {
            if asset.isLocallyAvailable {
                candidates.append(asset)
            } else {
                skipped += 1
            }
        }
        return (candidates, skipped)
    }

    /// Exact byte matches must have the same primary-resource length. Use that
    /// cheap metadata to avoid streaming every full-resolution asset through
    /// SHA-256. When PhotoKit does not expose a resource size, keep the entire
    /// matching dimension bucket so the optimization cannot hide a duplicate.
    static func exactHashCandidates(_ assets: [AssetSummary]) -> [AssetSummary] {
        var dimensionBuckets: [String: [AssetSummary]] = [:]
        for asset in assets {
            let key = "\(asset.pixelWidth)x\(asset.pixelHeight)_\(asset.mediaType)"
            dimensionBuckets[key, default: []].append(asset)
        }

        var candidateIDs = Set<String>()
        for bucket in dimensionBuckets.values where bucket.count > 1 {
            if bucket.contains(where: { $0.primaryResourceSize <= 0 }) {
                candidateIDs.formUnion(bucket.map(\.id))
                continue
            }

            let sizeBuckets = Dictionary(grouping: bucket, by: \.primaryResourceSize)
            for sizeBucket in sizeBuckets.values where sizeBucket.count > 1 {
                candidateIDs.formUnion(sizeBucket.map(\.id))
            }
        }

        // Preserve PhotoKit's input order for deterministic hashing and progress.
        return assets.filter { candidateIDs.contains($0.id) }
    }

    func findExactDuplicates(
        assets: [AssetSummary],
        progress: @Sendable (Float) -> Void
    ) async -> ExactDuplicateResult {
        // Pre-filter pass (reports 0 → 0.1 so the bar moves during this phase;
        // DUP-12): bucket by dimensions, media type, and the primary resource's
        // exact byte length. Common camera dimensions alone keep most large
        // libraries in the hash set; byte length removes unique assets without
        // changing exact-match results.
        // Assets that aren't on this device are skipped — hashing them would
        // download the full resource from iCloud (DUP-03) — and counted so the
        // UI can surface "N iCloud-only photos skipped".
        let (localAssets, skippedCount) = Self.splitByLocalAvailability(assets)
        let total = assets.count
        for (index, _) in localAssets.enumerated() {
            if Task.isCancelled {
                return ExactDuplicateResult(groups: [], skippedCount: skippedCount)
            }
            if index % 20 == 0 {
                await Task.yield()
            }
            progress(Float(index + 1) / Float(max(total, 1)) * 0.1)
        }

        let hashCandidates = Self.exactHashCandidates(localAssets)
        let totalAssets = hashCandidates.count
        var processed = 0

        var hashGroups: [String: [AssetSummary]] = [:]

        for asset in hashCandidates {
            if Task.isCancelled {
                return ExactDuplicateResult(groups: [], skippedCount: skippedCount)
            }
            if processed % 20 == 0 {
                await Task.yield()
            }
            // Stream the hash so large videos aren't loaded fully into memory.
            if let hashString = await photoService.sha256ForPrimaryResource(of: asset.id) {
                hashGroups[hashString, default: []].append(asset)
            }
            processed += 1
            progress(0.1 + Float(processed) / Float(max(totalAssets, 1)) * 0.9)
        }

        if hashCandidates.isEmpty {
            progress(1)
        }

        let groups = hashGroups
            .filter { $0.value.count > 1 }
            .map { (hash, assets) in
                let best = selectBestAsset(from: assets)
                return DuplicateGroup(
                    id: hash,
                    assets: assets,
                    bestAssetId: best.id,
                    type: .exact
                )
            }
            .sorted { $0.assets.count > $1.assets.count }

        return ExactDuplicateResult(groups: groups, skippedCount: skippedCount)
    }

    // MARK: - Visual Duplicate Detection

    func findVisualDuplicates(
        assets: [AssetSummary],
        threshold: Float = 0.5,
        progress: @Sendable (Float) -> Void
    ) async -> [DuplicateGroup] {
        let photoAssets = assets.filter { $0.mediaType == .photo }
        let total = photoAssets.count
        // Thumbnail loading and Vision feature generation dominate normal
        // scans. Giving that phase a stable share keeps large-library progress
        // visible instead of weighting it against an n-squared theoretical
        // pair count and displaying 0% for most of the scan.
        let generationWeight: Float = 0.8
        let comparisonWeight = 1 - generationWeight

        // Phase 1 (0 → generationWeight): feature prints plus the cheap
        // perceptual pre-filter hash, both from the same 300px CGImage.
        var featurePrints: [(asset: AssetSummary, print: FeaturePrint, hash: UInt64)] = []
        for (index, asset) in photoAssets.enumerated() {
            if Task.isCancelled { return [] }
            if index % 20 == 0 {
                await Task.yield()
            }
            var hash: UInt64 = 0
            if let image = await loadCGImage(for: asset.id) {
                if let grid = VisualPreFilter.luminanceGrid(from: image) {
                    hash = VisualPreFilter.hash64(from: grid)
                }
                if let fp = await visionService.generateFeaturePrint(image: image) {
                    featurePrints.append((asset, fp, hash))
                }
            }
            progress(generationWeight * Float(index + 1) / Float(max(total, 1)))
        }

        // DUP-01: pre-filter the comparison set — only pairs whose perceptual
        // hash is within the loose Hamming bound can be duplicates, so the
        // expensive Vision distance call is skipped for every other pair.
        // The map is built defensively: PhotoKit identifiers are unique, but a
        // trap on a duplicate key would kill the whole scan — keep the FIRST
        // hash for a repeated id instead of crashing.
        let hashesByAsset = featurePrints.reduce(into: [String: UInt64]()) { result, entry in
            if result[entry.asset.id] == nil {
                result[entry.asset.id] = entry.hash
            }
        }
        let candidateSet = VisualPreFilter.candidatePairs(hashesByAsset)
        let candidateIndices = VisualPreFilter.candidateIndicesByAnchor(
            assetIds: featurePrints.map { $0.asset.id },
            candidates: candidateSet
        )
        let totalCandidateEdges = max(candidateSet.count, 1)
        let progressUpdateStride = 128

        // Phase 2 (generationWeight → 1): greedy grouping, unchanged semantics
        // (same anchor order, same threshold, same visited handling).
        var visited = Set<String>()
        var groups: [DuplicateGroup] = []
        var processedCandidateEdges = 0

        for i in 0..<featurePrints.count {
            // Preserve groups already found rather than discarding completed work on cancel.
            if Task.isCancelled { return groups.sorted { $0.assets.count > $1.assets.count } }
            guard !visited.contains(featurePrints[i].asset.id) else {
                processedCandidateEdges += candidateIndices[i].count
                if !candidateIndices[i].isEmpty
                    && (processedCandidateEdges.isMultiple(of: progressUpdateStride)
                        || processedCandidateEdges == candidateSet.count) {
                    progress(
                        generationWeight
                        + comparisonWeight * Float(processedCandidateEdges) / Float(totalCandidateEdges)
                    )
                }
                continue
            }

            var group: [AssetSummary] = [featurePrints[i].asset]
            visited.insert(featurePrints[i].asset.id)

            for j in candidateIndices[i] {
                if Task.isCancelled { return groups.sorted { $0.assets.count > $1.assets.count } }
                processedCandidateEdges += 1
                guard !visited.contains(featurePrints[j].asset.id) else {
                    if processedCandidateEdges.isMultiple(of: progressUpdateStride)
                        || processedCandidateEdges == candidateSet.count {
                        progress(
                            generationWeight
                            + comparisonWeight * Float(processedCandidateEdges) / Float(totalCandidateEdges)
                        )
                    }
                    continue
                }

                let distance = await visionService.computeDistance(
                    between: featurePrints[i].print,
                    and: featurePrints[j].print
                )

                if distance < threshold {
                    group.append(featurePrints[j].asset)
                    visited.insert(featurePrints[j].asset.id)
                }

                if processedCandidateEdges.isMultiple(of: progressUpdateStride)
                    || processedCandidateEdges == candidateSet.count {
                    progress(
                        generationWeight
                        + comparisonWeight * Float(processedCandidateEdges) / Float(totalCandidateEdges)
                    )
                }
            }

            if group.count > 1 {
                let best = selectBestAsset(from: group)
                groups.append(DuplicateGroup(
                    id: UUID().uuidString,
                    assets: group,
                    bestAssetId: best.id,
                    type: .visual
                ))
            }

        }

        progress(1)
        return groups.sorted { $0.assets.count > $1.assets.count }
    }

    // MARK: - Helpers

    private func selectBestAsset(from assets: [AssetSummary]) -> AssetSummary {
        // Highest resolution, then favorited, then most recent, then stable id.
        BestAssetSelector.bestByMetadata(from: assets) ?? assets[0]
    }

    private func loadCGImage(for assetId: String) async -> CGImage? {
        guard let uiImage = await photoService.loadThumbnail(for: assetId, size: CGSize(width: 300, height: 300)) else {
            return nil
        }
        return uiImage.cgImage
    }
}
