//
//  MarkerTracker.swift
//
// QR codes seen by the headset, reported to the streamer for its QR code recentering mode. Found by
// image tracking: each reference image in the "QR Codes" AR resource group is a printed code, cropped
// to its black pattern and sized as printed. Image tracking cannot read a code, so codeTexts gives
// each image's text, which is what the Quest reports for the same code.
//

import Foundation
import ARKit
import QuartzCore // CACurrentMediaTime

class MarkerTracker {
    static let referenceImageGroup = "QR Codes"
    static let sendInterval: TimeInterval = 0.5

    // Reference image name -> the code's text; asset names cannot hold a URL. Unlisted images report
    // their name.
    static let codeTexts = [
        "cae-qr": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    ]

    // ARKit puts an image anchor's +Y out of the image's face and its -Z towards the image's top edge,
    // ALVR wants +Y towards the top edge and +Z out of the face
    static let anchorFromMarker = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: simd_float3(1, 0, 0)))

    struct Marker {
        let originFromMarker: simd_float4x4 // Apple world space
        let size: Float // Edge length in metres
    }

    let imageTracking: ImageTrackingProvider?
    private var markers: [String: Marker] = [:]
    private var markersLock = NSObject()
    private var lastSent: TimeInterval = 0

    init() {
        let referenceImages = ReferenceImage.loadReferenceImages(inGroupNamed: MarkerTracker.referenceImageGroup)
        if ImageTrackingProvider.isSupported && !referenceImages.isEmpty {
            imageTracking = ImageTrackingProvider(referenceImages: referenceImages)
        }
        else {
            print("QR code tracking is not available, reference images:", referenceImages.count)
            imageTracking = nil
        }
    }

    func processUpdates() async {
        guard let imageTracking else { return }

        for await update in imageTracking.anchorUpdates {
            let anchor = update.anchor
            guard let name = anchor.referenceImage.name else { continue }
            let id = MarkerTracker.codeTexts[name] ?? name

            objc_sync_enter(markersLock)
            if update.event != .removed && anchor.isTracked {
                if markers[id] == nil {
                    print("QR code \"\(id)\" at", anchor.originFromAnchorTransform.columns.3)
                }
                markers[id] = Marker(
                    originFromMarker: anchor.originFromAnchorTransform * MarkerTracker.anchorFromMarker,
                    size: Float(anchor.referenceImage.physicalSize.width) * anchor.estimatedScaleFactor)
            }
            else if markers.removeValue(forKey: id) != nil {
                print("QR code \"\(id)\" lost")
            }
            objc_sync_exit(markersLock)
        }
    }

    // Reports the markers in view every sendInterval, in the space the tracking is sent in
    func send(steamVRFromApple: simd_float4x4) {
        guard imageTracking != nil else { return }

        let now = CACurrentMediaTime()
        if now - lastSent < MarkerTracker.sendInterval {
            return
        }
        lastSent = now

        objc_sync_enter(markersLock)
        let current = markers
        objc_sync_exit(markersLock)

        let ids = current.keys.map { strdup($0)! }
        defer { ids.forEach { free($0) } }

        let alvrMarkers = zip(ids, current.values).map { id, marker in
            let transform = steamVRFromApple * marker.originFromMarker
            return AlvrMarker(id: id, pose: AlvrPose(simd_quaternion(transform), transform.columns.3), size: marker.size)
        }
        alvr_send_markers(alvrMarkers, UInt64(alvrMarkers.count))
    }
}
