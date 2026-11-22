import SwiftUI
import AVFoundation
import ImageIO
import ARKit
import Vision
import CoreImage

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

private extension FloorImage {
    var containsGraphic: Bool {
        var edges = 0
        for y in stride(from: 3, to: h - 10, by: 2) {
            for x in stride(from: 3, to: w - 3, by: 2) {
                if max(abs(value(x-1,y)-value(x+1,y)), abs(value(x,y-1)-value(x,y+1))) > 32 {
                    edges += 1
                    if edges >= 16 { return true }
                }
            }
        }
        return false
    }
}

struct KeyObservation {
    let pose: FramePose, features: [Sighting], signs: FrameResult?, jpeg: Data?, sentWidth: Int, sentHeight: Int
    var sceneSignature: UInt64? = nil
}
enum CameraEvent {
    case state(CaptureState), frame(FrameResult, sampledAt: TimeInterval), error(String)
    case pose(FramePose), near(NearField), key(KeyObservation)
    #if DEBUG && targetEnvironment(simulator)
    case preview(UIImage)
    #endif
}

/// The delegate replaces this single slot. Reading it never retains an ARFrame or its depth data.
private struct PreviewCapture {
    let id: FrameID
    let timestamp, receivedAt: TimeInterval
    let sensorOrientation: CGImagePropertyOrientation
    let buffer: CVPixelBuffer
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
    private var lastPublished:FramePose?, lastAssessed: NearField?
    private var latestPreview: PreviewCapture? // protected by gate, published with lastPublished
    fileprivate func previewCapture() -> PreviewCapture? { gate.sync { latestPreview } }
    @MainActor fileprivate weak var previewSurface: CameraPreview.Surface?
    private var acceptFramesAfter = TimeInterval.infinity // frames queue only
    func latestPose() -> FramePose? { gate.sync { lastPublished } }
    func latestAssessment() -> (FramePose?, NearField?) { gate.sync { (lastPublished, lastAssessed) } }
    private var stream:(id:UUID,target:Destination,cloud:Bool,event:(CameraEvent)->Void)?
    private var world=0, sequence=0, orientation:CGImagePropertyOrientation = .right
    private var origin:FramePose?, lastNear = -Double.infinity, lastSigns = -Double.infinity
    private var nearBusy=false, signsBusy=false, burst=true, lastNormal=false
    private var nearEngine=NearVision(), recentObjects:(FramePose,[Sighting])?
    private let reader=SignVision()
    #if DEBUG && targetEnvironment(simulator)
    // Construct the feed on the capture queue, including its one-time loopback pixel load.
    private lazy var replay = SimulatorFeed()
    private let evidence = SimulatorEvidenceTape()
    // Accessed only on the serial semantics queue. SimulatorFeed retains immutable BGRA pixels.
    private var lastReplayRead: (buffer: CVPixelBuffer, capture: FrameID, target: Destination, frame: FrameResult, scene: SceneClues)?
    private var replayReading = false
    private var replayIndex=0
    var isReplaying: Bool { ProcessInfo.processInfo.environment["PATHSENSE_TEST_CAMERA"] != nil }
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
        // An interruption can restart this very same ARSession with callbacks already enqueued.
        acceptFramesAfter = session.currentFrame?.timestamp ?? -.infinity
        session.run(config,options:[.resetTracking,.removeExistingAnchors]); stream?.event(.state(.ready))
    }
    private func resetWorld() {
        world+=1; sequence=0; origin=nil; lastNormal=false; burst=true; recentObjects=nil
        lastNear = -.infinity; lastSigns = -.infinity; nearEngine=NearVision()
        gate.sync { lastPublished=nil; lastAssessed=nil; latestPreview=nil }
        // A suspended display link may not tick when entering the background.
        DispatchQueue.main.async { [weak self] in self?.previewSurface?.clearIfWorldChanged() }
    }
    func stop() { frames.async {
        self.stream = nil
        self.acceptFramesAfter = .infinity
        let old = self.session
        old?.delegate = nil
        self.resetWorld()
        old?.pause()
        self.gate.sync { self.activeSession = nil }
    } }
    func sessionWasInterrupted(_ session: ARSession) {
        guard session === self.session else { return }
        acceptFramesAfter = .infinity
        resetWorld()
        stream?.event(.state(.interrupted))
    }
    func sessionInterruptionEnded(_ session:ARSession) { if session === self.session && stream != nil { run() } }
    func session(_ session: ARSession, didFailWithError error: Error) {
        guard session === self.session else { return }
        acceptFramesAfter = .infinity
        resetWorld()
        stream?.event(.state(.failed("位置追踪中断。请站定，点重试相机。")))
    }
    func session(_ session:ARSession,didUpdate frame:ARFrame) {
        guard session === self.session, let stream, frame.timestamp > acceptFramesAfter else { return }
        let quality:String
        switch frame.camera.trackingState { case .normal:quality="normal"; case .notAvailable:quality="unavailable"; case .limited(let why):quality="limited_\(why)" }
        if quality != "normal" && lastNormal { resetWorld() }
        lastNormal=quality == "normal"; sequence+=1
        let m=frame.camera.transform, k=frame.camera.intrinsics
        var p=FramePose(id:.init(session:stream.id,world:world,frame:sequence),time:frame.timestamp,
          transform:(0..<4).flatMap { c in (0..<4).map { Double(m[c][$0]) } },intrinsics:(0..<3).flatMap { c in (0..<3).map { Double(k[c][$0]) } },
          width:CVPixelBufferGetWidth(frame.capturedImage),height:CVPixelBufferGetHeight(frame.capturedImage),exif:Int(orientation.rawValue),tracking:quality)
        if origin == nil && p.normal { origin=p }; if let origin { p.headingDelta=turnAngle(p.heading-origin.heading); p.horizontalDelta=p.position.groundDistance(origin.position) }
        let pose = p
        let capture = PreviewCapture(id: pose.id, timestamp: frame.timestamp, receivedAt: CACurrentMediaTime(),
                                     sensorOrientation: orientation, buffer: frame.capturedImage)
        gate.sync { lastPublished=pose; latestPreview=capture }
        stream.event(.pose(pose))
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
            var measurement = engine.inspect(frame,pose:pose,semantic:objects)
            measurement.hasDepthMap = frame.sceneDepth != nil
            measurement.hasConfidenceMap = frame.sceneDepth?.confidenceMap != nil
            let near = measurement
            self.frames.async {
                self.nearBusy=false
                guard self.stream?.id==stream.id && self.world==pose.id.world else { if wantKey { self.signsBusy=false }; return }
                self.gate.sync { self.lastAssessed = near }
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
    private func key(_ buffer:CVPixelBuffer,pose:FramePose,o:CGImagePropertyOrientation,near:NearField,target:Destination,cloud:Bool,localized:[Sighting], immutableReplay:Bool = false) -> KeyObservation {
        let image=CIImage(cvPixelBuffer:buffer).oriented(o)
        let (frame, scene) = keyPixels(buffer, orientation: o, image: image, target: target, capture: pose.id, immutableReplay: immutableReplay)
        let gray=FloorImage(buffer,pose:pose)
        var candidates=scene.doorBoxes.map { r -> Sighting in let b=ImageBox(vision:r); return .init(kind:.door,box:b,confidence:scene.geometricDoor ? 0.71:0.85,appearance:gray?.signature(b)) }
        candidates += (frame?.lines ?? []).filter { !$0.bounds.isEmpty && $0.confidence>=0.55 }.prefix(12).map { .init(kind:.sign,box:ImageBox(vision:$0.bounds),confidence:$0.landmarkConfidence,label:String($0.text.prefix(80))) }
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
        // Keyframe selection is rate-limited independently of near-field analysis. A door or
        // a corridor on a level view can guide the plan even when the floor is outside the image.
        if cloud && pose.normal {
            // Send upright, uncropped keyframes. Intrinsics still describe the original sensor
            // raster; FramePose.exif converts normalized upright boxes to sensor coordinates.
            if let cg = RouteVision.renderer.createCGImage(image, from: image.extent) {
                let still = UIImage(cgImage: cg)
                for quality in [0.82, 0.65, 0.48] {
                    if let data = still.jpegData(compressionQuality: quality), data.count <= CloudClient.imageLimit {
                        jpeg = data; width = cg.width; height = cg.height; break
                    }
                }
            }
        }
        return .init(pose:pose,features:candidates,signs:frame,jpeg:jpeg,sentWidth:width,sentHeight:height,sceneSignature:gray?.signature(.init(0.10,0.10,0.90,0.73)))
    }
    private func keyPixels(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, image: CIImage,
                           target: Destination, capture: FrameID, immutableReplay: Bool) -> (FrameResult?, SceneClues) {
        #if DEBUG && targetEnvironment(simulator)
        if immutableReplay, let last = lastReplayRead, last.buffer === buffer,
           last.capture.sameWorld(capture), last.target == target { return (last.frame, last.scene) }
        #endif
        var frame=try? reader.frame(buffer,orientation:orientation,target:target)
        let scene:SceneClues
        if frame?.scene.doorBoxes.isEmpty == false { scene=frame!.scene }
        else if frame?.scene == SceneClues(), !(frame?.lines.isEmpty ?? true) { scene=RouteVision.scene(VNImageRequestHandler(cvPixelBuffer:buffer,orientation:orientation),image:image) }
        else { scene=frame?.scene ?? SceneClues() }
        // OCR suppresses the reader's opportunistic classifier. Restore the independent
        // same-buffer scene before caching/delivering the frame to the journey.
        frame?.scene = scene
        #if DEBUG && targetEnvironment(simulator)
        if immutableReplay, let frame { lastReplayRead = (buffer, capture, target, frame, scene) }
        #endif
        return (frame, scene)
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
        guard let s = stream, s.id == id else { return }
        let t = ProcessInfo.processInfo.systemUptime
        let replaySample = evidence?.sample(at: replayIndex, time: t)
        let interval = replaySample?.observation.captures == nil ? 0.15 : 0.055
        if let replaySample, !replaySample.isFresh {
            replayIndex += 1
            frames.asyncAfter(deadline: .now() + interval) { [weak self] in self?.replayNext(id: id) }
            return
        }
        guard let sample = replay?.next(picture: replaySample?.picture, cloud: s.cloud && replaySample != nil) else { return }
        if let replaySample {
            let observation = replaySample.observation
            let buffer = sample.buffer
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let (pose, near) = observation.events(session: id, frame: replaySample.frame, tick: replaySample.tick, time: replaySample.time, width: width, height: height)
            gate.sync { lastPublished=pose; lastAssessed=near }; s.event(.pose(pose)); s.event(.near(near))
            if observation.captures != nil || observation.freezeCapture == true || replayIndex % 3 == 0 {
                s.event(.preview(sample.preview))
                if observation.readSigns == true {
                    // Run the same key builder as AR capture, once, against this retained buffer
                    // and its own near field. New poses and person hazards keep flowing during OCR.
                    if !replayReading {
                        replayReading = true
                        let localized = observation.features.filter { item in
                            !near.hazards.contains(item) || (item.kind != .person && !(item.kind == .steps && item.label == nil))
                        }
                        semantics.async {
                            var key = self.key(buffer, pose: pose, o: .up, near: near, target: s.target, cloud: s.cloud, localized: localized, immutableReplay: true)
                            key.sceneSignature = sample.signature
                            let captured = key
                            self.frames.async {
                                self.replayReading = false
                                guard self.stream?.id == id, self.stream?.target == s.target,
                                      self.latestPose()?.id.sameWorld(pose.id) == true else { return }
                                s.event(.key(captured))
                            }
                        }
                    }
                } else {
                    // Geometry-only or relay-only tape. No local recognition runs on these pixels.
                    let jpeg = s.cloud && pose.normal ? sample.preview.jpegData(compressionQuality: 0.65) : nil
                    s.event(.key(.init(pose: pose, features: observation.features, signs: nil, jpeg: jpeg,
                                       sentWidth: jpeg == nil ? 0 : width, sentHeight: jpeg == nil ? 0 : height, sceneSignature: sample.signature)))
                }
            }
            replayIndex += 1; frames.asyncAfter(deadline:.now()+interval) { [weak self] in self?.replayNext(id:id) }; return
        }
        s.event(.preview(sample.preview))
        if let result=try? reader.frame(sample.buffer,orientation:.up,target:s.target) { s.event(.frame(result,sampledAt:t)) }
        frames.asyncAfter(deadline:.now()+max(0.02,0.55-(ProcessInfo.processInfo.systemUptime-t))) { [weak self] in self?.replayNext(id:id) }
    }
    #endif
}

/// Rotation is relative to the rear sensor (native landscape-right). Crop in upright CI
/// coordinates, then move the crop to the destination origin before asking CI for pixels.
private struct PreviewLayout: Equatable {
    let pixels: CGSize
    let orientation: CGImagePropertyOrientation

    func centerCrop(_ extent: CGRect, to size: CGSize) -> CGRect {
        let scale = max(size.width / extent.width, size.height / extent.height)
        let width = size.width / scale, height = size.height / scale
        return CGRect(x: extent.midX - width / 2, y: extent.midY - height / 2, width: width, height: height)
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
    func render(_ buffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        let crop = centerCrop(image.extent, to: pixels)
        let scaled = image.transformed(by: .init(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: .init(scaleX: pixels.width / crop.width, y: pixels.height / crop.height))
        return Self.context.createCGImage(scaled, from: CGRect(origin: .zero, size: pixels), format: .RGBA8,
                                          colorSpace: Self.sRGB, deferred: false)
    }
}

struct CameraPreview: UIViewRepresentable {
    let camera: SignCamera

    final class Surface: UIView {
        fileprivate weak var camera: SignCamera?
        private let picture = UIImageView(), status = UILabel()
        private let conversion = DispatchQueue(label: "PathSense.preview.CI", qos: .userInitiated)
        private var displayLink: CADisplayLink?
        private var inFlight = false, mount = 0
        private var lastRequested: FrameID?, presented: FrameID?, lastProgress = CACurrentMediaTime()
        private static let stalledText = "预览暂未更新，可暂停后继续。"
        private let stallInterval = 3.0
        #if DEBUG && !targetEnvironment(simulator)
        private var presentedCount = 0, conversionFailures = 0
        private var presentedTimestamp: TimeInterval?
        private var sensorLuma: CameraPreviewSnapshot.Luma?
        #endif

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = true
            backgroundColor = .black
            clipsToBounds = true
            picture.contentMode = .scaleAspectFill
            picture.frame = bounds
            picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(picture)
            status.textColor = .white
            status.font = .preferredFont(forTextStyle: .footnote)
            status.adjustsFontForContentSizeCategory = true
            status.textAlignment = .center
            status.numberOfLines = 0
            status.translatesAutoresizingMaskIntoConstraints = false
            addSubview(status)
            NSLayoutConstraint.activate([status.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                                         status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                                         status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)])
            clearFrame()
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        func bind(_ newCamera: SignCamera?) {
            guard camera !== newCamera else { return }
            if camera?.previewSurface === self { camera?.previewSurface = nil }
            camera = newCamera
            updateMount()
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateMount()
        }
        private func updateMount() {
            mount += 1
            displayLink?.invalidate()
            displayLink = nil
            #if DEBUG && !targetEnvironment(simulator)
            presentedCount = 0
            conversionFailures = 0
            #endif
            clearFrame()
            guard window != nil, let camera else {
                if camera?.previewSurface === self { camera?.previewSurface = nil }
                return
            }
            camera.previewSurface = self
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 24, preferred: 24)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        private func clearFrame() {
            picture.image = nil
            lastRequested = nil
            presented = nil
            lastProgress = CACurrentMediaTime()
            status.text = "正在显示相机画面…"
            status.isHidden = false
            #if DEBUG && !targetEnvironment(simulator)
            presentedTimestamp = nil
            sensorLuma = nil
            #endif
        }
        fileprivate func clearIfWorldChanged() {
            if let presented, camera?.latestPose()?.id.sameWorld(presented) != true { clearFrame() }
        }
        private func layout(fallback: CGImagePropertyOrientation) -> PreviewLayout? {
            guard let scene = window?.windowScene, scene.activationState == .foregroundActive,
                  bounds.width >= 1, bounds.height >= 1 else { return nil }
            let orientation: CGImagePropertyOrientation = switch scene.effectiveGeometry.interfaceOrientation {
            case .portrait: .right
            case .portraitUpsideDown: .left
            case .landscapeLeft: .down
            case .landscapeRight: .up
            default: fallback
            }
            let scale = min(max(1, traitCollection.displayScale), 1280 / max(bounds.width, bounds.height))
            return PreviewLayout(pixels: CGSize(width: max(1, (bounds.width * scale).rounded()),
                                                height: max(1, (bounds.height * scale).rounded())), orientation: orientation)
        }
        @objc private func tick() {
            guard let camera else { return }
            let latest = camera.previewCapture(), now = CACurrentMediaTime()
            if let presented, latest?.id.sameWorld(presented) != true { clearFrame() }
            if now - lastProgress >= stallInterval, presented != nil || status.text != Self.stalledText {
                if presented != nil { clearFrame() }
                status.text = Self.stalledText
            }
            guard !inFlight, let latest, latest.id != lastRequested, now - latest.receivedAt < stallInterval,
                  let target = layout(fallback: latest.sensorOrientation) else { return }
            // Until the main thread has consumed the result, all intervening captures simply
            // replace the camera's one slot. The capture delegate never waits for conversion.
            inFlight = true
            lastRequested = latest.id
            let ticket = mount, id = latest.id, receivedAt = latest.receivedAt, fallback = latest.sensorOrientation
            #if DEBUG && !targetEnvironment(simulator)
            let timestamp = latest.timestamp
            #endif
            conversion.async { [weak self, weak camera] in
                let image = autoreleasepool { target.render(latest.buffer) }
                #if DEBUG && !targetEnvironment(simulator)
                let luma = CameraPreviewSnapshot.sensorLuma(latest.buffer, layout: target)
                #endif
                DispatchQueue.main.async { [weak self, weak camera] in
                    guard let self else { return }
                    self.inFlight = false
                    guard self.mount == ticket, let camera, self.camera === camera,
                          camera.latestPose()?.id.sameWorld(id) == true, self.layout(fallback: fallback) == target,
                          CACurrentMediaTime() - receivedAt < self.stallInterval else { return }
                    guard let image else {
                        #if DEBUG && !targetEnvironment(simulator)
                        self.conversionFailures += 1
                        #endif
                        return
                    }
                    self.picture.image = UIImage(cgImage: image)
                    self.presented = id
                    self.lastProgress = CACurrentMediaTime()
                    self.status.isHidden = true
                    #if DEBUG && !targetEnvironment(simulator)
                    self.presentedCount += 1
                    self.presentedTimestamp = timestamp
                    self.sensorLuma = luma
                    #endif
                }
            }
        }
    }

    func makeUIView(context: Context) -> Surface {
        let view = Surface(frame: .zero)
        view.bind(camera)
        return view
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Surface, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, let height = proposal.height, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }
    func updateUIView(_ uiView: Surface, context: Context) { uiView.bind(camera) }
    static func dismantleUIView(_ uiView: Surface, coordinator: ()) { uiView.bind(nil) }
}

#if DEBUG && !targetEnvironment(simulator)
/// Safe to encode. Pixel samples exist only during the measurement, never in the report.
struct CameraPreviewSnapshot: Encodable {
    struct Luma: Encodable {
        let mean, standardDeviation, darkFraction: Double // 0...255 luma, fraction at or below 8
        fileprivate init(_ values: [Double]) {
            let n = Double(values.count), average = values.reduce(0, +) / n
            mean = average
            standardDeviation = sqrt(values.reduce(0) { $0 + ($1 - average) * ($1 - average) } / n)
            darkFraction = Double(values.filter { $0 <= 8 }.count) / n
        }
    }
    var state = "unmounted"
    var arSession: UUID?, latestFrame: FrameID?, presentedFrame: FrameID?
    var capturedTimestamp: TimeInterval?, latestAgeMS: Int?, presentedAgeMS: Int?
    var presentedCount = 0, conversionFailures = 0
    var visibleFraction = 0.0
    var sensorLuma: Luma?, expectedLuma: Luma?, viewLuma: Luma?
    var meanAbsoluteRGBError: Double? // 0...255, paired samples from the same frame and viewport

    // An independent check upstream of CI. Sample Y' from the center crop of the actual
    // rear buffer. A 90-degree rotation swaps the aspect, but preserves these statistics.
    fileprivate static func sensorLuma(_ buffer: CVPixelBuffer, layout: PreviewLayout) -> Luma? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(buffer) >= 1, CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        guard width > 0, height > 0 else { return nil }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), yPlane = base.assumingMemoryBound(to: UInt8.self)
        let rotated = layout.orientation == .right || layout.orientation == .left
        let size = rotated ? CGSize(width: layout.pixels.height, height: layout.pixels.width) : layout.pixels
        let rect = layout.centerCrop(CGRect(x: 0, y: 0, width: width, height: height), to: size)
        var samples = [Double]()
        for row in 0..<16 {
            let y = min(height - 1, Int(rect.minY + (CGFloat(row) + 0.5) * rect.height / 16))
            for col in 0..<24 {
                let x = min(width - 1, Int(rect.minX + (CGFloat(col) + 0.5) * rect.width / 24))
                let value = Double(yPlane[y * stride + x])
                samples.append(format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? min(255, max(0, (value - 16) * 255 / 219)) : value)
            }
        }
        return Luma(samples)
    }
}

extension SignCamera {
    /// Main-thread device-check entry point. Never mounts a view, opens a camera, or writes an image.
    @MainActor func debugPreviewSnapshot() -> CameraPreviewSnapshot {
        var report = CameraPreviewSnapshot()
        gate.sync {
            report.arSession = activeSession?.identifier
            if activeSession != nil, let latestPreview {
                report.latestFrame = latestPreview.id
                report.latestAgeMS = Int((CACurrentMediaTime() - latestPreview.receivedAt) * 1_000)
            }
        }
        previewSurface?.measure(into: &report)
        return report
    }
}

extension CameraPreview.Surface {
    fileprivate func measure(into report: inout CameraPreviewSnapshot) {
        report.presentedCount = presentedCount
        report.conversionFailures = conversionFailures
        report.presentedFrame = presented
        report.capturedTimestamp = presentedTimestamp
        report.sensorLuma = sensorLuma
        guard let window, window.windowScene?.activationState == .foregroundActive else { report.state = "notForeground"; return }
        guard !bounds.isEmpty else { report.state = "emptyBounds"; return }
        var visible = bounds, ancestor: UIView? = self
        while let view = ancestor {
            if view.isHidden || view.alpha < 0.01 { report.state = "hidden"; return }
            if view.clipsToBounds || view === window { visible = visible.intersection(convert(view.bounds, from: view)) }
            ancestor = view.superview
        }
        guard visible.width >= 1, visible.height >= 1 else { report.state = "offscreen"; return }
        report.visibleFraction = Double(visible.width * visible.height / (bounds.width * bounds.height))
        guard let latest = report.latestFrame else { report.state = "waitingForCapture"; return }
        guard let presented, presented.sameWorld(latest), status.isHidden, let reference = picture.image else {
            report.state = "waitingForPresentation"; return
        }
        report.presentedAgeMS = Int((CACurrentMediaTime() - lastProgress) * 1_000)
        let w = 32, h = 24
        // Render the same visible rect into identical sRGB contexts. One samples the assigned
        // upright CI product. Only the second reads back the actual mounted UIKit hierarchy.
        func thumbnail(_ draw: () -> Bool) -> [UInt8]? {
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            let complete = rgba.withUnsafeMutableBytes { bytes in
                guard let color = CGColorSpace(name: CGColorSpace.sRGB),
                      let ctx = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: color, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: CGFloat(w) / visible.width, y: -CGFloat(h) / visible.height)
                ctx.translateBy(x: -visible.minX, y: -visible.minY)
                UIGraphicsPushContext(ctx)
                defer { UIGraphicsPopContext() }
                let complete = draw()
                ctx.flush()
                return complete
            }
            return complete ? rgba : nil
        }
        let fillScale = max(bounds.width / reference.size.width, bounds.height / reference.size.height)
        let fillSize = CGSize(width: reference.size.width * fillScale, height: reference.size.height * fillScale)
        let destination = CGRect(x: bounds.midX - fillSize.width / 2, y: bounds.midY - fillSize.height / 2,
                                 width: fillSize.width, height: fillSize.height)
        guard let expected = thumbnail({ reference.draw(in: destination); return true }),
              let actual = thumbnail({ self.drawHierarchy(in: self.bounds, afterScreenUpdates: true) }) else {
            report.state = "snapshotIncomplete"; return
        }
        guard camera?.previewSurface === self, self.presented == presented,
              camera?.latestPose()?.id.sameWorld(presented) == true else {
            report.state = "frameChanged"; return
        }
        guard stride(from: 3, to: actual.count, by: 4).contains(where: { actual[$0] != 0 }) else {
            report.state = "snapshotIncomplete"; return
        }
        func luma(_ p: [UInt8], _ i: Int) -> Double {
            0.299 * Double(p[i]) + 0.587 * Double(p[i + 1]) + 0.114 * Double(p[i + 2])
        }
        var referenceY: [Double] = [], viewY: [Double] = [], error = 0
        for i in stride(from: 0, to: actual.count, by: 4) {
            referenceY.append(luma(expected, i)); viewY.append(luma(actual, i))
            for channel in i..<(i + 3) { error += abs(Int(expected[channel]) - Int(actual[channel])) }
        }
        report.expectedLuma = .init(referenceY)
        report.viewLuma = .init(viewY)
        report.meanAbsoluteRGBError = Double(error) / Double(3 * w * h)
        report.state = "sampled"
    }
}
#endif

#if DEBUG && targetEnvironment(simulator)
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
    private var signature: UInt64?

    init?() {
        let env = ProcessInfo.processInfo.environment
        guard let fixture = env["PATHSENSE_TEST_CAMERA"] else { return nil }
        if let raw = env["PATHSENSE_TEST_FRAME_SOURCE"] {
            // The runner serves private field captures on a per-launch loopback capability. Names,
            // paths and labels never enter navigation. Preserve the full upright source pixels.
            guard let url = URL(string: raw), url.scheme == "http", url.host == "127.0.0.1",
                  let bytes = try? Data(contentsOf: url), let frames = try? PropertyListDecoder().decode([Data].self, from: bytes),
                  !frames.isEmpty else { preconditionFailure("Cannot load field pixels from the local UI runner") }
            pictures = frames.compactMap { UIImage(data: $0) }
            precondition(pictures.count == frames.count, "Unreadable field capture")
        } else {
            pictures = (0..<12).compactMap { env["PATHSENSE_TEST_PIXELS_\($0)"].flatMap { Data(base64Encoded: $0) }.flatMap { UIImage(data: $0) } }
        }
        repeats = max(2, Int(env["PATHSENSE_TEST_HOLD"] ?? "") ?? 7)
        switch fixture {
        case "denied": state = .denied
        case "restricted": state = .restricted
        case "interrupted": state = .interrupted
        default: state = pictures.isEmpty ? .unavailable : .ready
        }
    }
    func next(picture: Int?, cloud: Bool) -> (buffer: CVPixelBuffer, preview: UIImage, signature: UInt64?)? {
        guard !pictures.isEmpty else { return nil }
        let current = picture ?? min(count / repeats, pictures.count - 1)
        precondition(pictures.indices.contains(current), "Missing simulator image at index \(current)")
        if index != current || buffer == nil {
            guard let cg = pictures[current].cgImage else { return nil }
            let image = CIImage(cgImage: cg)
            var next: CVPixelBuffer?
            let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary]
            guard CVPixelBufferCreate(nil, cg.width, cg.height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &next) == kCVReturnSuccess, let next else { return nil }
            renderer.render(image, to: next, bounds: image.extent, colorSpace: CGColorSpaceCreateDeviceRGB())
            buffer = next
            index = current
            signature = nil
        }
        // The replay buffer is BGRA rather than a planar camera buffer. Sample its image once
        // for the same luminance descriptor used to select a newly visible sign for upload.
        if cloud, signature == nil, let cg = pictures[current].cgImage {
            var gray = [UInt8](repeating: 0, count: 96 * 96)
            let drawn = gray.withUnsafeMutableBytes { bytes in
                guard let ctx = CGContext(data: bytes.baseAddress, width: 96, height: 96, bitsPerComponent: 8,
                                          bytesPerRow: 96, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 96, height: 96)); return true
            }
            if drawn { signature = FloorImage(pixels: gray).signature(.init(0.10, 0.10, 0.90, 0.73)) }
        }
        // Also populate the preview when a paused UI resumes on an unchanged frame.
        count += 1
        guard let buffer else { return nil }
        return (buffer, pictures[current], signature)
    }
}
#endif
