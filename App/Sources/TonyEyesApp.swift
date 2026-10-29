import SwiftUI
import UIKit

@main
struct TonyEyesApp: App {
    @State private var link = PeripheralLink()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(link)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true  // mounted: the screen is Tony's face
                    UIDevice.current.isBatteryMonitoringEnabled = true
                    link.start()
                }
        }
    }
}
