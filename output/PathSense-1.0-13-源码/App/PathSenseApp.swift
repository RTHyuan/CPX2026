import SwiftUI

@main
struct PathSenseApp: App {
    @StateObject private var scanner = Scanner()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView(scanner: scanner)
                .task { await scanner.checkCloudOnLaunchIfRequested() }
                #if DEBUG && targetEnvironment(simulator)
                .task { await SimulatorStepReplay.runIfRequested(scanner) }
                #elseif DEBUG
                .task { await scanner.diagnostics.run(scanner) }
                #endif
                .onChange(of: phase) { _, phase in
                    if phase == .background { scanner.background() }
                    if phase == .active { scanner.foreground() }
                }
        }
    }
}
