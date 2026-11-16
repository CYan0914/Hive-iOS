import SwiftUI

@main
struct HiveApp: App {
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .preferredColorScheme(.dark)
                .onAppear {
                    environment.bootstrap()
                }
        }
    }
}
