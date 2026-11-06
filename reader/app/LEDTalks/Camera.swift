import AVFoundation
import LEDTalksKit
import os

/// What the capture queue tells the main actor.
enum CaptureUpdate: Sendable {
    case configured(String)
    case failed(String)
    case decoder([DecoderEvent], contrast: Double)
    case found(x: Double, y: Double)
    case notFound
}

/// The camera pipeline: films at the highest frame rate the phone offers, with exposure and white
/// balance locked (so the training sequence stays valid for a whole message), takes the mean
/// colour of a small square around the LED in every frame, and feeds it to the decoder.
///
/// Everything except the lock-protected `Shared` state runs on `queue`.
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    var onUpdate: @Sendable (CaptureUpdate) -> Void = { _ in }

    /// The region of interest, in capture-device coordinates (0...1, the buffer's orientation),
    /// and its side as a fraction of the frame's height.
    struct Shared: Sendable {
        var roi = (x: 0.5, y: 0.5)
        var roiSize = 0.04
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let queue = DispatchQueue(label: "com.nakomis.ledtalks.capture", qos: .userInteractive)
    private var device: AVCaptureDevice?
    private var configured = false
    private var decoder = Decoder()
    private var finder: LEDFinder?
    private var findUntil: Double?
    private var lastPost = 0.0
    private var exposure = 0.3

    func start() {
        queue.async {
            if !self.configured { self.configure() }
            if self.configured, !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    func setROI(x: Double, y: Double) {
        shared.withLock { $0.roi = (x, y) }
        queue.async {
            self.decoder.reset()
            self.focus(at: CGPoint(x: x, y: y))
        }
    }

    /// Watches for 1.5 s, then reports the cell that blinked most.
    func findLED() {
        queue.async {
            self.finder = LEDFinder()
            self.findUntil = nil
        }
    }

    /// 0...1: from the camera's lowest ISO to about a quarter of its range (LEDs are bright).
    func setExposure(_ value: Double) {
        queue.async {
            self.exposure = value
            self.applyExposure()
        }
    }

    // MARK: Configuration (on queue)

    private func configure() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            onUpdate(.failed("No camera"))
            return
        }
        self.device = device
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)

        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            onUpdate(.failed("Can't use the camera"))
            return
        }
        session.addInput(input)
        session.addOutput(output)

        // The fastest format, capped at 240 fps; among those, the smallest that's at least
        // 640 wide (the decoder only looks at a few pixels, so resolution is just cost).
        let rate = { (f: AVCaptureDevice.Format) in f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0 }
        let width = { (f: AVCaptureDevice.Format) in Int(CMVideoFormatDescriptionGetDimensions(f.formatDescription).width) }
        let fps = min(240, device.formats.map(rate).max() ?? 30)
        let format = device.formats
            .filter { rate($0) >= fps && width($0) >= 640 }
            .min { width($0) < width($1) } ?? device.activeFormat
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let frame = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = frame
            device.activeVideoMaxFrameDuration = frame
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
        } catch {
            session.commitConfiguration()
            onUpdate(.failed("Can't configure the camera: \(error.localizedDescription)"))
            return
        }
        session.commitConfiguration()
        applyExposure()
        // Let auto white balance settle, then freeze it: the decoder learns colours per
        // message and mustn't have them drift underneath it.
        queue.asyncAfter(deadline: .now() + 1.5) { self.lockWhiteBalance() }
        configured = true
        onUpdate(.configured("\(Int(fps)) fps · \(dims.width)×\(dims.height)"))
    }

    private func applyExposure() {
        guard let device, device.isExposureModeSupported(.custom) else { return }
        let f = device.activeFormat
        let fps = 1 / max(device.activeVideoMinFrameDuration.seconds, 1.0 / 240)
        // Half a frame, so each frame sees a cleaner slice of each symbol.
        let wanted = CMTime(seconds: 0.5 / fps, preferredTimescale: 1_000_000)
        let duration = CMTimeClampToRange(wanted, range: CMTimeRange(start: f.minExposureDuration,
                                                                       end: f.maxExposureDuration))
        let span = Double(f.maxISO - f.minISO) * 0.25
        let iso = f.minISO + Float(span * min(max(exposure, 0), 1))
        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: duration, iso: iso)
            device.unlockForConfiguration()
        } catch {}
    }

    private func lockWhiteBalance() {
        guard let device, device.isWhiteBalanceModeSupported(.locked) else { return }
        do {
            try device.lockForConfiguration()
            device.setWhiteBalanceModeLocked(with: device.deviceWhiteBalanceGains)
            device.unlockForConfiguration()
        } catch {}
    }

    private func focus(at point: CGPoint) {
        guard let device, device.isFocusPointOfInterestSupported else { return }
        do {
            try device.lockForConfiguration()
            device.focusPointOfInterest = point
            if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            device.unlockForConfiguration()
        } catch {}
    }

    // MARK: Frames (on queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let frame = BGRAFrame(base: UnsafeRawPointer(base), width: CVPixelBufferGetWidth(pixels),
                              height: CVPixelBufferGetHeight(pixels),
                              bytesPerRow: CVPixelBufferGetBytesPerRow(pixels))

        if var f = finder {
            f.add(frame)
            let until = findUntil ?? time + 1.5
            findUntil = until
            if time >= until {
                finder = nil
                if let best = f.best, best.deviation > 0.03 {
                    setROI(x: best.x, y: best.y)
                    onUpdate(.found(x: best.x, y: best.y))
                } else {
                    onUpdate(.notFound)
                }
            } else {
                finder = f
            }
        }

        let s = shared.withLock { $0 }
        let colour = frame.mean(around: s.roi, size: s.roiSize)
        let events = decoder.add(Sample(time: time, colour: colour))
        if !events.isEmpty || time - lastPost > 0.1 {
            lastPost = time
            onUpdate(.decoder(events, contrast: decoder.contrast))
        }
    }
}
