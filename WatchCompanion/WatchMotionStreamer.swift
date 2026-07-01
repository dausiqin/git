import CoreMotion
import Foundation
import HealthKit
import WatchKit
import WatchConnectivity

final class WatchMotionStreamer: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isReachable = false
    @Published private(set) var isRuntimeActive = false
    @Published private(set) var isWorkoutActive = false
    @Published private(set) var latestAcceleration = Vector3.zero
    @Published private(set) var motionHz = 0.0
    @Published private(set) var lastSendTime = 0.0
    @Published private(set) var sentSampleCount = 0
    @Published private(set) var droppedBatchCount = 0
    @Published private(set) var bufferedSampleCount = 0
    @Published private(set) var latestHeartRateBpm = 0.0
    @Published private(set) var lastError = ""

    private let motionManager = CMMotionManager()
    private let healthStore = HKHealthStore()
    private let session = WCSession.default
    private let motionQueue = OperationQueue()
    private let batchQueue = DispatchQueue(label: "MobilePoseLab.watch.batch")
    private let jsonEncoder = JSONEncoder()
    private var pendingSamples: [[String: Any]] = []
    private var flushTimer: DispatchSourceTimer?
    private var runtimeSession: WKExtendedRuntimeSession?
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var isSendingBatch = false
    private var captureToken = ""
    private var shouldRunMotion = false
    private var requestedTargetHz = 30.0
    private var lastEmitTimeNs: Int64 = 0
    private var minimumEmitIntervalNs: Int64 = 25_000_000
    private var sampleTimes: [Double] = []
    private let realtimeBatchSize = 6
    private let backgroundBatchSize = 30
    private let maxPendingSamples = 9_000

    override init() {
        super.init()
        motionQueue.name = "MobilePoseLab.watch.motion"
        motionQueue.maxConcurrentOperationCount = 1
        if WCSession.isSupported() {
            session.delegate = self
            session.activate()
        }
    }

    func start(targetHz: Double = 30, token: String = UUID().uuidString) {
        guard motionManager.isDeviceMotionAvailable else { return }
        stop()
        captureToken = token
        shouldRunMotion = true
        requestedTargetHz = targetHz
        sentSampleCount = 0
        droppedBatchCount = 0
        bufferedSampleCount = 0
        lastError = ""
        lastEmitTimeNs = 0
        sampleTimes.removeAll(keepingCapacity: true)
        motionHz = 0
        lastSendTime = 0
        minimumEmitIntervalNs = Int64(((1_000_000_000.0 / max(targetHz, 1)) * 0.75).rounded())
        motionManager.deviceMotionUpdateInterval = 1.0 / targetHz
        startExtendedRuntimeSession()
        startWorkoutSession()
        startFlushTimer()
        isRunning = true
    }

    func stop() {
        shouldRunMotion = false
        motionManager.stopDeviceMotionUpdates()
        stopFlushTimer()
        flushBufferedSamplesForStop()
        stopExtendedRuntimeSession()
        stopWorkoutSession()
        isRunning = false
    }

    private func beginMotionUpdatesIfNeeded() {
        guard shouldRunMotion, motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / max(requestedTargetHz, 1)
        motionManager.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: motionQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let timestampNs = Date().unixNanoseconds
            guard timestampNs - self.lastEmitTimeNs >= self.minimumEmitIntervalNs else { return }
            self.lastEmitTimeNs = timestampNs
            let payload = self.payload(from: motion, timestampNs: timestampNs)
            self.enqueue(payload)
            DispatchQueue.main.async {
                self.latestAcceleration = Vector3(
                    x: motion.userAcceleration.x,
                    y: motion.userAcceleration.y,
                    z: motion.userAcceleration.z
                )
            }
        }
    }

    private func payload(from motion: CMDeviceMotion, timestampNs: Int64) -> [String: Any] {
        [
            "timestampNs": timestampNs,
            "accelX": motion.userAcceleration.x,
            "accelY": motion.userAcceleration.y,
            "accelZ": motion.userAcceleration.z,
            "gyroX": motion.rotationRate.x,
            "gyroY": motion.rotationRate.y,
            "gyroZ": motion.rotationRate.z,
            "gravityX": motion.gravity.x,
            "gravityY": motion.gravity.y,
            "gravityZ": motion.gravity.z,
            "quatX": motion.attitude.quaternion.x,
            "quatY": motion.attitude.quaternion.y,
            "quatZ": motion.attitude.quaternion.z,
            "quatW": motion.attitude.quaternion.w,
            "heartRateBpm": latestHeartRateBpm
        ]
    }

    private func enqueue(_ payload: [String: Any]) {
        batchQueue.async { [weak self] in
            guard let self else { return }
            self.pendingSamples.append(payload)
            self.updateMotionStats(timestampNs: payload["timestampNs"] as? Int64 ?? Date().unixNanoseconds)
            if self.pendingSamples.count > self.maxPendingSamples {
                let overflow = self.pendingSamples.count - self.maxPendingSamples
                self.pendingSamples.removeFirst(overflow)
                DispatchQueue.main.async {
                    self.droppedBatchCount += 1
                }
            }
            self.updateBufferedSampleCount()
            if self.pendingSamples.count >= self.realtimeBatchSize {
                self.flushPendingSamplesOnBatchQueue()
            }
        }
    }

    private func startFlushTimer() {
        stopFlushTimer()
        let timer = DispatchSource.makeTimerSource(queue: batchQueue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            self?.flushPendingSamplesOnBatchQueue()
        }
        flushTimer = timer
        timer.resume()
    }

    private func stopFlushTimer() {
        flushTimer?.cancel()
        flushTimer = nil
    }

    private func flushBufferedSamplesForStop() {
        batchQueue.async {
            self.flushPendingSamplesOnBatchQueue(preferBackgroundTransfer: true)
        }
    }

    private func flushPendingSamplesOnBatchQueue(preferBackgroundTransfer: Bool = false) {
        guard WCSession.isSupported(), !pendingSamples.isEmpty else { return }

        if preferBackgroundTransfer || !session.isReachable {
            transferPendingSamplesInBackground()
            return
        }

        guard !isSendingBatch else { return }

        let batch = Array(pendingSamples.prefix(realtimeBatchSize))
        pendingSamples.removeFirst(batch.count)
        updateBufferedSampleCount()
        isSendingBatch = true

        let compactSamples = batch.map(compactSample)
        let watchBatch = WatchIMUBatch(captureToken: captureToken, samples: compactSamples)
        guard let data = try? jsonEncoder.encode(watchBatch) else {
            session.sendMessage(["captureToken": captureToken, "samples": compactSamples], replyHandler: { [weak self] _ in
                self?.batchQueue.async {
                    self?.finishSending(count: batch.count)
                }
            }, errorHandler: { [weak self] error in
                self?.handleRealtimeSendFailure(error: error, batch: batch)
            })
            return
        }

        session.sendMessageData(data, replyHandler: { [weak self] _ in
            self?.batchQueue.async {
                self?.finishSending(count: batch.count)
            }
        }, errorHandler: { [weak self] error in
            self?.handleRealtimeSendFailure(error: error, batch: batch)
        })
    }

    private func handleRealtimeSendFailure(error: Error, batch: [[String: Any]]) {
        batchQueue.async {
            self.isSendingBatch = false
            self.pendingSamples.insert(contentsOf: batch, at: 0)
            self.updateBufferedSampleCount()
            self.transferPendingSamplesInBackground()
            DispatchQueue.main.async {
                self.lastError = error.localizedDescription
            }
        }
    }

    private func transferPendingSamplesInBackground() {
        guard WCSession.isSupported(), !pendingSamples.isEmpty else { return }
        let batch = Array(pendingSamples.prefix(backgroundBatchSize))
        pendingSamples.removeFirst(batch.count)
        updateBufferedSampleCount()

        let compactSamples = batch.map(compactSample)
        session.transferUserInfo(["captureToken": captureToken, "samples": compactSamples])
        DispatchQueue.main.async {
            self.sentSampleCount += batch.count
            self.lastSendTime = Date().timeIntervalSince1970
        }

        if pendingSamples.count >= backgroundBatchSize {
            transferPendingSamplesInBackground()
        }
    }

    private func compactSample(_ payload: [String: Any]) -> [Double] {
        [
            Double(payload["timestampNs"] as? Int64 ?? 0),
            payload["accelX"] as? Double ?? 0,
            payload["accelY"] as? Double ?? 0,
            payload["accelZ"] as? Double ?? 0,
            payload["gyroX"] as? Double ?? 0,
            payload["gyroY"] as? Double ?? 0,
            payload["gyroZ"] as? Double ?? 0,
            payload["gravityX"] as? Double ?? 0,
            payload["gravityY"] as? Double ?? 0,
            payload["gravityZ"] as? Double ?? 0,
            payload["quatX"] as? Double ?? 0,
            payload["quatY"] as? Double ?? 0,
            payload["quatZ"] as? Double ?? 0,
            payload["quatW"] as? Double ?? 1,
            payload["heartRateBpm"] as? Double ?? 0
        ]
    }

    private func finishSending(count: Int) {
        isSendingBatch = false
        DispatchQueue.main.async {
            self.sentSampleCount += count
            self.lastSendTime = Date().timeIntervalSince1970
        }
        if pendingSamples.count >= realtimeBatchSize {
            flushPendingSamplesOnBatchQueue()
        }
    }

    private func updateBufferedSampleCount() {
        let count = pendingSamples.count
        DispatchQueue.main.async {
            self.bufferedSampleCount = count
        }
    }

    private func updateMotionStats(timestampNs: Int64) {
        let sampleTime = Double(timestampNs) / 1_000_000_000
        sampleTimes.append(sampleTime)
        let cutoff = sampleTime - 3
        sampleTimes.removeAll { $0 < cutoff }
        let duration = (sampleTimes.last ?? sampleTime) - (sampleTimes.first ?? sampleTime)
        let hz = duration > 0 && sampleTimes.count > 1 ? Double(sampleTimes.count - 1) / duration : 0
        DispatchQueue.main.async {
            self.motionHz = hz
        }
    }

    private func startExtendedRuntimeSession() {
        runtimeSession?.invalidate()
        let runtimeSession = WKExtendedRuntimeSession()
        runtimeSession.delegate = self
        self.runtimeSession = runtimeSession
        runtimeSession.start()
    }

    private func stopExtendedRuntimeSession() {
        runtimeSession?.invalidate()
        runtimeSession = nil
        isRuntimeActive = false
    }

    private func startWorkoutSession() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let shareTypes: Set<HKSampleType> = [HKQuantityType.workoutType()]
        var readTypes: Set<HKObjectType> = []
        if let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) {
            readTypes.insert(heartRateType)
        }

        healthStore.requestAuthorization(toShare: shareTypes, read: readTypes) { [weak self] success, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                }
                return
            }
            guard success else {
                DispatchQueue.main.async {
                    self.lastError = "Health permission denied; background wrist motion needs Heart Rate permission."
                    self.beginMotionUpdatesIfNeeded()
                }
                return
            }

            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .walking
            configuration.locationType = .unknown

            do {
                let workoutSession = try HKWorkoutSession(healthStore: self.healthStore, configuration: configuration)
                let builder = workoutSession.associatedWorkoutBuilder()
                builder.dataSource = HKLiveWorkoutDataSource(healthStore: self.healthStore, workoutConfiguration: configuration)
                workoutSession.delegate = self
                builder.delegate = self
                self.workoutSession = workoutSession
                self.workoutBuilder = builder

                let startDate = Date()
                workoutSession.startActivity(with: startDate)
                builder.beginCollection(withStart: startDate) { _, error in
                    if let error {
                        DispatchQueue.main.async {
                            self.lastError = error.localizedDescription
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.beginMotionUpdatesIfNeeded()
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    self.beginMotionUpdatesIfNeeded()
                }
            }
        }
    }

    private func stopWorkoutSession() {
        let endDate = Date()
        workoutSession?.end()
        workoutBuilder?.endCollection(withEnd: endDate) { [weak self] _, _ in
            self?.workoutBuilder?.finishWorkout { _, _ in }
        }
        workoutSession = nil
        workoutBuilder = nil
        isWorkoutActive = false
    }
}

extension WatchMotionStreamer: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        DispatchQueue.main.async {
            self.isWorkoutActive = toState == .running
            if toState == .running {
                self.beginMotionUpdatesIfNeeded()
            }
            if toState == .ended || toState == .notStarted {
                self.motionManager.stopDeviceMotionUpdates()
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.isWorkoutActive = false
            self.lastError = error.localizedDescription
        }
    }
}

extension WatchMotionStreamer: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate),
              collectedTypes.contains(heartRateType),
              let statistics = workoutBuilder.statistics(for: heartRateType),
              let quantity = statistics.mostRecentQuantity()
        else {
            return
        }

        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        let bpm = quantity.doubleValue(for: bpmUnit)
        DispatchQueue.main.async {
            self.latestHeartRateBpm = bpm
        }
    }
}

extension WatchMotionStreamer: WKExtendedRuntimeSessionDelegate {
    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        DispatchQueue.main.async {
            self.isRuntimeActive = true
        }
    }

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        batchQueue.async {
            self.flushPendingSamplesOnBatchQueue(preferBackgroundTransfer: true)
        }
    }

    func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession, didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {
        DispatchQueue.main.async {
            self.isRuntimeActive = false
            if let error {
                self.lastError = error.localizedDescription
            }
        }
    }
}

extension WatchMotionStreamer: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
        }
        if session.isReachable {
            batchQueue.async {
                self.flushPendingSamplesOnBatchQueue()
            }
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleCommand(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleCommand(userInfo)
    }

    private func handleCommand(_ message: [String: Any]) {
        guard let command = message["command"] as? String else { return }
        DispatchQueue.main.async {
            switch command {
            case "start":
                let token = message["captureToken"] as? String ?? UUID().uuidString
                let targetHz = message["targetHz"] as? Double ?? 30
                self.start(targetHz: targetHz, token: token)
            case "stop":
                self.stop()
            default:
                break
            }
        }
    }
}
