import SwiftUI

@main
struct cxp_testbedApp: App {
    @State private var store = CredentialStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
    }
}
