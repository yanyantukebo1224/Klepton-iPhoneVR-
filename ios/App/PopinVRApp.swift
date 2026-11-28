import SwiftUI
import Darwin

@main
struct PopinVRApp: App {
    init() {
        // MoltenVK is embedded as a signed framework. Resolve it from this app's
        // Frameworks directory so the C runtime never depends on a host path.
        if let frameworkURL = Bundle.main.privateFrameworksURL?
            .appendingPathComponent("MoltenVK.framework")
            .appendingPathComponent("MoltenVK") {
            setenv("KL_MVK_DYLIB", frameworkURL.path, 0)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
