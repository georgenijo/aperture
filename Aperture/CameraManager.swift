import AVFoundation

class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()
    @Published var authorizationStatus: AVAuthorizationStatus = .notDetermined
    @Published var isCapturing = false
    @Published var photoSaveCount = 0

    private let sessionQueue = DispatchQueue(label: "com.georgenijo.Aperture.sessionQueue")
    private var currentInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private var captureStartTime: CFAbsoluteTime = 0
    private var captureInFlight = false

    override init() {
        super.init()
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    }

    func checkPermissions() {
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    }

    func requestPermission() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                self?.authorizationStatus = granted ? .authorized : .denied
            }
        }
    }

    func startSession() {
        guard authorizationStatus == .authorized else { return }
        let startTime = CFAbsoluteTimeGetCurrent()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let configStart = CFAbsoluteTimeGetCurrent()
            self.configureSession()
            print("[Timing] configureSession: \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - configStart) * 1000))ms")

            let runStart = CFAbsoluteTimeGetCurrent()
            self.session.startRunning()
            print("[Timing] startRunning: \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - runStart) * 1000))ms")
            print("[Timing] total startup: \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - startTime) * 1000))ms")
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    private func configureSession() {
        guard currentInput == nil else { return }

        session.beginConfiguration()
        session.sessionPreset = .photo

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )

        guard let device = discoverySession.devices.first else {
            session.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                currentInput = input
            }
        } catch {
            print("Failed to create camera input: \(error)")
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        session.commitConfiguration()
    }

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.captureInFlight,
                  self.session.isRunning,
                  self.photoOutput.connection(with: .video) != nil else {
                print("[Capture] skipped: \(self.captureInFlight ? "capture in flight" : "no active video connection")")
                return
            }
            self.captureInFlight = true
            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }
            DispatchQueue.main.async { self.isCapturing = true }
            settings.photoQualityPrioritization = self.photoOutput.maxPhotoQualityPrioritization
            self.captureStartTime = CFAbsoluteTimeGetCurrent()
            print("[Capture] capturing photo...")
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        defer {
            sessionQueue.async { self.captureInFlight = false }
            DispatchQueue.main.async { self.isCapturing = false }
        }

        if let error {
            print("[Capture] failed: \(error)")
            return
        }
        let processingMs = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - captureStartTime) * 1000)
        guard let data = photo.fileDataRepresentation() else {
            print("[Capture] failed to get photo data representation")
            return
        }

        let sizeMB = String(format: "%.1f", Double(data.count) / 1_000_000)
        print("[Capture] processed in \(processingMs)ms (\(sizeMB)MB)")

        let fileExtension = photoOutput.availablePhotoCodecTypes.contains(.hevc) ? "heic" : "jpg"
        if let _ = PhotoStorage.savePhoto(data, fileExtension: fileExtension) {
            print("[Capture] photo saved successfully")
            DispatchQueue.main.async { self.photoSaveCount += 1 }
        } else {
            print("[Capture] photo save failed")
        }
    }
}
