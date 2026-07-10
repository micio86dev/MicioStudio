import SwiftUI

@main
struct MicioStudioApp: App {
    init() {
        #if DEBUG
        Bundle(path: "/Applications/InjectionIII.app/Contents/Resources/macOSInjection.bundle")?.load()
        #endif
    }

    var body: some Scene {
        WindowGroup(Config.productName) {
            ContentView()
        }
        .defaultSize(width: 520, height: 360)
        .windowResizability(.contentMinSize)
    }
}
