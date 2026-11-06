import AVFoundation
import Foundation
import LEDTalksKit
import Observation

@MainActor @Observable
final class ReaderModel {
    enum Status: Equatable {
        case starting
        case noCamera(String)
        case searching
        case reading(mode: LEDTalks.Mode, received: Int, total: Int?)
    }

    struct Reading: Identifiable, Equatable {
        let id = UUID()
        let message: DecodedMessage
        var at: Date
        /// How many times this message has been read in a row (devices repeat).
        var count = 1
    }

    private(set) var status = Status.starting
    private(set) var contrast = 0.0
    private(set) var cameraInfo = ""
    private(set) var history: [Reading] = []
    private(set) var note: String?
    private(set) var finding = false
    /// The region of interest, in capture-device coordinates.
    private(set) var roi = CGPoint(x: 0.5, y: 0.5)
    let roiSize = 0.04
    var exposure = 0.3 {
        didSet { camera.setExposure(exposure) }
    }

    let camera = Camera()

    init() {
        camera.onUpdate = { [weak self] update in
            Task { @MainActor in self?.handle(update) }
        }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            camera.start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                Task { @MainActor in
                    if ok { self.camera.start() } else { self.status = .noCamera("Camera access was refused") }
                }
            }
        default:
            status = .noCamera("Allow camera access in Settings → LED Talks")
        }
    }

    func stop() {
        camera.stop()
    }

    func select(_ devicePoint: CGPoint) {
        roi = devicePoint
        note = nil
        camera.setROI(x: devicePoint.x, y: devicePoint.y)
    }

    func findLED() {
        finding = true
        note = "Looking for a blinking LED…"
        camera.findLED()
    }

    func clearHistory() {
        history.removeAll()
    }

    private func handle(_ update: CaptureUpdate) {
        switch update {
        case .configured(let info):
            cameraInfo = info
            if status == .starting { status = .searching }
        case .failed(let why):
            status = .noCamera(why)
        case .found(let x, let y):
            finding = false
            roi = CGPoint(x: x, y: y)
            note = "Found it."
        case .notFound:
            finding = false
            note = "Nothing's blinking. Point at the LED and tap it, or try again."
        case .decoder(let events, let contrast):
            self.contrast = contrast
            for event in events { handle(event) }
        }
    }

    private func handle(_ event: DecoderEvent) {
        switch event {
        case .locked(let mode, _):
            status = .reading(mode: mode, received: 0, total: nil)
        case .progress(let received, let total):
            if case .reading(let mode, _, _) = status {
                status = .reading(mode: mode, received: received, total: total)
            }
        case .decoded(let message):
            status = .searching
            note = nil
            if let first = history.first, first.message.payload == message.payload,
               Date().timeIntervalSince(first.at) < 15 {
                history[0].count += 1
                history[0].at = Date()
            } else {
                history.insert(Reading(message: message, at: Date()), at: 0)
            }
        case .failed(let failure):
            status = .searching
            note = switch failure {
            case .crc: "Missed part of a message. Hold steady: it'll come round again."
            case .unknownHeader: "That isn't an LED Talks version 1 message."
            case .indistinctSymbols: "Couldn't tell its symbols apart. Try more or less exposure."
            }
        }
    }
}
