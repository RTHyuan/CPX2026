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
        CVPixelBufferLockBaseAddress(buffer,.readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
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
        switch plane.classification { case .floor, .none: break; default: return nil }
        let matrix=plane.transform
        let y=Double(matrix.columns.3.y)
        guard (0.55...2.15).contains(camera.y-y) else { return nil }
        let polygon=plane.geometry.boundaryVertices.map { p in let q=matrix*SIMD4<Float>(p,1); return V3(Double(q.x),Double(q.y),Double(q.z)) }
        guard polygon.count>=3 else { return nil }
        self.init(y:y,polygon:polygon)
    }
}

final class NearVision {
    private let assessment=GroundAssessment()
    func inspect(_ frame: ARFrame, pose p: FramePose, semantic:[Sighting]) -> NearField {
        let image=FloorImage(frame.capturedImage,pose:p)
        guard image?.visible == true, p.normal else {
            return assessment.inspect(image:image,pose:p,planes:[],features:[],observations:[],personOK:false)
        }
        let human=VNDetectHumanRectanglesRequest(); human.upperBodyOnly=false
        let handler=VNImageRequestHandler(cvPixelBuffer:frame.capturedImage,orientation:CGImagePropertyOrientation(rawValue:UInt32(p.exif)) ?? .right)
        let personOK=(try? handler.perform([human])) != nil
        let humans: [Sighting] = (human.results ?? []).filter { $0.confidence >= 0.48 }.map { .init(kind:.person,box:ImageBox(vision:$0.boundingBox),confidence:Double($0.confidence)) }
        let planes=frame.anchors.compactMap { ($0 as? ARPlaneAnchor).flatMap { FloorPatch($0,camera:p.position) } }
        let depth=frame.sceneDepth
        if let depth { CVPixelBufferLockBaseAddress(depth.depthMap,.readOnly); if let c=depth.confidenceMap { CVPixelBufferLockBaseAddress(c,.readOnly) } }
        defer { if let depth { CVPixelBufferUnlockBaseAddress(depth.depthMap,.readOnly); if let c=depth.confidenceMap { CVPixelBufferUnlockBaseAddress(c,.readOnly) } } }
        return assessment.inspect(image:image,pose:p,planes:planes,features:frame.rawFeaturePoints?.points.map(V3.init) ?? [],
                                  observations:semantic+humans,personOK:personOK,depth:depth.map { data in { uv in Self.range(data,uv) } })
    }
    private static func range(_ depth:ARDepthData,_ uv:(Double,Double)) -> Double? {
        let map=depth.depthMap, x=min(CVPixelBufferGetWidth(map)-1,Int(uv.0*Double(CVPixelBufferGetWidth(map)))), y=min(CVPixelBufferGetHeight(map)-1,Int(uv.1*Double(CVPixelBufferGetHeight(map))))
        guard let data=CVPixelBufferGetBaseAddress(map),let conf=depth.confidenceMap,let bytes=CVPixelBufferGetBaseAddress(conf), bytes.load(fromByteOffset:y*CVPixelBufferGetBytesPerRow(conf)+x,as:UInt8.self)>=1 else {return nil}
        let d=Double(data.load(fromByteOffset:y*CVPixelBufferGetBytesPerRow(map)+x*4,as:Float.self)); return d.isFinite && d>0 ? d:nil
    }
}
