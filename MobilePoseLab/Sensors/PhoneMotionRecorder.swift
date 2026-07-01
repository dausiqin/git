import CoreMotion
import Foundation

@MainActor
final class PhoneMotionRecorder: ObservableObject {
    @Published private(set) var isAvailable = false
    @Published private(set) var isRunning = false
    @Published private(set) var latestSample: MotionSample?

    private let manager = CMMotionManager()
    private let motionQueue = OperationQueue()

    init() {
        motionQueue.name = "MobilePoseLab.phone.motion"
        motionQueue.qualityOfService = .userInteractive
        isAvailable = manager.isDeviceMotionAvailable
    }

    func start(store: CaptureSessionStore) {
        guard manager.isDeviceMotionAvailable else { return }
        latestSample = nil
        manager.deviceMotionUpdateInterval = 1.0 / store.profile.targetHz
        manager.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: motionQueue) { [weak self, weak store] motion, _ in
            guard let motion else { return }
            Task { @MainActor in
                guard let self, let store else { return }
                let context = store.timestampContext(for: .iPhone)
                let sample = MotionSample(
                    sessionId: context.sessionId,
                    source: .iPhone,
                    placement: store.profile.phonePlacement,
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
