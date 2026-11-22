import SwiftUI

@main
struct PathSenseApp: App {
    @StateObject private var scanner = Scanner()
    @Environment(\.scenePhase) private var phase
    private var originalNavigation: Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--door-demo") { return false }
        return args.contains("--full-navigation") || args.contains("--check-direct-cloud")
            || args.contains("--check-paired-cloud") || args.contains("--pathsense-device-check")
            || args.contains("--pathsense-passage-check") || args.contains("--pathsense-dictation-check")
            || ProcessInfo.processInfo.environment["PATHSENSE_TEST_CAMERA"] != nil
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if originalNavigation { RootView(scanner: scanner) }
                else { DoorDemoView(scanner: scanner) }
            }
                .task {
                    await scanner.checkCloudOnLaunchIfRequested()
                    #if DEBUG
                    await DoorDemoCloudCheck.runIfRequested()
                    await LocalMapDeviceCheck.runIfRequested()
                    #endif
                }
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
