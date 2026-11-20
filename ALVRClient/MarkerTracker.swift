//
//  MarkerTracker.swift
//
// QR codes seen by the headset, reported to the streamer for OpenXR applications to track. Found by
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
    private var reportedUnavailable = false

    // alvr_log reaches the streamer's session_log.txt while connected, so a run can be checked
    // without a console on the headset
    static func log(_ message: String) {
        print(message)
        alvr_log(AlvrLogLevel(ALVR_LOG_LEVEL_INFO.rawValue), message)
    }

    // Whether this headset can report codes, told to the streamer right after alvr_initialize
    static var isAvailable: Bool {
        ImageTrackingProvider.isSupported && !ReferenceImage.loadReferenceImages(inGroupNamed: referenceImageGroup).isEmpty
    }

    init() {
        let referenceImages = ReferenceImage.loadReferenceImages(inGroupNamed: MarkerTracker.referenceImageGroup)
        if ImageTrackingProvider.isSupported && !referenceImages.isEmpty {
            imageTracking = ImageTrackingProvider(referenceImages: referenceImages)
        }
        else {
            MarkerTracker.log("QR code tracking is not available, reference images: \(referenceImages.count)")
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
                    // A scale factor far from 1 means the reference image's size is not the printed one
                    MarkerTracker.log("QR code \"\(id)\" seen at \(anchor.originFromAnchorTransform.columns.3), scale factor \(anchor.estimatedScaleFactor)")
                }
                markers[id] = Marker(
                    originFromMarker: anchor.originFromAnchorTransform * MarkerTracker.anchorFromMarker,
                    size: Float(anchor.referenceImage.physicalSize.width) * anchor.estimatedScaleFactor)
            }
            else if markers.removeValue(forKey: id) != nil {
                MarkerTracker.log("QR code \"\(id)\" lost")
            }
            objc_sync_exit(markersLock)
        }
    }

    // Reports the markers in view every sendInterval, in the space the tracking is sent in, with the
    // timestamp of the tracking sent along
    func send(steamVRFromApple: simd_float4x4, timestampNS: UInt64) {
        guard imageTracking != nil else {
            // init's message comes before the connection, so the streamer never gets it
            if !reportedUnavailable {
                reportedUnavailable = true
                MarkerTracker.log("QR code tracking is not available (not supported, or no reference images in \"\(MarkerTracker.referenceImageGroup)\")")
            }
            return
        }

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
            return AlvrMarker(text: id, pose: AlvrPose(simd_quaternion(transform), transform.columns.3), size: marker.size)
        }
        alvr_send_markers(timestampNS, alvrMarkers, UInt64(alvrMarkers.count))
    }
}
