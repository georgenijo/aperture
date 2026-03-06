import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @State private var showFlash = false
    @State private var showLab = false
    @State private var lastPhotoThumbnail: UIImage?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch cameraManager.authorizationStatus {
            case .authorized:
                CameraPreview(session: cameraManager.session)
                    .ignoresSafeArea()

                VStack {
                    Spacer()
                    HStack {
                        labButton
                        Spacer()
                        shutterButton
                        Spacer()
                        Color.clear.frame(width: 50, height: 50)
                    }
                    .padding(.horizontal, 30)
                    .padding(.bottom, 40)
                }

                if showFlash {
                    Color.white.ignoresSafeArea()
                        .allowsHitTesting(false)
                }

            case .notDetermined:
                promptView

            case .denied, .restricted:
                deniedView

            @unknown default:
                promptView
            }
        }
        .onAppear {
            cameraManager.checkPermissions()
            if cameraManager.authorizationStatus == .authorized {
                cameraManager.startSession()
            } else if cameraManager.authorizationStatus == .notDetermined {
                cameraManager.requestPermission()
            }
        }
        .onDisappear {
            cameraManager.stopSession()
        }
        .onChange(of: cameraManager.authorizationStatus) { _, newValue in
            if newValue == .authorized {
                cameraManager.startSession()
            }
        }
        .fullScreenCover(isPresented: $showLab) {
            loadLastPhotoThumbnail()
        } content: {
            LabView()
        }
        .task { loadLastPhotoThumbnail() }
    }

    private var promptView: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera")
                .font(.system(size: 48))
                .foregroundStyle(.white)
            Text("Camera Access Required")
                .font(.title2)
                .foregroundStyle(.white)
            Text("Aperture needs access to your camera to show the viewfinder.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.gray)
                .padding(.horizontal, 40)
        }
    }

    private var labButton: some View {
        Button { showLab = true } label: {
            if let lastPhotoThumbnail {
                Image(uiImage: lastPhotoThumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 50, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
            }
        }
    }

    private var shutterButton: some View {
        Button {
            cameraManager.capturePhoto()
            showFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                showFlash = false
            }
        } label: {
            ZStack {
                Circle()
                    .fill(cameraManager.isCapturing ? .gray : .white)
                    .frame(width: 70, height: 70)
                Circle()
                    .stroke(cameraManager.isCapturing ? .gray : .white, lineWidth: 4)
                    .frame(width: 80, height: 80)
            }
        }
        .disabled(cameraManager.isCapturing)
    }

    private func loadLastPhotoThumbnail() {
        guard let latest = PhotoStorage.loadAllPhotos().first else {
            lastPhotoThumbnail = nil
            return
        }
        let url = PhotoStorage.photoURL(for: latest.filename)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 100 * UIScreen.main.scale
        ]
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            lastPhotoThumbnail = UIImage(cgImage: cgImage)
        }
    }

    private var deniedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.slash")
                .font(.system(size: 48))
                .foregroundStyle(.white)
            Text("Camera Access Denied")
                .font(.title2)
                .foregroundStyle(.white)
            Text("Enable camera access in Settings to use Aperture.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.gray)
                .padding(.horizontal, 40)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
