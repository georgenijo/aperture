import AVFoundation

class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()
    @Published var authorizationStatus: AVAuthorizationStatus = .notDetermined

    private let sessionQueue = DispatchQueue(label: "com.georgenijo.Aperture.sessionQueue")
    private var currentInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()

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
        sessionQueue.async { [weak self] in
            self?.configureSession()
            self?.session.startRunning()
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
            let settings = AVCapturePhotoSettings()
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings.photoQualityPrioritization = .quality
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation() else { return }
        if let _ = PhotoStorage.savePhoto(data) {
            print("Photo saved successfully")
        }
    }
}
