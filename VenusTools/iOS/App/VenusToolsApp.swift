import SwiftUI
import UIKit

@main
struct VenusToolsApp: App {
    @UIApplicationDelegateAdaptor(ModelDownloadAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class ModelDownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = BackgroundModelTransfers.shared
        _ = OfflineSpeechModels.shared
        _ = LocalQwenService.shared
        return true
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundModelTransfers.identifier else { completionHandler(); return }
        BackgroundModelTransfers.shared.reconnect(completion: completionHandler)
    }
}
