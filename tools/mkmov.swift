// mkmov.swift — write a Live Photo MOV: passthrough video + Apple pairing metadata.
//
// usage: mkmov <in.mov|mp4> <out.mov> <contentIdentifier> [--date YYYY-MM-DDThh:mm:ssZ]
//
// The movie carries the three keys PHLivePhoto matching depends on:
//   com.apple.quicktime.content.identifier  == the still image's MakerNote key 17
//   com.apple.quicktime.still-image-time
//   com.apple.quicktime.live-photo.auto
//
// AVAssetExportSession stamps every time field in the output with "now", which
// for a converted photo means the movie claims it was shot on the conversion
// date. Unless --date is given we restore the source movie's creation time in
// mvhd/tkhd/mdhd, so conversions are reproducible and consistent with the still
// image's EXIF.
import AVFoundation
import Foundation

// MARK: - QuickTime time handling

let kQuickTimeEpochToUnix: Int64 = 2_082_844_800   // 1904-01-01 -> 1970-01-01

func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
    (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
}
func be64(_ b: [UInt8], _ o: Int) -> UInt64 {
    var v: UInt64 = 0
    for k in 0 ..< 8 { v = (v << 8) | UInt64(b[o + k]) }
    return v
}

/// Find one box by type anywhere under `parent`, returning the offset of its
/// 4-char type. Container boxes are descended into.
///
/// Offset convention: `type` is the 4-char type at `at`, so the box starts four
/// bytes earlier and its payload begins at `at + 4`.
func findBox(_ b: [UInt8], wanted: String, at: Int, end: Int) -> Int? {
    var cursor = at + 4
    let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "udta", "meta"]
    while cursor + 8 <= end {
        let size = Int(be32(b, cursor))
        let type = String(decoding: b[cursor + 4 ..< cursor + 8], as: UTF8.self)
        let childEnd = size == 0 ? end : min(cursor + size, end)
        if type == wanted { return cursor + 4 }
        if containers.contains(type), let hit = findBox(b, wanted: wanted, at: cursor + 4, end: childEnd) {
            return hit
        }
        guard size >= 8 else { return nil }
        cursor += size
    }
    return nil
}

/// Byte offset of a full-box's creation-time field, plus its width.
/// Layout after the type: version+flags (4), creation (4 or 8), modification.
func creationField(_ b: [UInt8], boxTypeAt typeAt: Int) -> (offset: Int, is64: Bool)? {
    guard typeAt + 12 <= b.count else { return nil }
    let version = b[typeAt + 4]
    return (typeAt + 8, version == 1)
}

func readMovieCreationTime(_ url: URL) -> Date? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let bytes = [UInt8](data)
    guard let moov = findBox(bytes, wanted: "moov", at: -4, end: bytes.count),
          let mvhd = findBox(bytes, wanted: "mvhd", at: moov, end: bytes.count),
          let field = creationField(bytes, boxTypeAt: mvhd),
          field.offset + (field.is64 ? 8 : 4) <= bytes.count
    else { return nil }
    let raw = field.is64 ? be64(bytes, field.offset) : UInt64(be32(bytes, field.offset))
    guard raw > 0 else { return nil }
    return Date(timeIntervalSince1970: Double(Int64(raw) - kQuickTimeEpochToUnix))
}

/// Rewrite creation and modification time in every mvhd / tkhd / mdhd so the
/// exported movie keeps the source's date instead of the export date.
@discardableResult
func normaliseDates(to date: Date, in url: URL) -> Int {
    guard var data = try? Data(contentsOf: url) else { return 0 }
    let bytes = [UInt8](data)
    let epoch = Int64(date.timeIntervalSince1970) + kQuickTimeEpochToUnix
    guard epoch > 0 else { return 0 }
    guard let moov = findBox(bytes, wanted: "moov", at: -4, end: bytes.count) else { return 0 }

    // Collect every target box, then patch back-to-front so earlier offsets stay
    // valid even though the field widths are unchanged.
    var hits: [(offset: Int, is64: Bool)] = []
    for name in ["mvhd", "tkhd", "mdhd"] {
        var typeAts: [Int] = []
        collectBoxes(bytes, wanted: name, at: moov, end: bytes.count, into: &typeAts)
        for typeAt in typeAts {
            if let field = creationField(bytes, boxTypeAt: typeAt),
               field.offset + (field.is64 ? 16 : 8) <= bytes.count {
                hits.append(field)
            }
        }
    }
    hits.sort { $0.offset > $1.offset }
    for field in hits {
        if field.is64 {
            var v = UInt64(epoch).bigEndian
            withUnsafeBytes(of: &v) {
                data.replaceSubrange(field.offset ..< field.offset + 8, with: $0)
                data.replaceSubrange(field.offset + 8 ..< field.offset + 16, with: $0)
            }
        } else {
            var v = UInt32(truncatingIfNeeded: epoch).bigEndian
            withUnsafeBytes(of: &v) {
                data.replaceSubrange(field.offset ..< field.offset + 4, with: $0)
                data.replaceSubrange(field.offset + 4 ..< field.offset + 8, with: $0)
            }
        }
    }
    guard !hits.isEmpty else { return 0 }
    do { try data.write(to: url) } catch { return 0 }
    return hits.count
}

func collectBoxes(_ b: [UInt8], wanted: String, at: Int, end: Int, into out: inout [Int]) {
    var cursor = at + 4
    let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "udta", "meta"]
    while cursor + 8 <= end {
        let size = Int(be32(b, cursor))
        let type = String(decoding: b[cursor + 4 ..< cursor + 8], as: UTF8.self)
        let childEnd = size == 0 ? end : min(cursor + size, end)
        if type == wanted { out.append(cursor + 4) }
        if containers.contains(type) { collectBoxes(b, wanted: wanted, at: cursor + 4, end: childEnd, into: &out) }
        guard size >= 8 else { return }
        cursor += size
    }
}

// MARK: - main

var argv = Array(CommandLine.arguments.dropFirst())
var explicitDate: Date?
if let idx = argv.firstIndex(of: "--date") {
    guard idx + 1 < argv.count else { print("usage: mkmov <in> <out> <cid> [--date ISO8601]"); exit(2) }
    guard let d = ISO8601DateFormatter().date(from: argv[idx + 1]) else { print("FAIL: bad --date"); exit(2) }
    explicitDate = d
    argv.removeSubrange(idx ... idx + 1)
}
guard argv.count == 3 else { print("usage: mkmov <in.mov|mp4> <out.mov> <cid> [--date ISO8601]"); exit(2) }
let inURL = URL(fileURLWithPath: argv[0]), outURL = URL(fileURLWithPath: argv[1])
let cid = argv[2]
guard FileManager.default.fileExists(atPath: inURL.path) else { print("FAIL: no such input \(inURL.path)"); exit(1) }
try? FileManager.default.removeItem(at: outURL)

let sourceDate = explicitDate ?? readMovieCreationTime(inURL)
let asset = AVURLAsset(url: inURL)

func item(_ key: String, _ value: Any) -> AVMutableMetadataItem {
    let m = AVMutableMetadataItem()
    m.key = key as NSString
    m.keySpace = .quickTimeMetadata
    m.value = (value as? NSString) ?? (value as? NSNumber) ?? "\(value)" as NSString
    return m
}

Task {
    do {
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            print("FAIL: no export session"); exit(1)
        }
        let md: [AVMetadataItem] = [
            item("com.apple.quicktime.content.identifier", cid),
            item("com.apple.quicktime.still-image-time", 0 as NSNumber),
            item("com.apple.quicktime.live-photo.auto", 1 as NSNumber),
        ]
        ex.outputURL = outURL
        ex.outputFileType = .mov
        ex.metadata = md
        ex.shouldOptimizeForNetworkUse = false
        try await ex.export(to: outURL, as: .mov)

        print("wrote \(outURL.lastPathComponent) with \(md.count) metadata items")
        if let d = sourceDate {
            let n = normaliseDates(to: d, in: outURL)
            print("movie date: \(ISO8601DateFormatter().string(from: d))"
                  + (n > 0 ? " (normalised \(n) time fields)" : " (no time fields patched)"))
        } else {
            print("movie date: source had none; left as exported")
        }
        exit(0)
    } catch {
        print("FAIL: \(error)")
        exit(1)
    }
}
dispatchMain()
