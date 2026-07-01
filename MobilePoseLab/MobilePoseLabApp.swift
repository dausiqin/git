import SwiftUI

@main
struct MobilePoseLabApp: App {
    @StateObject private var store = CaptureSessionStore()
    @StateObject private var phoneRecorder = PhoneMotionRecorder()
    @StateObject private var airPodsRecorder = AirPodsMotionRecorder()
    @StateObject private var watchReceiver = WatchConnectivityReceiver()

    var body: some Scene {
        WindowGroup {
            CaptureDashboardView()
                .environmentObject(store)
                .environmentObject(phoneRecorder)
                .environmentObject(airPodsRecorder)
                .environmentObject(watchReceiver)
                .onAppear {
                    watchReceiver.activate(store: store)
                }
        }
    }
}
