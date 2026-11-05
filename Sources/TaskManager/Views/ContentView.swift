import SwiftUI

struct ContentView: View {
    enum Tab: String {
        case processes, performance, startup
    }

    @AppStorage("selectedTab") private var tab: Tab = .performance

    var body: some View {
        TabView(selection: $tab) {
            ProcessesView()
                .tabItem { Label("Processes", systemImage: "list.bullet.rectangle") }
                .tag(Tab.processes)
            PerformanceView()
                .tabItem { Label("Performance", systemImage: "waveform.path.ecg") }
                .tag(Tab.performance)
            StartupView()
                .tabItem { Label("Startup apps", systemImage: "power") }
                .tag(Tab.startup)
        }
    }
}
