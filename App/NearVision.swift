import ARKit
import Vision

extension V3 {
    init(_ p: SIMD3<Float>) { self.init(Double(p.x),Double(p.y),Double(p.z)) }
}
extension ImageBox {
    init(vision r: CGRect) { self.init(r.minX, 1-r.maxY, r.maxX, 1-r.minY) }
}

extension FloorImage {
    init?(_ buffer: CVPixelBuffer, pose: FramePose) {
        let w=96, h=96
        var pixels=[UInt8](repeating:0,count:w*h)
        guard CVPixelBufferGetPlaneCount(buffer) >= 1 else { return nil }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base=CVPixelBufferGetBaseAddressOfPlane(buffer,0)?.assumingMemoryBound(to:UInt8.self) else { return nil }
        let stride=CVPixelBufferGetBytesPerRowOfPlane(buffer,0)
        let width=CVPixelBufferGetWidthOfPlane(buffer,0), height=CVPixelBufferGetHeightOfPlane(buffer,0)
        for y in 0..<h { for x in 0..<w {
            let (u,v)=pose.sensor((Double(x)+0.5)/Double(w),(Double(y)+0.5)/Double(h))
            pixels[y*w+x]=base[min(height-1,Int(v*Double(height)))*stride+min(width-1,Int(u*Double(width)))]
        } }
        self.init(pixels:pixels)
    }
}

extension FloorPatch {
    init?(_ plane:ARPlaneAnchor, camera:V3) {
        guard plane.alignment == .horizontal else { return nil }
        let surface: Surface
        switch plane.classification {
        case .floor: surface = .floor
        case .none: surface = .unclassified
        default: surface = .nonFloor
        }
        let matrix=plane.transform
        let y=Double(matrix.columns.3.y)
        guard (0.55...2.15).contains(camera.y-y) else { return nil }
        let polygon=plane.geometry.boundaryVertices.map { p in let q=matrix*SIMD4<Float>(p,1); return V3(Double(q.x),Double(q.y),Double(q.z)) }
        guard polygon.count>=3 else { return nil }
        self.init(y:y,polygon:polygon,surface:surface)
    }
}

extension LidarDepthFrame {
    init?(_ data: ARDepthData, pose: FramePose) {
        let map = data.depthMap
        guard let confidence = data.confidenceMap else { return nil }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8,
              CVPixelBufferGetWidth(confidence) == width, CVPixelBufferGetHeight(confidence) == height,
              CVPixelBufferLockBaseAddress(map, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard CVPixelBufferLockBaseAddress(confidence, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
        guard let depths = CVPixelBufferGetBaseAddress(map), let qualities = CVPixelBufferGetBaseAddress(confidence) else { return nil }
        let depthStride = CVPixelBufferGetBytesPerRow(map), confidenceStride = CVPixelBufferGetBytesPerRow(confidence)
        self.init(pose: pose, width: width, height: height) { x, y in
            let quality = qualities.load(fromByteOffset: y * confidenceStride + x, as: UInt8.self)
            let metres = depths.load(fromByteOffset: y * depthStride + x * MemoryLayout<Float>.stride, as: Float.self)
            return (Double(metres), quality)
        }
    }
}

final class NearVision {
    private let assessment = GroundAssessment()
    private var lastPose: FramePose?
    // Camera.run enables this semantic on supporting devices. A missing capture on such a
    // device must invalidate depth proof rather than falling through to a monocular clear.
    private let usesDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)

    func inspect(_ frame: ARFrame, pose p: FramePose, semantic: [Sighting]) -> NearField {
        let image = FloorImage(frame.capturedImage, pose: p)
        // An exposure spanning a large rotation/translation blurs image-based person checks even
        // when depth returns remain dense. Estimate smear at 0.75 m from successive capture poses.
        let prior = lastPose; lastPose = p
        let sharp: Bool
        if let prior, prior.id.sameWorld(p.id), (0.025...0.58).contains(p.time - prior.time) {
            let rotation = acos(min(1, max(-1, p.forward.dot(prior.forward))))
            let motion = rotation + (p.position - prior.position).length / 0.75
            sharp = motion * max(0, frame.camera.exposureDuration) / (p.time - prior.time) < 0.014
        } else { sharp = false }
        let usable = sharp && (usesDepth ? image?.exposed == true : image?.visible == true)
        guard usable, p.normal else {
            if usesDepth {
                return assessment.inspectLidar(pose: p, depth: nil, planes: [], observations: [], personOK: false, exposed: false)
            }
            return assessment.inspect(image: nil, pose: p, planes: [], features: [], observations: [], personOK: false)
        }
        let human = VNDetectHumanRectanglesRequest()
        human.upperBodyOnly = false
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.capturedImage,
            orientation: CGImagePropertyOrientation(rawValue: UInt32(p.exif)) ?? .right)
        let personOK = (try? handler.perform([human])) != nil
        let humans: [Sighting] = (human.results ?? []).filter { $0.confidence >= 0.48 }.map {
            .init(kind: .person, box: ImageBox(vision: $0.boundingBox), confidence: Double($0.confidence))
        }
        let planes = frame.anchors.compactMap { ($0 as? ARPlaneAnchor).flatMap { FloorPatch($0, camera: p.position) } }
        if usesDepth {
            let depth = frame.sceneDepth.flatMap { LidarDepthFrame($0, pose: p) }
            return assessment.inspectLidar(pose: p, depth: depth, planes: planes, observations: semantic + humans,
                                           personOK: personOK, exposed: usable, image: image)
        }
        return assessment.inspect(image: image, pose: p, planes: planes, features: frame.rawFeaturePoints?.points.map(V3.init) ?? [],
                                  observations: semantic + humans, personOK: personOK)
    }
}
