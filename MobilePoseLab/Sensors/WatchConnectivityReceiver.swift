import Foundation
import WatchConnectivity

@MainActor
final class WatchConnectivityReceiver: NSObject, ObservableObject {
    @Published private(set) var isSupported = WCSession.isSupported()
    @Published private(set) var isReachable = false
    @Published private(set) var latestSample: MotionSample?

    private weak var store: CaptureSessionStore?
    private var activeCaptureToken = ""
    private let jsonDecoder = JSONDecoder()

    func activate(store: CaptureSessionStore) {
        self.store = store
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func startWatchCapture(targetHz: Double = 30) {
        activeCaptureToken = UUID().uuidString
        latestSample = nil
        sendCommand(["command": "start", "captureToken": activeCaptureToken, "targetHz": targetHz])
    }

    func stopWatchCapture() {
        sendCommand(["command": "stop"])
        activeCaptureToken = ""
    }

    private func receiveWatchPayload(_ payload: [String: Any]) {
        if let token = payload["captureToken"] as? String, token != activeCaptureToken {
            return
        }

        if let compactSamples = payload["samples"] as? [[Double]] {
            compactSamples.forEach(receiveCompactWatchSample)
            return
        }

        if let samples = payload["samples"] as? [[String: Any]] {
            samples.forEach(receiveWatchPayload)
            return
        }

        guard let store else { return }
        guard payload["captureToken"] as? String == activeCaptureToken else { return }
        let context = store.timestampContext(for: .appleWatch)
        let timestampNs = (payload["timestampNs"] as? Int64) ?? context.timestampNs
        let sample = MotionSample(
            sessionId: context.sessionId,
            source: .appleWatch,
            placement: store.profile.watchPlacement,
            timestampNs: timestampNs,
            secondsElapsed: store.elapsedSeconds(for: timestampNs),
            acceleration: Vector3(
                x: payload["accelX"] as? Double ?? 0,
                y: payload["accelY"] as? Double ?? 0,
                z: payload["accelZ"] as? Double ?? 0
            ),
            rotationRate: Vector3(
                x: payload["gyroX"] as? Double ?? 0,
                y: payload["gyroY"] as? Double ?? 0,
                z: payload["gyroZ"] as? Double ?? 0
            ),
            gravity: Vector3(
                x: payload["gravityX"] as? Double ?? 0,
                y: payload["gravityY"] as? Double ?? 0,
                z: payload["gravityZ"] as? Double ?? 0
            ),
            attitude: Quaternion(
                x: payload["quatX"] as? Double ?? 0,
                y: payload["quatY"] as? Double ?? 0,
                z: payload["quatZ"] as? Double ?? 0,
                w: payload["quatW"] as? Double ?? 1
            ),
            magneticField: nil,
            heartRateBpm: payload["heartRateBpm"] as? Double
        )
        latestSample = sample
        store.append(sample)
    }

    private func receiveWatchData(_ data: Data) {
        guard let batch = try? jsonDecoder.decode(WatchIMUBatch.self, from: data) else { return }
        guard batch.captureToken == activeCaptureToken else { return }
        batch.samples.forEach(receiveCompactWatchSample)
    }

    private func receiveCompactWatchSample(_ values: [Double]) {
        guard values.count >= 14, let store else { return }
        let context = store.timestampContext(for: .appleWatch)
        let timestampNs = Int64(values[0])
        let sample = MotionSample(
            sessionId: context.sessionId,
            source: .appleWatch,
            placement: store.profile.watchPlacement,
            timestampNs: timestampNs,
            secondsElapsed: store.elapsedSeconds(for: timestampNs),
            acceleration: Vector3(x: values[1], y: values[2], z: values[3]),
            rotationRate: Vector3(x: values[4], y: values[5], z: values[6]),
            gravity: Vector3(x: values[7], y: values[8], z: values[9]),
            attitude: Quaternion(x: values[10], y: values[11], z: values[12], w: values[13]),
            magneticField: nil,
            heartRateBpm: values.count > 14 && values[14] > 0 ? values[14] : nil
        )
        latestSample = sample
        store.append(sample)
    }
}

extension WatchConnectivityReceiver: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            isReachable = session.isReachable
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            isReachable = session.isReachable
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            receiveWatchPayload(message)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            receiveWatchPayload(message)
            replyHandler(["ok": true])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor in
            receiveWatchData(messageData)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        Task { @MainActor in
            receiveWatchData(messageData)
            replyHandler(Data())
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            receiveWatchPayload(userInfo)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    private func sendCommand(_ command: [String: Any]) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        if session.isReachable {
            session.sendMessage(command, replyHandler: nil)
        } else {
            session.transferUserInfo(command)
        }
    }
}
