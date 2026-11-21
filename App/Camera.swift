import SwiftUI
import AVFoundation
import ImageIO

enum CaptureState: Equatable {
    case starting, ready, denied, unavailable, interrupted, failed(String)
    var description: String {
        switch self {
        case .starting: return "正在打开相机…"
        case .ready: return "相机已就绪"
        case .denied: return "相机权限未开启。可以在设置中允许相机，或选择照片识字。"
        case .unavailable: return "此设备当前没有可用的后置相机。可以选择照片或试用练习标牌。"
        case .interrupted: return "相机使用已中断，恢复后可继续扫描。"
        case .failed(let reason): return reason
        }
    }
}

enum CameraEvent { case state(CaptureState), frame(FrameResult, single: Bool, sampledAt: TimeInterval), error(String) }

/// Capture and inference use separate serial queues. `alwaysDiscardsLateVideoFrames` bounds the backlog.
final class SignCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let control = DispatchQueue(label: "PathSense.capture.session")
    private let frames = DispatchQueue(label: "PathSense.capture.frames", qos: .userInitiated)
    private let reader = SignVision()
    private var configured = false
    // Only accessed on the control queue.
    private var sessionID: UUID?
    private var sessionEvent: ((CameraEvent) -> Void)?
    // Only accessed on the frame queue.
    private var stream: (id: UUID, target: Destination, single: Bool, callback: (CameraEvent) -> Void)?
    private var orientation: CGImagePropertyOrientation = .right
    private var snapshotArmed = false
    private var lastFrame = -Double.infinity
    private var failureCount = 0

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(interruption(_:)), name: AVCaptureSession.wasInterruptedNotification, object: session)
        center.addObserver(self, selector: #selector(recover(_:)), name: AVCaptureSession.interruptionEndedNotification, object: session)
        center.addObserver(self, selector: #selector(runtimeError(_:)), name: AVCaptureSession.runtimeErrorNotification, object: session)
    }
    deinit { NotificationCenter.default.removeObserver(self) }

    func updateOrientation(_ device: UIDeviceOrientation) {
        let image: CGImagePropertyOrientation
        switch device { case .portrait: image = .right; case .portraitUpsideDown: image = .left; case .landscapeLeft: image = .up; case .landscapeRight: image = .down; default: return }
        frames.async { self.orientation = image }
    }

    func start(id: UUID, target: Destination, single: Bool, event: @escaping (CameraEvent) -> Void) {
        control.async {
            self.sessionID = id; self.sessionEvent = event
            self.frames.async { self.stream = nil; self.snapshotArmed = false }
            let resume: (Bool) -> Void = { granted in
                self.control.async {
                    guard self.sessionID == id else { return }
                    guard granted else { event(.state(.denied)); return }
                    do {
                        try self.configure()
                        self.frames.async { self.lastFrame = -.infinity; self.snapshotArmed = false; self.failureCount = 0; self.stream = (id, target, single, event) }
                        if !self.session.isRunning { self.session.startRunning() }
                        event(.state(self.session.isRunning ? .ready : .interrupted))
                    } catch let reason as CaptureFailure { event(.state(reason.state)) }
                    catch { event(.state(.failed("无法启动相机。请重试或选择照片。"))) }
                }
            }
            guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil else { event(.state(.unavailable)); return }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: resume(true)
            case .notDetermined: AVCaptureDevice.requestAccess(for: .video, completionHandler: resume)
            default: resume(false)
            }
        }
    }
    private struct CaptureFailure: Error { let state: CaptureState }
    private func configure() throws {
        guard !configured else { return }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw CaptureFailure(state: .unavailable) }
        let input = try AVCaptureDeviceInput(device: camera)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        guard session.canAddInput(input) else { throw CaptureFailure(state: .unavailable) }; session.addInput(input)
        guard session.canAddOutput(output) else { session.removeInput(input); throw CaptureFailure(state: .unavailable) }; session.addOutput(output)
        // Vision receives the sensor buffer plus its orientation; rotate only the onscreen preview.
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
        }
        output.setSampleBufferDelegate(self, queue: frames)
        configured = true
    }
    func snapshot() { frames.async { self.snapshotArmed = true } }
    func stop() {
        control.async {
            self.sessionID = nil; self.sessionEvent = nil
            self.frames.async { self.stream = nil; self.snapshotArmed = false }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }
    @objc private func interruption(_ note: Notification) { control.async { self.sessionEvent?(.state(.interrupted)) } }
    @objc private func recover(_ note: Notification) { control.async {
        guard self.sessionID != nil, self.configured else { return }
        if !self.session.isRunning { self.session.startRunning() }
        self.sessionEvent?(.state(self.session.isRunning ? .ready : .interrupted))
    } }
    @objc private func runtimeError(_ note: Notification) {
        if (note.userInfo?[AVCaptureSessionErrorKey] as? AVError)?.code == .mediaServicesWereReset { recover(note) }
        else { control.async { self.sessionEvent?(.state(.failed("相机暂时不可用，请暂停后重新开始。"))) } }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let stream, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard stream.single ? snapshotArmed : now - lastFrame >= 0.5 else { return }
        lastFrame = now; snapshotArmed = false
        do {
            let result = try reader.frame(image, orientation: orientation, target: stream.target)
            failureCount = 0; stream.callback(.frame(result, single: stream.single, sampledAt: now))
        } catch {
            failureCount += 1
            if stream.single || failureCount == 3 { stream.callback(.error("这次识字未成功。请重拍或调整手机角度。")) }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let connection = preview.connection else { return }
            let angle: CGFloat
            switch window?.windowScene?.effectiveGeometry.interfaceOrientation {
            case .landscapeLeft: angle = 180
            case .landscapeRight: angle = 0
            case .portraitUpsideDown: angle = 270
            default: angle = 90
            }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
    }
    func makeUIView(context: Context) -> Surface { let view = Surface(); view.preview.session = session; view.preview.videoGravity = .resizeAspectFill; return view }
    func updateUIView(_ view: Surface, context: Context) { view.setNeedsLayout() }
}
