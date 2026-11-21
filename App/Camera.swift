import SwiftUI
import AVFoundation
import ImageIO

enum CaptureState: Equatable {
    case starting, ready, denied, restricted, unavailable, interrupted, failed(String)
    var description: String {
        switch self {
        case .starting: return "正在打开相机…"
        case .ready: return "相机已就绪"
        case .denied: return "相机权限未开启。请在设置里允许 PathSense 使用相机。"
        case .restricted: return "这台设备限制了相机使用。请检查设备的使用限制，再重试。"
        case .unavailable: return "当前没有可用的后置相机。请在配有后置相机的 iPhone 上使用导航。"
        case .interrupted: return "相机使用已中断，恢复后可继续扫描。"
        case .failed(let reason): return reason
        }
    }
}

import ARKit
import Vision
import MetalKit

struct KeyObservation {
    let pose: FramePose, features: [Sighting], signs: FrameResult?, jpeg: Data?, sentWidth: Int, sentHeight: Int
}
enum CameraEvent {
    case state(CaptureState), frame(FrameResult, sampledAt: TimeInterval), error(String)
    case pose(FramePose), near(NearField), key(KeyObservation)
    #if DEBUG && targetEnvironment(simulator)
    case preview(UIImage)
    #endif
}

/// The session delegate never waits for Vision or networking. Each worker may hold at most one capture.
final class SignCamera: NSObject, ARSessionDelegate {
    private var activeSession: ARSession?
    var session: ARSession? { gate.sync { activeSession } }
    private let frames=DispatchQueue(label:"PathSense.AR.frames",qos:.userInitiated)
    private let reactive=DispatchQueue(label:"PathSense.AR.near",qos:.userInitiated)
    private let furnitureWorker=DispatchQueue(label:"PathSense.AR.furniture",qos:.userInitiated)
    private var furnitureBusy=false, lastFurniture = -Double.infinity
    private final class FurnitureSample: @unchecked Sendable {
        let ready=DispatchGroup(); var items:[Sighting]=[]
        init() {ready.enter()}
    }
    private let semantics=DispatchQueue(label:"PathSense.AR.signs",qos:.utility)
    private let gate=DispatchQueue(label:"PathSense.AR.latest")
    private var lastPublished:FramePose?
    func latestPose() -> FramePose? { gate.sync { lastPublished } }
    private var stream:(id:UUID,target:Destination,cloud:Bool,event:(CameraEvent)->Void)?
    private var world=0, sequence=0, orientation:CGImagePropertyOrientation = .right
    private var origin:FramePose?, lastNear = -Double.infinity, lastSigns = -Double.infinity
    private var nearBusy=false, signsBusy=false, burst=true, lastNormal=false
    private var nearEngine=NearVision(), recentObjects:(FramePose,[Sighting])?
    private let reader=SignVision()
    #if DEBUG && targetEnvironment(simulator)
    private let replay=SimulatorFeed()
    private lazy var evidence: [SimulatorEvidence] = {
        guard let text=ProcessInfo.processInfo.environment["PATHSENSE_TEST_EVIDENCE"] else {return []}
        return (try? JSONDecoder().decode([SimulatorEvidence].self,from:Data(text.utf8))) ?? []
    }()
    private var replayIndex=0
    var isReplaying:Bool { replay != nil }
    #endif
    func updateOrientation(_ device: UIDeviceOrientation) {
        let o:CGImagePropertyOrientation
        switch device { case .portrait:o = .right; case .portraitUpsideDown:o = .left; case .landscapeLeft:o = .up; case .landscapeRight:o = .down; default:return }
        frames.async { self.orientation=o }
    }
    func updateTarget(_ target:Destination) { frames.async { self.stream?.target=target; self.burst=true } }
    func requestKey() { frames.async { self.burst=true } }
    func start(id:UUID,target:Destination,cloud:Bool=false,event:@escaping(CameraEvent)->Void) {
        frames.async {
            self.stream=(id,target,cloud,event)
            #if DEBUG && targetEnvironment(simulator)
            if let replay=self.replay { self.replayIndex=0; event(.state(replay.state)); if replay.state == .ready { self.replayNext(id:id) }; return }
            #endif
            guard ARWorldTrackingConfiguration.isSupported else { event(.state(.unavailable)); return }
            switch AVCaptureDevice.authorizationStatus(for:.video) {
            case .authorized: self.run()
            case .restricted: event(.state(.restricted))
            case .notDetermined: AVCaptureDevice.requestAccess(for:.video) { granted in self.frames.async { guard self.stream?.id==id else {return}; if granted { self.run() } else { event(.state(.denied)) } } }
            default:event(.state(.denied))
            }
        }
    }
    private func run() {
        let session = self.session ?? ARSession()
        session.delegateQueue=frames; session.delegate=self; gate.sync { activeSession=session }
        resetWorld(); let config=ARWorldTrackingConfiguration(); config.worldAlignment = .gravity
        config.planeDetection=[.horizontal]; config.providesAudioData=false
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { config.frameSemantics.insert(.sceneDepth) }
        session.run(config,options:[.resetTracking,.removeExistingAnchors]); stream?.event(.state(.ready))
    }
    private func resetWorld() {
        world+=1; sequence=0; origin=nil; lastNormal=false; burst=true; recentObjects=nil
        lastNear = -.infinity; lastSigns = -.infinity; nearEngine=NearVision(); gate.sync { lastPublished=nil }
    }
    func stop() { frames.async {
        self.stream=nil; let old=self.session; old?.delegate=nil; old?.pause()
        self.gate.sync { self.activeSession=nil }; self.resetWorld()
    } }
    func sessionWasInterrupted(_ session:ARSession) { guard session === self.session else {return}; resetWorld(); stream?.event(.state(.interrupted)) }
    func sessionInterruptionEnded(_ session:ARSession) { if session === self.session && stream != nil { run() } }
    func session(_ session:ARSession,didFailWithError error:Error) { guard session === self.session else {return}; resetWorld(); stream?.event(.state(.failed("位置追踪中断。请站定，点重试相机。"))) }
    func session(_ session:ARSession,didUpdate frame:ARFrame) {
        guard session === self.session, let stream else { return }
        let quality:String
        switch frame.camera.trackingState { case .normal:quality="normal"; case .notAvailable:quality="unavailable"; case .limited(let why):quality="limited_\(why)" }
        if quality != "normal" && lastNormal { resetWorld() }
        lastNormal=quality == "normal"; sequence+=1
        let m=frame.camera.transform, k=frame.camera.intrinsics
        var p=FramePose(id:.init(session:stream.id,world:world,frame:sequence),time:frame.timestamp,
          transform:(0..<4).flatMap { c in (0..<4).map { Double(m[c][$0]) } },intrinsics:(0..<3).flatMap { c in (0..<3).map { Double(k[c][$0]) } },
          width:CVPixelBufferGetWidth(frame.capturedImage),height:CVPixelBufferGetHeight(frame.capturedImage),exif:Int(orientation.rawValue),tracking:quality)
        if origin == nil && p.normal { origin=p }; if let origin { p.headingDelta=turnAngle(p.heading-origin.heading); p.horizontalDelta=p.position.groundDistance(origin.position) }
        let pose=p; gate.sync { lastPublished=pose }; stream.event(.pose(pose))
        guard !nearBusy, pose.time-lastNear>=0.105 else {return}; nearBusy=true; lastNear=pose.time
        let engine=nearEngine, o=orientation
        let objects=recentObjects.flatMap { old,items in old.id.sameWorld(pose.id) && pose.time-old.time<0.65 && abs(turnAngle(old.heading-pose.heading))<5 && old.position.groundDistance(pose.position)<0.12 ? items:nil } ?? []
        let wantKey = !signsBusy && !furnitureBusy && (burst || pose.time-lastSigns>=0.55)
        let furniture: FurnitureSample?
        if !furnitureBusy && (wantKey || pose.time-lastFurniture>=0.30) {
            let sample=FurnitureSample(), buffer=frame.capturedImage; furniture=sample; furnitureBusy=true; lastFurniture=pose.time
            furnitureWorker.async {
                sample.items=Self.furniture(buffer,o); sample.ready.leave()
                self.frames.async {
                    self.furnitureBusy=false
                    if self.world==pose.id.world && self.stream?.id==stream.id { self.recentObjects=(pose,sample.items) }
                }
            }
        } else { furniture=nil }
        if wantKey { signsBusy=true; burst=false; lastSigns=pose.time }
        reactive.async {
            let near=engine.inspect(frame,pose:pose,semantic:objects)
            self.frames.async {
                self.nearBusy=false
                guard self.stream?.id==stream.id && self.world==pose.id.world else { if wantKey { self.signsBusy=false }; return }
                stream.event(.near(near))
                if wantKey, let furniture {
                    // Copy the buffer reference, not the ARFrame, for the slower worker.
                    let buffer=frame.capturedImage
                    furniture.ready.notify(queue:self.semantics) {
                        let key=self.key(buffer,pose:pose,o:o,near:near,target:stream.target,cloud:stream.cloud,localized:furniture.items)
                        self.frames.async {
                            self.signsBusy=false
                            guard self.stream?.id==stream.id && self.world==pose.id.world else {return}
                            stream.event(.key(key))
                        }
                    }
                }
            }
        }
    }
    private func key(_ buffer:CVPixelBuffer,pose:FramePose,o:CGImagePropertyOrientation,near:NearField,target:Destination,cloud:Bool,localized:[Sighting]) -> KeyObservation {
        let image=CIImage(cvPixelBuffer:buffer).oriented(o)
        let frame=try? reader.frame(buffer,orientation:o,target:target)
        let scene:SceneClues
        if frame?.scene.doorBoxes.isEmpty == false { scene=frame!.scene }
        else if frame?.scene == SceneClues(), !(frame?.lines.isEmpty ?? true) { scene=RouteVision.scene(VNImageRequestHandler(cvPixelBuffer:buffer,orientation:o),image:image) }
        else { scene=frame?.scene ?? SceneClues() }
        let gray=FloorImage(buffer,pose:pose)
        var candidates=scene.doorBoxes.map { r -> Sighting in let b=ImageBox(vision:r); return .init(kind:.door,box:b,confidence:scene.geometricDoor ? 0.71:0.85,appearance:gray?.signature(b)) }
        candidates += (frame?.lines ?? []).filter { !$0.bounds.isEmpty && $0.confidence>=0.55 }.prefix(12).map { .init(kind:.sign,box:ImageBox(vision:$0.bounds),confidence:Double($0.confidence),label:String($0.text.prefix(80))) }
        // Historical slow detections may veto movement, but never relabel a different keyframe.
        candidates += near.hazards.filter { $0.kind == .person || ($0.kind == .steps && $0.label == nil) } + localized
        let corridors=near.sectors.filter { $0.state == .free }
        for sector in corridors {
            let a=(pose.heading+Double(sector.angle)) * .pi/180
            let point=pose.position+V3(sin(a)*1.6,-0.65,-cos(a)*1.6)
            if let (u,v)=pose.project(point) {
                let b=ImageBox(max(0,u-0.075),max(0,v-0.09),min(1,u+0.075),min(1,v+0.12))
                if b.valid { candidates.append(.init(kind:.aisle_entrance,box:b,confidence:0.76)) }
            }
        }
        var jpeg:Data?, width=0,height=0
        if cloud && pose.normal && near.visible {
            let scale=min(1,768/max(image.extent.width,image.extent.height)); let small=image.transformed(by:.init(scaleX:scale,y:scale))
            if let cg=RouteVision.renderer.createCGImage(small,from:small.extent.integral) { jpeg=UIImage(cgImage:cg).jpegData(compressionQuality:0.64); width=cg.width;height=cg.height }
        }
        return .init(pose:pose,features:candidates,signs:frame,jpeg:jpeg,sentWidth:width,sentHeight:height)
    }
    private static func furniture(_ buffer:CVPixelBuffer,_ o:CGImagePropertyOrientation) -> [Sighting] {
        let handler=VNImageRequestHandler(cvPixelBuffer:buffer,orientation:o); var items:[Sighting]=[]
        for x in [0.0,0.30,0.60] {
            let rect=CGRect(x:x,y:0.04,width:0.40,height:0.62), request=VNClassifyImageRequest(); request.regionOfInterest=rect
            guard (try? handler.perform([request])) != nil else { continue }
            for hit in (request.results ?? []).prefix(8) where hit.confidence>0.60 {
                let kind:FeatureKind
                switch hit.identifier { case "chair","armchair","seat","bench":kind = .chair; case "stool","footstool":kind = .stool; case "stairs","staircase","stairway":kind = .steps; default:continue }
                items.append(.init(kind:kind,box:.init(vision:rect),confidence:Double(hit.confidence),label:hit.identifier)); break
            }
        }; return items
    }
    #if DEBUG && targetEnvironment(simulator)
    private func replayNext(id:UUID) {
        guard let s=stream,s.id==id,let sample=replay?.next() else {return}
        let t=ProcessInfo.processInfo.systemUptime
        if !evidence.isEmpty {
            let observation=evidence[min(replayIndex,evidence.count-1)]
            let (pose, near)=observation.events(session:id,sequence:replayIndex,time:t)
            gate.sync { lastPublished=pose }; s.event(.pose(pose)); s.event(.near(near))
            if replayIndex % 3 == 0 {
                if let preview=sample.preview { s.event(.preview(preview)); let jpeg=s.cloud ? preview.jpegData(compressionQuality:0.65):nil
                    s.event(.key(.init(pose:pose,features:observation.features,signs:nil,jpeg:jpeg,sentWidth:preview.cgImage?.width ?? 0,sentHeight:preview.cgImage?.height ?? 0))) }
            }
            replayIndex += 1; frames.asyncAfter(deadline:.now()+0.15) { [weak self] in self?.replayNext(id:id) }; return
        }
        if let preview=sample.preview {s.event(.preview(preview))}
        if let result=try? reader.frame(sample.buffer,orientation:.up,target:s.target) { s.event(.frame(result,sampledAt:t)) }
        frames.asyncAfter(deadline:.now()+max(0.02,0.55-(ProcessInfo.processInfo.systemUptime-t))) { [weak self] in self?.replayNext(id:id) }
    }
    #endif
}

struct CameraPreview:UIViewRepresentable {
    let session:ARSession?
    final class Surface:MTKView, MTKViewDelegate {
        weak var source:ARSession?
        private var renderer:CIContext?, commands: MTLCommandQueue?
        init(_ session:ARSession?) {
            let gpu=MTLCreateSystemDefaultDevice(); super.init(frame:.zero,device:gpu); source=session
            framebufferOnly=false; preferredFramesPerSecond=24; delegate=self
            if let gpu { renderer=CIContext(mtlDevice:gpu); commands=gpu.makeCommandQueue() }
        }
        required init(coder:NSCoder) { fatalError() }
        func mtkView(_ view:MTKView,drawableSizeWillChange size:CGSize) {}
        func draw(in view:MTKView) {
            guard let f=source?.currentFrame,let d=currentDrawable,let cmd=commands?.makeCommandBuffer(),let renderer else {return}
            let o:CGImagePropertyOrientation
            switch window?.windowScene?.effectiveGeometry.interfaceOrientation { case .landscapeLeft:o = .down; case .landscapeRight:o = .up; case .portraitUpsideDown:o = .left; default:o = .right }
            let image=CIImage(cvPixelBuffer:f.capturedImage).oriented(o), size=drawableSize
            let s=max(size.width/image.extent.width,size.height/image.extent.height)
            let scaled=image.transformed(by:.init(scaleX:s,y:s)); let rect=CGRect(x:scaled.extent.midX-size.width/2,y:scaled.extent.midY-size.height/2,width:size.width,height:size.height)
            renderer.render(scaled,to:d.texture,commandBuffer:cmd,bounds:rect,colorSpace:CGColorSpaceCreateDeviceRGB()); cmd.present(d); cmd.commit()
        }
    }
    func makeUIView(context:Context)->Surface { Surface(session) }
    func updateUIView(_ uiView:Surface,context:Context) { uiView.source=session }
}
#if DEBUG && targetEnvironment(simulator)
import CoreImage

/// Only the UI test runner owns fixtures. Supply pixels at the capture boundary;
/// no fixture labels, destinations, or expected results go into the navigator.
private final class SimulatorFeed {
    let state: CaptureState
    private let pictures: [UIImage]
    private let repeats: Int
    private let renderer = CIContext()
    private var count = 0
    private var index = -1
    private var buffer: CVPixelBuffer?

    init?() {
        let env = ProcessInfo.processInfo.environment
        guard let fixture = env["PATHSENSE_TEST_CAMERA"] else { return nil }
        pictures = (0..<12).compactMap { env["PATHSENSE_TEST_PIXELS_\($0)"].flatMap { Data(base64Encoded: $0) }.flatMap { UIImage(data: $0) } }
        repeats = max(2, Int(env["PATHSENSE_TEST_HOLD"] ?? "") ?? 7)
        switch fixture {
        case "denied": state = .denied
        case "restricted": state = .restricted
        case "interrupted": state = .interrupted
        default: state = pictures.isEmpty ? .unavailable : .ready
        }
    }
    func next() -> (buffer: CVPixelBuffer, preview: UIImage?)? {
        guard !pictures.isEmpty else { return nil }
        let current = min(count / repeats, pictures.count - 1)
        var preview: UIImage?
        if index != current || buffer == nil {
            guard let cg = pictures[current].cgImage else { return nil }
            let image = CIImage(cgImage: cg)
            var next: CVPixelBuffer?
            let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary]
            guard CVPixelBufferCreate(nil, cg.width, cg.height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &next) == kCVReturnSuccess, let next else { return nil }
            renderer.render(image, to: next, bounds: image.extent, colorSpace: CGColorSpaceCreateDeviceRGB())
            buffer = next
            index = current
        }
        // Also populate the preview when a paused UI resumes on an unchanged frame.
        preview = pictures[current]
        count += 1
        guard let buffer else { return nil }
        return (buffer, preview)
    }
}
#endif
