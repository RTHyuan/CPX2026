import SwiftUI

@main
struct PathSenseApp: App {
    @StateObject private var scanner = Scanner()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView(scanner: scanner)
                #if DEBUG && !targetEnvironment(simulator)
                .task { await scanner.diagnostics.run(scanner) }
                #endif
                .onChange(of: phase) { _, phase in
                    if phase == .background { scanner.background() }
                    if phase == .active { scanner.foreground() }
                }
        }
    }
}
