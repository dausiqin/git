import CoreMotion
import Foundation

@MainActor
final class AirPodsMotionRecorder: NSObject, ObservableObject {
    @Published private(set) var isAvailable = false
    @Published private(set) var isRunning = false
    @Published private(set) var isConnected = false
    @Published private(set) var latestSample: MotionSample?
    @Published private(set) var authorizationStatus: CMAuthorizationStatus = .notDetermined

    private let manager = CMHeadphoneMotionManager()
    private let motionQueue = OperationQueue()
    private var lastEmitTimeNs: Int64 = 0

    override init() {
        super.init()
        motionQueue.name = "MobilePoseLab.headphone.motion"
        motionQueue.qualityOfService = .userInteractive
        manager.delegate = self
        isAvailable = manager.isDeviceMotionAvailable
        authorizationStatus = CMHeadphoneMotionManager.authorizationStatus()
    }

    func start(store: CaptureSessionStore) {
        guard manager.isDeviceMotionAvailable else { return }
        latestSample = nil
        lastEmitTimeNs = 0
        authorizationStatus = CMHeadphoneMotionManager.authorizationStatus()
        manager.startDeviceMotionUpdates(to: motionQueue) { [weak self, weak store] motion, _ in
            guard let motion else { return }
            Task { @MainActor in
                guard let self, let store else { return }
                let context = store.timestampContext(for: .airPods)
                let minimumIntervalNs = Int64(((1_000_000_000.0 / max(store.profile.targetHz, 1)) * 0.75).rounded())
                if self.lastEmitTimeNs > 0, context.timestampNs - self.lastEmitTimeNs < minimumIntervalNs {
                    return
                }
                self.lastEmitTimeNs = context.timestampNs
                let sample = MotionSample(
                    sessionId: context.sessionId,
                    source: .airPods,
                    placement: store.profile.headphonePlacement,
                    referenceFrame: .headphoneDeviceMotion,
                    timestampNs: context.timestampNs,
                    secondsElapsed: context.secondsElapsed,
                    acceleration: Vector3(motion.userAcceleration),
                    rotationRate: Vector3(motion.rotationRate),
                    gravity: Vector3(motion.gravity),
                    attitude: Quaternion(motion.attitude.quaternion),
                    magneticField: nil,
                    heartRateBpm: nil
                )
                self.latestSample = sample
                store.append(sample)
            }
        }
        isRunning = true
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        motionQueue.cancelAllOperations()
        isRunning = false
    }
}

extension AirPodsMotionRecorder: CMHeadphoneMotionManagerDelegate {
    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in
            isConnected = true
            isAvailable = manager.isDeviceMotionAvailable
        }
    }

    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in
            isConnected = false
        }
    }
}
