import SwiftUI

@main
struct MicioStudioApp: App {
    var body: some Scene {
        WindowGroup(Config.productName) {
            ContentView()
        }
        .defaultSize(width: 520, height: 360)
        .windowResizability(.contentMinSize)
    }
}
