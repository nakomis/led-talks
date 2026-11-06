import AVFoundation
import LEDTalksKit
import SwiftUI

struct ContentView: View {
    @State private var model = ReaderModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                CameraPreview(session: model.camera.session, roi: model.roi, roiSize: model.roiSize,
                              onTap: model.select)
                    .ignoresSafeArea(edges: .top)
                Text(model.cameraInfo)
                    .font(.caption2.monospacedDigit())
                    .padding(6)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
                    .padding(8)
            }
            .frame(maxHeight: .infinity)

            panel
                .padding()
                .background(.background)
        }
        .onAppear { model.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.start() } else { model.stop() }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                statusLine
                Spacer()
                Button(model.finding ? "Looking…" : "Find LED", action: model.findLED)
                    .buttonStyle(.bordered)
                    .disabled(model.finding)
            }
            HStack {
                Text("Signal").font(.caption)
                ProgressView(value: min(model.contrast / 0.5, 1))
                    .tint(model.contrast < 0.04 ? .gray : .green)
            }
            HStack {
                Image(systemName: "sun.min").font(.caption)
                Slider(value: $model.exposure, in: 0...1)
                Image(systemName: "sun.max").font(.caption)
            }
            if let note = model.note {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
            history
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch model.status {
        case .starting:
            Label("Starting the camera…", systemImage: "camera")
        case .noCamera(let why):
            Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        case .searching:
            Label("Tap the LED, or Find LED", systemImage: "viewfinder")
        case .reading(let mode, let received, let total):
            VStack(alignment: .leading) {
                Label("Reading \(mode.name)…", systemImage: "waveform")
                if let total { ProgressView(value: Double(received), total: Double(total)) }
            }
        }
    }

    private var history: some View {
        List {
            if model.history.isEmpty {
                Text("Nothing read yet.").foregroundStyle(.secondary)
            }
            ForEach(model.history) { reading in
                Section {
                    ForEach(Array(reading.message.content.lines.enumerated()), id: \.offset) { _, line in
                        LabeledContent(line.label, value: line.value)
                    }
                } header: {
                    HStack {
                        Text(reading.at, style: .time)
                        Spacer()
                        Text(summary(reading))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .frame(minHeight: 220)
    }

    private func summary(_ r: Reading) -> String {
        let rate = Int((1 / r.message.period).rounded())
        let times = r.count > 1 ? " · ×\(r.count)" : ""
        return "\(r.message.mode.name) · \(rate) symbols/s\(times)"
    }

    private typealias Reading = ReaderModel.Reading
}

/// The camera preview, with the region of interest marked. A tap selects a new region.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let roi: CGPoint
    let roiSize: Double
    let onTap: (CGPoint) -> Void

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        let marker = CAShapeLayer()
        var roi = CGPoint(x: 0.5, y: 0.5)
        var roiSize = 0.04

        override init(frame: CGRect) {
            super.init(frame: frame)
            preview.videoGravity = .resizeAspectFill
            marker.strokeColor = UIColor.systemYellow.cgColor
            marker.fillColor = UIColor.clear.cgColor
            marker.lineWidth = 2
            layer.addSublayer(marker)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            drawMarker()
        }

        func drawMarker() {
            // The square's side is a fraction of the buffer's height; the buffer is landscape,
            // about 16:9, so in normalised x it's 9/16 as wide.
            let sy = roiSize, sx = roiSize * 9 / 16
            let rect = preview.layerRectConverted(fromMetadataOutputRect:
                CGRect(x: roi.x - sx / 2, y: roi.y - sy / 2, width: sx, height: sy))
            marker.path = UIBezierPath(rect: rect.insetBy(dx: -4, dy: -4)).cgPath
        }
    }

    @MainActor final class Coordinator: NSObject {
        let onTap: (CGPoint) -> Void
        init(onTap: @escaping (CGPoint) -> Void) { self.onTap = onTap }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let view = g.view as? PreviewView else { return }
            onTap(view.preview.captureDevicePointConverted(fromLayerPoint: g.location(in: view)))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = session
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator,
                                                         action: #selector(Coordinator.tapped)))
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.roi = roi
        view.roiSize = roiSize
        view.drawMarker()
    }
}
