import SwiftUI
import UIKit
import AppIntents
import WidgetKit

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    // Construct the manager during launch, including a CoreBluetooth background relaunch.
    let receiver = BluetoothReceiver.shared
    private var registeredShortcuts = false

    func registerShortcutsIfNeeded() {
        guard !registeredShortcuts, !BluetoothReceiver.isDesignPreview else { return }
        registeredShortcuts = true
        // Register on the first foreground visit. A BLE background launch does
        // no indexing work; subsequent foreground visits do not repeat it.
        CodexModeShortcuts.updateAppShortcutParameters()
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: CodexModeStore.kind)
        }
        #if DEBUG && targetEnvironment(simulator)
        NSLog("CodexControls: foreground shortcut metadata registration requested")
        #endif
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        receiver.refreshNotificationSettings()
        if !BluetoothReceiver.isDesignPreview { LegacyActivityCleanup.endAll() }
        return true
    }
}

@main
struct CodexPhoneNotifierApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var receiver = BluetoothReceiver.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(receiver: receiver)
                .onAppear {
                    if scenePhase == .active { appDelegate.registerShortcutsIfNeeded() }
                    if !BluetoothReceiver.isDesignPreview { LegacyActivityCleanup.endAll() }
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        appDelegate.registerShortcutsIfNeeded()
                        receiver.applicationBecameActive()
                        if !BluetoothReceiver.isDesignPreview { LegacyActivityCleanup.endAll() }
                    }
                }
        }
    }
}
