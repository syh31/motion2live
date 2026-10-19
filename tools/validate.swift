// validate.swift — decode the still with ImageIO and the movie with AVFoundation,
// then confirm both carry the same Live Photo ContentIdentifier.
import Foundation
import ImageIO
import AVFoundation
import CoreMedia

func die(_ m: String) -> Never { FileHandle.standardError.write((m+"\n").data(using:.utf8)!); exit(1) }

let still = URL(fileURLWithPath: CommandLine.arguments[1])
let movie = URL(fileURLWithPath: CommandLine.arguments[2])

// ---- still image ----
guard let src = CGImageSourceCreateWithURL(still as CFURL, nil) else { die("FAIL: cannot open still") }
guard let type = CGImageSourceGetType(src) else { die("FAIL: unknown still type") }
print("still type     : \(type)")
guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { die("FAIL: no props") }
print("still pixels   : \(props[kCGImagePropertyPixelWidth] ?? "?") x \(props[kCGImagePropertyPixelHeight] ?? "?")")
let headroom = (props["Headroom" as CFString] as? NSNumber)?.doubleValue ?? 1.0
let appleGainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
let isoGainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
print("still HDR      : \(headroom > 1.01 || appleGainMap || isoGainMap ? "yes" : "no") (headroom \(String(format: "%.3f", headroom)))")
if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
    print("still DateTime : \(exif[kCGImagePropertyExifDateTimeOriginal] ?? "-")")
}
guard let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { die("FAIL: still will NOT decode") }
print("still decode   : OK  (\(img.width)x\(img.height), \(img.bitsPerPixel)bpp)")
if let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil) {
    let tags = CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag] ?? []
    for t in tags {
        let prefix = CGImageMetadataTagCopyPrefix(t) as String? ?? ""
        let name = CGImageMetadataTagCopyName(t) as String? ?? ""
        let val = CGImageMetadataTagCopyValue(t).map { "\($0)" } ?? ""
        if name.contains("Identifier") || prefix == "apple" { print("still XMP      : \(prefix):\(name) = \(val)") }
    }
}

// ---- movie ----
let asset = AVURLAsset(url: movie)
let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let tracks = try await asset.load(.tracks)
        let dur = try await asset.load(.duration)
        print("movie duration : \(String(format: "%.3f", CMTimeGetSeconds(dur)))s, tracks=\(tracks.count)")
        for t in tracks {
            let fd = try await t.load(.formatDescriptions)
            let codec = fd.first.map { String(describing: CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
            print("  track \(t.mediaType.rawValue) codec=\(codec) nominal=\(String(format:"%.1f", try await t.load(.nominalFrameRate)))fps")
        }
        let md = try await asset.load(.metadata)
        var found: [String:String] = [:]
        for item in md {
            if let k = item.key as? String,
               k.contains("content.identifier") || k.contains("still-image-time") || k.contains("live-photo.auto") {
                found[k] = String(describing: try await item.load(.value))
            }
        }
        for (k,v) in found.sorted(by: { $0.key < $1.key }) { print("movie metadata : \(k) = \(v)") }
        let stillIdentifier: String? = {
            guard let maker = props[kCGImagePropertyMakerAppleDictionary] as? NSDictionary else { return nil }
            return (maker["17"] ?? maker[17]).map { String(describing: $0) }
        }()
        let movieIdentifier = found.first { $0.key.contains("content.identifier") }?.value
            .replacingOccurrences(of: "Optional(", with: "")
            .replacingOccurrences(of: ")", with: "")
        print("still identifier: \(stillIdentifier ?? "MISSING")")
        let ok = stillIdentifier != nil && movieIdentifier == stillIdentifier
            && found.keys.contains { $0.contains("still-image-time") }
        print("\nRESULT: \(ok ? "VALID Live Photo metadata pair" : "INVALID or mismatched Live Photo metadata")")
        exit(ok ? 0 : 1)
    } catch { die("FAIL: \(error)") }
}
dispatchMain()
