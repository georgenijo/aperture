import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @State private var showFlash = false
    @State private var showLab = false
    @State private var lastPhotoThumbnail: UIImage?
    @State private var photoCount = 0

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
        .onChange(of: showLab) { _, isShowingLab in
            if isShowingLab {
                cameraManager.stopSession()
            } else {
                cameraManager.startSession()
            }
        }
        .onChange(of: cameraManager.authorizationStatus) { _, newValue in
            if newValue == .authorized {
                cameraManager.startSession()
            }
        }
        .fullScreenCover(isPresented: $showLab) {
            loadLastPhotoThumbnail()
            photoCount = PhotoStorage.loadAllPhotos().count
        } content: {
            LabView()
        }
        .task {
            loadLastPhotoThumbnail()
            photoCount = PhotoStorage.loadAllPhotos().count
        }
        .onChange(of: cameraManager.photoSaveCount) { _, _ in
            loadLastPhotoThumbnail()
            photoCount += 1
        }
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
                    .overlay(alignment: .topTrailing) {
                        photoBadge
                    }
            } else {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .overlay(alignment: .topTrailing) {
                        photoBadge
                    }
            }
        }
    }

    @ViewBuilder
    private var photoBadge: some View {
        if photoCount > 0 {
            Text("\(photoCount)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(.red))
                .offset(x: 6, y: -6)
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
