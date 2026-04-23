import SwiftUI
import Combine
import AVFoundation
import Vision
import UIKit

struct BarcodeResult {
    let value: String
    let format: String
}

final class ScannerModel: ObservableObject {
    @Published var isScanning = false
    @Published var detectedResult: BarcodeResult?
    @Published var torchOn = false
    @Published var hasPermission = false
    @Published var sessionReady = false

    let session = AVCaptureSession()
    private let visionQueue = DispatchQueue(label: "vision", qos: .userInitiated)
    private let scanDelegate = ScanDelegate()
    private var hasSetUp = false
    private var videoOutput: AVCaptureVideoDataOutput?
    private var orientationObserver: NSObjectProtocol?

    func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            hasPermission = true
            setupSession()
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                hasPermission = granted
                if granted { setupSession() }
            }
        default:
            hasPermission = false
        }
    }

    private func setupSession() {
        guard !hasSetUp else { return }
        hasSetUp = true

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        session.beginConfiguration()
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        scanDelegate.setModel(self)
        output.setSampleBufferDelegate(scanDelegate, queue: visionQueue)
        session.addOutput(output)

        videoOutput = output

        session.commitConfiguration()
        sessionReady = true

        if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
            updateVideoOrientation(on: connection)
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            self?.session.startRunning()
        }

        if !UIDevice.current.isGeneratingDeviceOrientationNotifications {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let output = self?.videoOutput,
                  let connection = output.connection(with: .video),
                  connection.isVideoOrientationSupported else { return }
            self?.updateVideoOrientation(on: connection)
        }
    }

    private func updateVideoOrientation(on connection: AVCaptureConnection) {
        switch UIDevice.current.orientation {
        case .portrait: connection.videoOrientation = .portrait
        case .landscapeLeft: connection.videoOrientation = .landscapeRight
        case .landscapeRight: connection.videoOrientation = .landscapeLeft
        case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
        default: connection.videoOrientation = .portrait
        }
    }

    func startScanning() {
        detectedResult = nil
        isScanning = true
        scanDelegate.isActivelyScanning = true
    }

    func stopScanning() {
        isScanning = false
        scanDelegate.isActivelyScanning = false
    }

    func stopSession() {
        session.stopRunning()
        if let observer = orientationObserver {
            NotificationCenter.default.removeObserver(observer)
            orientationObserver = nil
        }
        if UIDevice.current.isGeneratingDeviceOrientationNotifications {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
    }

    func toggleTorch() {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        try? device.lockForConfiguration()
        device.torchMode = torchOn ? .off : .on
        torchOn.toggle()
        device.unlockForConfiguration()
    }

    func didDetectBarcode(_ result: BarcodeResult) {
        detectedResult = result
        isScanning = false
        scanDelegate.isActivelyScanning = false
    }
}

final class ScanDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated(unsafe) private weak var model: ScannerModel?
    nonisolated(unsafe) var isActivelyScanning = false
    nonisolated(unsafe) private var visionFailCount = 0

    func setModel(_ model: ScannerModel) {
        self.model = model
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let model = model, isActivelyScanning,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var visionResult: BarcodeResult?

        let request = VNDetectBarcodesRequest { request, error in
            guard let results = request.results as? [VNBarcodeObservation],
                  let first = results.first,
                  let payload = first.payloadStringValue else { return }

            if first.symbology == .ean13, payload.count == 13, payload.hasPrefix("0") {
                visionResult = BarcodeResult(value: String(payload.dropFirst()), format: "UPC-A")
            } else {
                visionResult = BarcodeResult(value: payload, format: Self.symbologyName(first.symbology))
            }
        }
        request.symbologies = [.code128, .ean13, .ean8, .upce,
                               .i2of5, .i2of5Checksum,
                               .gs1DataBar, .gs1DataBarExpanded, .gs1DataBarLimited]

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])

        if visionResult != nil {
            visionFailCount = 0
        } else {
            visionFailCount += 1
        }

        if visionResult == nil, visionFailCount >= 5,
           let gray = MsiPlesseyDecoder.extractGrayscale(from: pixelBuffer),
           let msiResult = MsiPlesseyDecoder.decodeGray(gray) {
            visionResult = BarcodeResult(value: msiResult.fullDigits, format: "MSI Plessey")
        }

        if let result = visionResult {
            Task { @MainActor in
                model.didDetectBarcode(result)
            }
        }
    }

    private static func symbologyName(_ symbology: VNBarcodeSymbology) -> String {
        switch symbology {
        case .code128: return "Code 128"
        case .ean13: return "EAN-13"
        case .ean8: return "EAN-8"
        case .upce: return "UPC-E"
        case .i2of5: return "Interleaved 2 of 5"
        case .i2of5Checksum: return "Interleaved 2 of 5 (Checksum)"
        case .gs1DataBar: return "GS1 DataBar"
        case .gs1DataBarExpanded: return "GS1 DataBar Expanded"
        case .gs1DataBarLimited: return "GS1 DataBar Limited"
        default: return symbology.rawValue
        }
    }
}

class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        PreviewView(session: session)
    }

    func updateUIView(_ uiView: PreviewView, context: Context) { }
}

struct BarcodeScannerView: View {
    @StateObject private var model = ScannerModel()

    var body: some View {
        ZStack {
            if model.sessionReady {
                CameraPreview(session: model.session)
                    .ignoresSafeArea()
            }

            VStack {
                Spacer().frame(height: 60)

                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white, lineWidth: 2)
                        .frame(width: 280, height: 280)

                    if model.hasPermission {
                        Button { model.toggleTorch() } label: {
                            Image(systemName: model.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                .font(.title2)
                                .foregroundColor(.yellow)
                        }
                        .padding(8)
                    }
                }

                Spacer().frame(height: 40)

                if !model.hasPermission {
                    Text("Camera permission required")
                        .foregroundColor(.white)
                        .font(.headline)
                } else if let result = model.detectedResult {
                    VStack(spacing: 4) {
                        Text("Symbology: \(result.format)")
                            .font(.title3)
                            .foregroundColor(.accentColor)
                        Text("Value: \(result.value)")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.7))
                    )

                    Button("Rescan") { model.startScanning() }
                        .buttonStyle(.borderedProminent)
                } else if model.isScanning {
                    Text("Scanning...")
                        .foregroundColor(.white)
                        .font(.headline)
                } else {
                    Button("Start Scanning") { model.startScanning() }
                        .buttonStyle(.borderedProminent)

                    Text("Point camera at a barcode")
                        .foregroundColor(.white)
                        .font(.subheadline)
                        .padding(.top, 8)
                }
            }
        }
        .onAppear { model.checkPermission() }
        .onDisappear { model.stopSession() }
    }
}
