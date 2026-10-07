import RealityKit
import SwiftUI

/// The app is a single mixed-immersion space: visionOS opens it directly at launch
/// (`UIApplicationPreferredDefaultSceneSessionRole = UISceneSessionRoleImmersiveSpaceApplication`
/// in Info.plist), tracking starts immediately and every control lives in the space itself.
/// Press the Digital Crown to leave, or use the 退出 chip on the desk arc. (The hint capsule only offers a
/// 退出 button for real errors — unsupported hardware, a missing reference image, denied authorization, a failed
/// session. Searching and losing the card are normal states with reassuring copy and no button: see
/// `CardTracker.Status.showsExit`.)
///
/// A tiny fallback window exists only for the "coming back" case: tapping the card opens Safari,
/// which dismisses our space; when the user returns (Home View → app icon, or Safari closed) the
/// system may hand us a window scene instead — it shows one glass button and, when the scene
/// becomes active without an open space, reopens the space by itself.
@main
struct SpatialCardApp: App {
    /// v4 B1: A1's magic materials start loading before anything else is built — stored properties initialise in
    /// order, so this runs before `AppModel()` (the first recognition closes ≈ 3.5 s after launch and must find them).
    private let materialPreloadStarted = V4MaterialPreload.startAtLaunch()
    @State private var appModel = AppModel()

    init() {
        // `print` is block-buffered when stdout is a pipe (devicectl / simctl --console); flush per line
        // so the [timing] / [perf] / [p0] diagnostics arrive while the app runs.
        setvbuf(stdout, nil, _IOLBF, 0)
        EngineTickSystem.registerSystem()
        FXRegistration.register()
    }

    // Both SwiftUI and RealityKit declare `Scene`; qualify it so the compiler picks SwiftUI's.
    var body: some SwiftUI.Scene {
        ImmersiveSpace(id: AppModel.immersiveSpaceID) {
            // v4 labs (`--lab <id>`): one experiment on a virtual desk, none of the product's tracking or links.
            if let labID = LabLaunch.id {
                LabImmersiveView(labID: labID)
            } else {
                ImmersiveView()
                    .environment(appModel)
            }
        }
        // Mixed by default; worlds (and the P0 probe) switch to .full through AppModel.
        .immersionStyle(selection: Binding(get: { appModel.immersionStyle }, set: { appModel.immersionStyle = $0 }),
                        in: .mixed, .full)

        WindowGroup(id: AppModel.returnWindowID) {
            ReturnWindowView()
                .environment(appModel)
        }
        .windowStyle(.plain)
        .defaultSize(width: 320, height: 160)
    }
}

/// Minimal glass window: a single button back into the space (and automatic reopen on activation).
struct ReturnWindowView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOpening = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "visionpro")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
            if appModel.userDismissedSpace {
                Text("已退出空间名片")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            Button {
                appModel.userDismissedSpace = false
                Task { await reopen() }
            } label: {
                Label(isOpening ? "正在返回…" : "回到空间名片", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 19, weight: .semibold))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isOpening)
        }
        .padding(28)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .task {
            // Landing here after Safari: go straight back into the space without a tap. After one of our own
            // 退出 buttons the window waits for the tap instead.
            if !appModel.userDismissedSpace { await reopen() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !appModel.immersiveSpaceIsOpen, !appModel.userDismissedSpace {
                Task { await reopen() }
            }
        }
    }

    @MainActor
    private func reopen() async {
        guard !appModel.immersiveSpaceIsOpen, !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        switch await openImmersiveSpace(id: AppModel.immersiveSpaceID) {
        case .opened:
            appModel.immersiveSpaceIsOpen = true
            dismissWindow(id: AppModel.returnWindowID)
        default:
            break
        }
    }
}
