import SwiftUI
import BraviaKit

@main
struct PultApp: App {
    @State private var model = PultApp.makeModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Color.accentColor)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                model.enterBackground()
                return
            }
            guard phase == .active else { return }
            model.enterForeground()
            switch model.screen {
            case .remote:
                Task { await model.refresh() }
            case .blasterSetup where model.blaster.pairingCandidate == nil:
                // Setup sends the user to iOS Settings; resume the search on return (not while pairing).
                model.blaster.startScan()
            case .discovery where model.localNetworkDenied:
                // The first scan races the "Local Network" permission alert; retry once allowed.
                Task { await model.startScan() }
            default:
                break
            }
        }
    }

    @MainActor
    private static func makeModel() -> RemoteModel {
        let store = TVStore()
        #if DEBUG
        // Simulator testing against a mock TV: -PultDebugHost 192.168.1.10:8080 -PultDebugPSK 0000
        let arguments = UserDefaults.standard
        if arguments.bool(forKey: "PultDebugReset") {
            store.forgetTV()
            store.savedBlaster = nil
            store.irRemote = nil
            store.controlMode = .network
        }
        if let host = arguments.string(forKey: "PultDebugHost") {
            store.savedTV = SavedTV(host: host, modelName: "Debug TV")
            if let psk = arguments.string(forKey: "PultDebugPSK") {
                store.credentials = .psk(psk)
            }
        }
        // Simulator testing of the IR mode with a fake bridge: -PultDebugBlaster YES
        let link: BlasterLink = arguments.bool(forKey: "PultDebugBlaster") ? DebugBlasterLink() : CoreBluetoothBlasterLink()
        #else
        let link: BlasterLink = CoreBluetoothBlasterLink()
        #endif
        // One database per app: it owns Application Support/ProfileDatabase.
        let profiles = ProfileDatabase()
        #if DEBUG
        // Simulator check of the TV code download without tapping: -PultDebugInstallProfiles YES
        if arguments.bool(forKey: "PultDebugReset") {
            profiles.remove()
        }
        if arguments.bool(forKey: "PultDebugInstallProfiles") {
            profiles.install(.pinned)
        }
        #endif
        return RemoteModel(store: store, blaster: BlasterSession(link: link, store: store), profiles: profiles)
    }
}

struct RootView: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        Group {
            switch model.screen {
            case .discovery:
                DiscoveryView()
            case .pairing:
                PairingView()
            case .remote:
                RemoteView()
            case .blasterSetup:
                BlasterSetupView()
            case .irSetup:
                IRSetupView()
            }
        }
        .animation(.default, value: model.screen)
    }
}
