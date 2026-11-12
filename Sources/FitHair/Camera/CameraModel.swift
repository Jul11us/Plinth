import SwiftUI
@preconcurrency import AVFoundation
import AppKit
import CoreImage
import Vision

/// Live camera feed with lightweight framing checks (face present, facing the camera, lighting).
@MainActor
@Observable
final class CameraModel: NSObject {
    enum Access { case unknown, granted, denied, noCamera }

    var access: Access = .unknown
    var devices: [AVCaptureDevice] = []
    var deviceID: String = ""
    var faceCount = 0
    var yaw: Double?
    var roll: Double?
    var pitch: Double?
    /// Face width as a fraction of the frame width.
    var faceSize: Double = 0
    var brightness: Double = 0.5

    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "fithair.camera")
    @ObservationIgnored nonisolated private let ciContext = CIContext()
    @ObservationIgnored nonisolated(unsafe) private var latestFrame: CGImage?
    @ObservationIgnored nonisolated(unsafe) private var lastCheck = Date.distantPast

    /// Strict limits: a turned or tilted head changes the measured widths.
    static let maxYaw = 8.0, maxRoll = 8.0, maxPitch = 12.0
    var facingOK: Bool {
        faceCount == 1 && abs(yaw ?? 99) < Self.maxYaw && abs(roll ?? 99) < Self.maxRoll && abs(pitch ?? 0) < Self.maxPitch
    }
    var distanceOK: Bool { faceCount == 1 && (0.18...0.6).contains(faceSize) }
    var lightOK: Bool { (0.22...0.88).contains(brightness) }
    var ready: Bool { facingOK && distanceOK && lightOK }

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: access = .granted
        case .notDetermined: access = await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        default: access = .denied
        }
        guard access == .granted, !Task.isCancelled else { return }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
                                                         mediaType: .video, position: .unspecified)
        devices = discovery.devices
        guard let device = devices.first(where: { $0.uniqueID == deviceID }) ?? AVCaptureDevice.default(for: .video) ?? devices.first else {
            access = .noCamera; return
        }
        deviceID = device.uniqueID
        configure(device)
    }

    func select(_ id: String) {
        guard let d = devices.first(where: { $0.uniqueID == id }) else { return }
        deviceID = id
        configure(d)
    }

    private func configure(_ device: AVCaptureDevice) {
        let session = self.session, output = self.output, queue = self.queue
        queue.async { [weak self] in
            session.beginConfiguration()
            session.sessionPreset = .high
            session.inputs.forEach { session.removeInput($0) }
            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) { session.addInput(input) }
            if session.outputs.isEmpty {
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(output) { session.addOutput(output) }
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        let session = self.session
        faceCount = 0
        queue.async {
            if session.isRunning { session.stopRunning() }
            self.latestFrame = nil
            self.lastCheck = .distantPast
        }
    }

    /// The most recent frame, mirrored like the preview so the photo matches what the user just saw.
    /// (Face-shape ratios are symmetric, so mirroring doesn't change the measurement.)
    func snapshot() -> CGImage? { queue.sync { session.isRunning ? latestFrame : nil } }

    /// Grabs `count` consecutive frames about `interval` seconds apart, for a median measurement.
    func burst(count: Int = 10, interval: Double = 0.08) async throws -> [CGImage] {
        var frames: [CGImage] = []
        var last: CGImage?
        for _ in 0..<(count * 3) where frames.count < count {
            try Task.checkCancellation()
            if let f = snapshot(), f !== last { frames.append(f); last = f }
            try await Task.sleep(for: .seconds(interval))
        }
        try Task.checkCancellation()
        return frames
    }
}

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: pb)
        let mirrored = ci.oriented(.upMirrored)
        if let cg = ciContext.createCGImage(mirrored, from: mirrored.extent) { latestFrame = cg }

        // Run the checks a few times per second, not on every frame.
        guard Date().timeIntervalSince(lastCheck) > 0.25 else { return }
        lastCheck = Date()

        let req = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pb, options: [:]).perform([req])
        let faces = req.results ?? []
        let main = faces.max { $0.boundingBox.width < $1.boundingBox.width }
        let yaw = main?.yaw.map { $0.doubleValue * 180 / .pi }
        let roll = main?.roll.map { $0.doubleValue * 180 / .pi }
        let pitch = main?.pitch.map { $0.doubleValue * 180 / .pi }
        let size = Double(main?.boundingBox.width ?? 0)

        let avg = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)])?.outputImage
        var px = [UInt8](repeating: 0, count: 4)
        if let avg {
            ciContext.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        }
        let luma = (0.299 * Double(px[0]) + 0.587 * Double(px[1]) + 0.114 * Double(px[2])) / 255

        Task { @MainActor in
            self.faceCount = faces.count
            self.yaw = yaw
            self.roll = roll
            self.pitch = pitch
            self.faceSize = size
            self.brightness = luma
        }
    }
}

/// Mirrored live preview, like a mirror.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let v = PreviewView()
        v.previewLayer.session = session
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
            previewLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(previewLayer)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            previewLayer.frame = bounds
            if let c = previewLayer.connection, c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = true
            }
        }
    }
}
