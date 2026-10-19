// mkstill.swift — create the still half of a Live Photo.
//
// usage:
//   mkstill <in.jpg|heic> <out.jpg|heic> <contentIdentifier> [heic|jpeg]
//           [--hdr auto|preserve|sdr]
//
// HDR modes:
//   auto      preserve/regenerate a gain map when the source is HDR; fall back
//             to SDR with a warning if the platform encoder cannot do so.
//   preserve  require HDR output and fail rather than silently flattening it.
//   sdr       deliberately tone-map/encode an SDR still.
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum HDRMode: String {
    case auto, preserve, sdr
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("FAIL: \(message)\n").data(using: .utf8)!)
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
var hdrMode: HDRMode = .auto
if let index = args.firstIndex(of: "--hdr") {
    guard index + 1 < args.count, let parsed = HDRMode(rawValue: args[index + 1]) else {
        fail("--hdr must be auto, preserve, or sdr")
    }
    hdrMode = parsed
    args.removeSubrange(index ... index + 1)
}
guard args.count == 3 || args.count == 4 else {
    print("usage: mkstill <in> <out> <contentIdentifier> [heic|jpeg] [--hdr auto|preserve|sdr]")
    exit(2)
}

let sourceURL = URL(fileURLWithPath: args[0])
let outputURL = URL(fileURLWithPath: args[1])
let contentIdentifier = args[2]
let format = args.count == 4 ? args[3].lowercased() : "jpeg"
guard format == "heic" || format == "jpeg" else { fail("format must be heic or jpeg") }
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
    fail("cannot open \(sourceURL.path)")
}

let sourceType = CGImageSourceGetType(source) as String? ?? "unknown"
let sourceProperties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
let sourceHeadroom = (sourceProperties["Headroom" as CFString] as? NSNumber)?.doubleValue ?? 1.0
let hasAppleGainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
    source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
let hasISOGainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
    source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
let sourceIsHDR = sourceHeadroom > 1.01 || hasAppleGainMap || hasISOGainMap
let requireHDROutput = hdrMode == .preserve && sourceIsHDR
let wantsHDR = hdrMode != .sdr && sourceIsHDR
let destinationType = format == "heic" ? UTType.heic.identifier : UTType.jpeg.identifier

func outputHeadroom(_ url: URL) -> Double {
    guard let result = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [CFString: Any]
    else { return 1.0 }
    return (properties["Headroom" as CFString] as? NSNumber)?.doubleValue ?? 1.0
}

func encode(hdr: Bool) -> Bool {
    try? FileManager.default.removeItem(at: outputURL)
    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL, destinationType as CFString, 1, nil) else { return false }

    var properties = sourceProperties
    properties[kCGImagePropertyMakerAppleDictionary] = ["17": contentIdentifier]

    if hdr {
        // Decode the source's gain-map representation into an extended-range
        // image, then encode a standards-based ISO gain map. This also bridges
        // Android Ultra HDR JPEG into an Apple-friendly HEIC/JPEG still.
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
            kCGImageSourceDecodeRequestOptions: [
                kCGImageSourceGenerateImageSpecificLumaScaling: true,
            ],
        ]
        guard let image = CGImageSourceCreateImageAtIndex(
            source, 0, decodeOptions as CFDictionary) else { return false }
        properties[kCGImageDestinationEncodeRequest] = kCGImageDestinationEncodeToISOGainmap
        properties[kCGImageDestinationEncodeRequestOptions] = [
            kCGImageDestinationEncodeBaseIsSDR: true,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    } else {
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR,
        ]
        guard let image = CGImageSourceCreateImageAtIndex(
            source, 0, decodeOptions as CFDictionary) else { return false }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    }
    return CGImageDestinationFinalize(destination)
}

var encodedHDR = false
if wantsHDR {
    encodedHDR = encode(hdr: true)
    if !encodedHDR && hdrMode == .auto {
        FileHandle.standardError.write(
            "warning: HDR gain-map encoding failed; falling back to SDR\n".data(using: .utf8)!)
    }
}
if !encodedHDR && !encode(hdr: false) {
    fail("cannot encode \(outputURL.lastPathComponent)")
}

let resultHeadroom = outputHeadroom(outputURL)
if requireHDROutput && resultHeadroom <= 1.01 {
    try? FileManager.default.removeItem(at: outputURL)
    fail("source is HDR (headroom \(String(format: "%.3f", sourceHeadroom))) but output has no gain map")
}
if wantsHDR && resultHeadroom <= 1.01 {
    FileHandle.standardError.write(
        "warning: output is SDR even though the source reported HDR headroom\n".data(using: .utf8)!)
}

guard let result = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
      let resultProperties = CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [CFString: Any],
      CGImageSourceCreateImageAtIndex(result, 0, nil) != nil
else { fail("output does not decode") }
let maker = resultProperties[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
guard String(describing: maker?["17"] ?? "") == contentIdentifier else {
    try? FileManager.default.removeItem(at: outputURL)
    fail("Apple MakerNote key 17 was not written")
}

print("wrote \(outputURL.lastPathComponent) [\(format)]")
print("  source type : \(sourceType)")
print("  source HDR  : \(sourceIsHDR ? "yes" : "no") (headroom \(String(format: "%.3f", sourceHeadroom)))")
print("  output HDR  : \(resultHeadroom > 1.01 ? "yes" : "no") (headroom \(String(format: "%.3f", resultHeadroom)))")
print("  MakerApple  : key 17 = \(contentIdentifier)")
print("  pixels      : \(resultProperties[kCGImagePropertyPixelWidth] ?? "?")x\(resultProperties[kCGImagePropertyPixelHeight] ?? "?")")
