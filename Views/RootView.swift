import SwiftUI

struct RootView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        TabView {
            NavigationStack {
                ChatView()
            }
            .tabItem {
                Label("对话", systemImage: "bubble.left.and.bubble.right")
            }

            NavigationStack {
                RunsView()
            }
            .tabItem {
                Label("任务", systemImage: "list.bullet.rectangle")
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("设置", systemImage: "slider.horizontal.3")
            }
        }
        .tint(Theme.accent)
        .alert(
            "提示",
            isPresented: Binding(
                get: { env.startupError != nil },
                set: { if !$0 { env.startupError = nil } }
            )
        ) {
            Button("好", role: .cancel) { env.startupError = nil }
        } message: {
            Text(env.startupError ?? "")
        }
    }
}
