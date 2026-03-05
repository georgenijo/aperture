import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "camera")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Aperture")
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
