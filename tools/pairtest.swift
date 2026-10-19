import Foundation
import Photos
let a = Array(CommandLine.arguments.dropFirst())
guard a.count == 2 else { print("usage: pairtest <still> <movie>"); exit(2) }
let still = URL(fileURLWithPath: a[0]), movie = URL(fileURLWithPath: a[1])
let sem = DispatchSemaphore(value: 0)
PHPhotoLibrary.requestAuthorization(for: .readWrite) { st in
    guard st == .authorized || st == .limited else { print("NO AUTH"); sem.signal(); return }
    let s = DispatchSemaphore(value: 0)
    var cid: PHObjectPlaceholder?
    PHPhotoLibrary.shared().performChanges({
        let r = PHAssetCreationRequest.forAsset()
        let so = PHAssetResourceCreationOptions(); so.originalFilename = still.lastPathComponent
        r.addResource(with: .photo, fileURL: still, options: so)
        let vo = PHAssetResourceCreationOptions(); vo.originalFilename = movie.lastPathComponent
        r.addResource(with: .pairedVideo, fileURL: movie, options: vo)
        cid = r.placeholderForCreatedAsset
    }) { ok, err in
        print("still=\(still.lastPathComponent) + movie=\(movie.lastPathComponent)")
        print("   result: \(ok ? "ACCEPTED" : "REJECTED")  \(err.map { "\(($0 as NSError).domain)/\(($0 as NSError).code)" } ?? "")")
        if ok, let c = cid, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [c.localIdentifier], options: nil).firstObject {
            print("   mediaSubtype=\(asset.mediaSubtypes.rawValue) live=\(asset.mediaSubtypes.contains(.photoLive))")
            for r in PHAssetResource.assetResources(for: asset) { print("   resource type=\(r.type.rawValue) \(r.originalFilename)") }
        }
        s.signal()
    }
    s.wait(); sem.signal()
}
sem.wait()
