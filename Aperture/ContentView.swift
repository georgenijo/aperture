import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @State private var showFlash = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch cameraManager.authorizationStatus {
            case .authorized:
                CameraPreview(session: cameraManager.session)
                    .ignoresSafeArea()

                VStack {
                    Spacer()
                    shutterButton
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
