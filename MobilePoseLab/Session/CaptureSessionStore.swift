import Foundation
import Combine
import Network

struct CalibrationBaseline: Codable, Equatable {
    var source: SensorSource
    var timestampNs: Int64
    var gravity: Vector3
    var attitude: Quaternion
}

struct SensorQualitySummary: Identifiable, Equatable {
    var source: SensorSource
    var sampleCount: Int
    var durationSeconds: Double
    var averageHz: Double
    var gapCount: Int
    var placement: BodyPlacement

    var id: SensorSource { source }
}

struct StreamSourceStats: Identifiable, Equatable {
    var source: SensorSource
    var packetCount = 0
    var hz = 0.0
    var droppedFrameEstimate = 0
    var lastHostTime = 0.0
    var lastDeviceTime = 0.0
    var lastAccelerationNorm = 0.0
    var lastQuaternionNorm = 0.0

    var id: SensorSource { source }
    var packetAge: Double {
        guard lastHostTime > 0 else { return 0 }
        return max(0, ProcessInfo.processInfo.systemUptime - lastHostTime)
    }
}

struct GravityCalibrationSnapshot: Equatable {
    var source: SensorSource
    var baselineGravity: Vector3
    var sampleCount: Int
}

final class UDPSender {
    private let queue = DispatchQueue(label: "MobilePoseLab.udp.sender")
    private var connection: NWConnection?
    private(set) var isStarted = false
    private(set) var lastError = ""

    func start(host: String, port: Int) {
        stop()
        guard (0...65_535).contains(port) else {
            lastError = "Invalid UDP port"
            return
        }
        guard let udpPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            lastError = "Invalid UDP port"
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: udpPort, using: .udp)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.lastError = error.localizedDescription
            }
        }
        self.connection = connection
        connection.start(queue: queue)
        isStarted = true
        lastError = ""
    }

    func stop() {
        connection?.cancel()
        connection = nil
        isStarted = false
    }

    func send(_ packet: String, completion: @escaping (String?) -> Void) {
        guard let connection, isStarted else {
            completion("UDP sender is not started")
            return
        }
        let data = Data(packet.utf8)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            let message = error?.localizedDescription
            if let message {
                self?.lastError = message
            }
            completion(message)
        })
    }
}

@MainActor
final class CaptureSessionStore: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var samples: [MotionSample] = []
    @Published private(set) var currentSessionId = UUID()
    @Published private(set) var calibrationBaselines: [SensorSource: CalibrationBaseline] = [:]
    @Published private(set) var currentPhase: CapturePhase = .idle
    @Published private(set) var lastEventLabel: String?
    @Published var profile: CaptureProfile = .mobilePoserBaseline
    @Published var streamingConfig = StreamingConfig()
    @Published private(set) var isStreaming = false
    @Published private(set) var isCSVRecording = false
    @Published private(set) var csvRowCount = 0
    @Published private(set) var udpPacketCount = 0
    @Published private(set) var lastUDPError = ""
    @Published private(set) var lastPacketHostTime = 0.0
    @Published private(set) var sourceStats: [SensorSource: StreamSourceStats] = [:]
    @Published private(set) var streamPreparationStatus = "Idle"
    @Published private(set) var gravityCalibrationSnapshots: [SensorSource: GravityCalibrationSnapshot] = [:]

    private var startDate: Date?
    private var startTimestampNs: Int64?
    private let maxLiveSamples = 120_000
    private var exportedFiles: [URL] = []
    private var pendingEventLabel: String?
    private let udpSender = UDPSender()
    private var csvRows: [String] = []
    private var csvPacketSequence = 0
    private var statsWindows: [SensorSource: [Double]] = [:]
    private var pendingSourceStats: [SensorSource: StreamSourceStats] = [:]
    private var internalUDPPacketCount = 0
    private var internalCSVRowCount = 0
    private var internalLastPacketHostTime = 0.0
    private var lastUIPublishHostTime = 0.0
    private var lastPreparationStatusPublishHostTime = 0.0
    private let uiPublishIntervalSeconds = 0.5
    private var streamStartHostTime = 0.0
    private let placementDelaySeconds = 3.0
    private let gravityCalibrationSeconds = 3.0
    private var gravityCalibrationSamples: [SensorSource: [Vector3]] = [:]

    var elapsed: Double {
        guard let startDate else { return 0 }
        return Date().timeIntervalSince(startDate)
    }

    func start(clearCalibration: Bool = true, phase: CapturePhase = .recording) {
        removeExportedFiles()
        currentSessionId = UUID()
        samples.removeAll(keepingCapacity: true)
        if clearCalibration {
            calibrationBaselines.removeAll(keepingCapacity: true)
        }
        let startDate = Date()
        self.startDate = startDate
        startTimestampNs = startDate.unixNanoseconds
        currentPhase = phase
        pendingEventLabel = nil
        lastEventLabel = nil
        isRecording = true
    }

    func startStreaming() {
        udpSender.start(host: streamingConfig.targetHost, port: streamingConfig.targetPort)
        udpPacketCount = 0
        lastUDPError = udpSender.lastError
        lastPacketHostTime = 0
        internalUDPPacketCount = 0
        internalCSVRowCount = 0
        internalLastPacketHostTime = 0
        lastUIPublishHostTime = 0
        lastPreparationStatusPublishHostTime = 0
        sourceStats.removeAll(keepingCapacity: true)
        pendingSourceStats.removeAll(keepingCapacity: true)
        statsWindows.removeAll(keepingCapacity: true)
        gravityCalibrationSamples.removeAll(keepingCapacity: true)
        gravityCalibrationSnapshots.removeAll(keepingCapacity: true)
        streamStartHostTime = ProcessInfo.processInfo.systemUptime
        streamPreparationStatus = "Place devices: 3.0 s"
        isStreaming = true
    }

    func stopStreaming() {
        publishUIStatsIfNeeded(hostTime: ProcessInfo.processInfo.systemUptime, force: true)
        udpSender.stop()
        isStreaming = false
        streamPreparationStatus = "Idle"
    }

    func startCSVRecording() {
        csvRows.removeAll(keepingCapacity: true)
        csvPacketSequence = 0
        csvRowCount = 0
        internalCSVRowCount = 0
        isCSVRecording = true
    }

    func stopCSVRecording() {
        isCSVRecording = false
    }

    func stop() {
        isRecording = false
        currentPhase = .idle
    }

    func setPhase(_ phase: CapturePhase) {
        currentPhase = phase
    }

    func markEvent(_ label: String = "event") {
        pendingEventLabel = label
        lastEventLabel = label
    }

    func trimTail(seconds: Double) {
        guard seconds > 0, let lastElapsed = samples.last?.secondsElapsed else { return }
        let cutoff = max(0, lastElapsed - seconds)
        samples.removeAll { $0.secondsElapsed > cutoff }
    }

    func append(_ sample: MotionSample) {
        let hostTime = ProcessInfo.processInfo.systemUptime
        let receiveTime = hostTime
        let streamOutputReady = updateGravityCalibration(with: sample, hostTime: hostTime)
        if isStreaming, streamOutputReady, shouldSend(sample.source) {
            sendUDPPacket(for: sample, hostTime: hostTime)
        }
        if isCSVRecording, streamOutputReady {
            csvRows.append(csvRow(for: sample, hostTime: hostTime, receiveTime: receiveTime))
            internalCSVRowCount = csvRows.count
            publishUIStatsIfNeeded(hostTime: hostTime)
        }

        guard isRecording else { return }
        var calibratedSample = sample
        calibratedSample.capturePhase = currentPhase
        if let pendingEventLabel {
            calibratedSample.eventLabel = pendingEventLabel
            self.pendingEventLabel = nil
        }
        if let baseline = calibrationBaselines[sample.source] {
            calibratedSample.calibrationTimestampNs = baseline.timestampNs
            calibratedSample.calibrationGravity = baseline.gravity
            calibratedSample.calibrationAttitude = baseline.attitude
        }
        samples.append(calibratedSample)
        if samples.count > maxLiveSamples {
            samples.removeFirst(samples.count - maxLiveSamples)
        }
    }

    func calibrate(with latestSamples: [MotionSample]) {
        for sample in latestSamples {
            calibrationBaselines[sample.source] = CalibrationBaseline(
                source: sample.source,
                timestampNs: sample.timestampNs,
                gravity: sample.gravity,
                attitude: sample.attitude
            )
        }
    }

    func clearCalibration() {
        calibrationBaselines.removeAll(keepingCapacity: true)
    }

    var qualitySummaries: [SensorQualitySummary] {
        SensorSource.allCases.compactMap { source in
            let sourceSamples = samples
                .filter { $0.source == source }
                .sorted { $0.secondsElapsed < $1.secondsElapsed }
            guard let first = sourceSamples.first else { return nil }
            let duration = max(0, (sourceSamples.last?.secondsElapsed ?? first.secondsElapsed) - first.secondsElapsed)
            let averageHz = duration > 0 && sourceSamples.count > 1 ? Double(sourceSamples.count - 1) / duration : 0
            let expectedInterval = 1.0 / max(profile.targetHz, 1)
            let gapThreshold = max(0.12, expectedInterval * 3)
            let gapCount = zip(sourceSamples, sourceSamples.dropFirst()).reduce(0) { count, pair in
                count + (pair.1.secondsElapsed - pair.0.secondsElapsed > gapThreshold ? 1 : 0)
            }
            return SensorQualitySummary(
                source: source,
                sampleCount: sourceSamples.count,
                durationSeconds: duration,
                averageHz: averageHz,
                gapCount: gapCount,
                placement: first.placement
            )
        }
    }

    func timestampContext(for source: SensorSource) -> (sessionId: UUID, timestampNs: Int64, secondsElapsed: Double) {
        let now = Date()
        let seconds = startDate.map { now.timeIntervalSince($0) } ?? 0
        return (currentSessionId, now.unixNanoseconds, seconds)
    }

    func elapsedSeconds(for timestampNs: Int64) -> Double {
        guard let startTimestampNs else { return 0 }
        return max(0, Double(timestampNs - startTimestampNs) / 1_000_000_000)
    }

    func exportCSV() throws -> URL {
        let fileName = "mobile_pose_lab_\(currentSessionId.uuidString).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        let body: String
        if !csvRows.isEmpty {
            body = ([Self.streamCSVHeader] + csvRows).joined(separator: "\n")
        } else {
            body = ([MotionSample.csvHeader] + samples.map(\.csvRow)).joined(separator: "\n")
        }
        try body.write(to: url, atomically: true, encoding: .utf8)
        trackExport(url)
        return url
    }

    func exportJSONL() throws -> URL {
        let fileName = "mobile_pose_lab_\(currentSessionId.uuidString).jsonl"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines = try samples.map { sample in
            try String(data: encoder.encode(sample), encoding: .utf8) ?? "{}"
        }.joined(separator: "\n")
        try lines.write(to: url, atomically: true, encoding: .utf8)
        trackExport(url)
        return url
    }

    func removeExportedFiles() {
        for url in exportedFiles {
            try? FileManager.default.removeItem(at: url)
        }
        exportedFiles.removeAll()
    }

    private func trackExport(_ url: URL) {
        exportedFiles.append(url)
    }

    private func shouldSend(_ source: SensorSource) -> Bool {
        switch source {
        case .iPhone: return streamingConfig.sendPhone
        case .appleWatch: return streamingConfig.sendWatch
        case .airPods: return streamingConfig.sendAirPods
        }
    }

    private func updateGravityCalibration(with sample: MotionSample, hostTime: Double) -> Bool {
        guard isStreaming else { return true }
        let elapsed = hostTime - streamStartHostTime
        if elapsed < placementDelaySeconds {
            publishPreparationStatus(String(format: "Place devices: %.1f s", placementDelaySeconds - elapsed), hostTime: hostTime)
            return false
        }

        let calibrationElapsed = elapsed - placementDelaySeconds
        if calibrationElapsed < gravityCalibrationSeconds {
            gravityCalibrationSamples[sample.source, default: []].append(sample.gravity)
            publishPreparationStatus(String(format: "Stand still calibration: %.1f s", gravityCalibrationSeconds - calibrationElapsed), hostTime: hostTime)
            return false
        }

        if gravityCalibrationSnapshots.isEmpty {
            finalizeGravityCalibration()
        }
        streamPreparationStatus = "Streaming"
        return true
    }

    private func publishPreparationStatus(_ status: String, hostTime: Double) {
        guard hostTime - lastPreparationStatusPublishHostTime >= uiPublishIntervalSeconds else { return }
        streamPreparationStatus = status
        lastPreparationStatusPublishHostTime = hostTime
    }

    private func finalizeGravityCalibration() {
        gravityCalibrationSnapshots = gravityCalibrationSamples.reduce(into: [:]) { result, entry in
            let samples = entry.value
            guard !samples.isEmpty else { return }
            let sum = samples.reduce(Vector3.zero) { partial, gravity in
                Vector3(
                    x: partial.x + gravity.x,
                    y: partial.y + gravity.y,
                    z: partial.z + gravity.z
                )
            }
            let count = Double(samples.count)
            result[entry.key] = GravityCalibrationSnapshot(
                source: entry.key,
                baselineGravity: Vector3(x: sum.x / count, y: sum.y / count, z: sum.z / count),
                sampleCount: samples.count
            )
        }
    }

    private func sendUDPPacket(for sample: MotionSample, hostTime: Double) {
        let packet = PacketFormatter.formatUDPPacket(sample: sample, config: streamingConfig, hostTime: hostTime)
        udpSender.send(packet) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.lastUDPError = error
                } else {
                    self.internalUDPPacketCount += 1
                    self.internalLastPacketHostTime = hostTime
                    self.updateStats(for: sample, hostTime: hostTime)
                    self.publishUIStatsIfNeeded(hostTime: hostTime)
                }
            }
        }
    }

    private func updateStats(for sample: MotionSample, hostTime: Double) {
        var window = statsWindows[sample.source, default: []]
        window.append(hostTime)
        let cutoff = hostTime - 3
        window.removeAll { $0 < cutoff }
        statsWindows[sample.source] = window

        let duration = (window.last ?? hostTime) - (window.first ?? hostTime)
        let hz = duration > 0 && window.count > 1 ? Double(window.count - 1) / duration : 0
        let expectedInterval = 1.0 / max(profile.targetHz, 1)
        let expectedSamples = duration > 0 ? Int((duration / expectedInterval).rounded()) + 1 : window.count
        let droppedFrameEstimate = max(0, expectedSamples - window.count)
        pendingSourceStats[sample.source] = StreamSourceStats(
            source: sample.source,
            packetCount: pendingSourceStats[sample.source, default: StreamSourceStats(source: sample.source)].packetCount + 1,
            hz: hz,
            droppedFrameEstimate: droppedFrameEstimate,
            lastHostTime: hostTime,
            lastDeviceTime: sample.deviceTimeSeconds,
            lastAccelerationNorm: sample.accelerationMetersPerSecondSquared.length,
            lastQuaternionNorm: sample.attitude.norm
        )
    }

    private func publishUIStatsIfNeeded(hostTime: Double, force: Bool = false) {
        guard force || hostTime - lastUIPublishHostTime >= uiPublishIntervalSeconds else { return }
        udpPacketCount = internalUDPPacketCount
        csvRowCount = internalCSVRowCount
        lastPacketHostTime = internalLastPacketHostTime
        sourceStats = pendingSourceStats
        lastUIPublishHostTime = hostTime
    }

    private static var streamCSVHeader: String {
        [
            "session_id", "source", "device_type", "device_id", "placement", "packet_seq",
            "host_time_s", "device_time_s", "receive_time_s",
            "ax_m_s2", "ay_m_s2", "az_m_s2",
            "gx_rad_s", "gy_rad_s", "gz_rad_s", "gyro_available",
            "quat_x", "quat_y", "quat_z", "quat_w",
            "gravity_x_m_s2", "gravity_y_m_s2", "gravity_z_m_s2",
            "user_accel_x_m_s2", "user_accel_y_m_s2", "user_accel_z_m_s2",
            "raw_extra_json"
        ].joined(separator: ",")
    }

    private func csvRow(for sample: MotionSample, hostTime: Double, receiveTime: Double) -> String {
        csvPacketSequence += 1
        let acceleration = sample.accelerationMetersPerSecondSquared
        let gravity = sample.gravityMetersPerSecondSquared
        let calibration = gravityCalibrationSnapshots[sample.source]
        let rawExtra = Self.rawExtraJSON(for: sample, calibration: calibration)
        let deviceTime = sample.packetDeviceTime(hostTime: hostTime)
        let values = [
            currentSessionId.uuidString,
            sample.source.rawValue,
            sample.source.deviceType,
            sample.deviceID(config: streamingConfig),
            sample.placement.rawValue,
            String(csvPacketSequence),
            hostTime.fixed6,
            deviceTime.fixed6,
            receiveTime.fixed6,
            acceleration.x.fixed6,
            acceleration.y.fixed6,
            acceleration.z.fixed6,
            sample.rotationRate.x.fixed6,
            sample.rotationRate.y.fixed6,
            sample.rotationRate.z.fixed6,
            sample.gyroAvailable ? "1" : "0",
            sample.attitude.x.fixed6,
            sample.attitude.y.fixed6,
            sample.attitude.z.fixed6,
            sample.attitude.w.fixed6,
            gravity.x.fixed6,
            gravity.y.fixed6,
            gravity.z.fixed6,
            acceleration.x.fixed6,
            acceleration.y.fixed6,
            acceleration.z.fixed6,
            rawExtra.csvEscaped
        ]
        return values.joined(separator: ",")
    }

    private static func rawExtraJSON(for sample: MotionSample, calibration: GravityCalibrationSnapshot?) -> String {
        var fields = [
            "\"reference_frame\":\"\(sample.referenceFrame.rawValue)\"",
            "\"capture_phase\":\"\(sample.capturePhase.rawValue)\"",
            "\"gravity_calibration_samples\":\(calibration?.sampleCount ?? 0)"
        ]

        if let calibration {
            let baseline = calibration.baselineGravity.metersPerSecondSquared
            fields.append("\"gravity_calibration_baseline_m_s2\":{\"x\":\(baseline.x.fixed6),\"y\":\(baseline.y.fixed6),\"z\":\(baseline.z.fixed6)}")
            fields.append("\"gravity_calibration_norm_m_s2\":\(baseline.length.fixed6)")
        }

        return "{\(fields.joined(separator: ","))}"
    }
}

enum PacketFormatter {
    static func formatUDPPacket(sample: MotionSample, config: StreamingConfig, hostTime: Double) -> String {
        // mobile_6Dof / IMU_VIZ format:
        // device_id;device_type:host_time device_time ax ay az qx qy qz qw [gx gy gz]
        // host_time/device_time are seconds, acceleration is m/s^2, gyro is rad/s,
        // and quaternion order is CoreMotion xyzw.
        let acceleration = sample.accelerationMetersPerSecondSquared
        let deviceTime = sample.packetDeviceTime(hostTime: hostTime)
        var parts = [
            hostTime.fixed6,
            deviceTime.fixed6,
            acceleration.x.fixed6,
            acceleration.y.fixed6,
            acceleration.z.fixed6,
            sample.attitude.x.fixed6,
            sample.attitude.y.fixed6,
            sample.attitude.z.fixed6,
            sample.attitude.w.fixed6
        ]
        if sample.gyroAvailable {
            parts.append(contentsOf: [
                sample.rotationRate.x.fixed6,
                sample.rotationRate.y.fixed6,
                sample.rotationRate.z.fixed6
            ])
        }
        return "\(sample.deviceID(config: config));\(sample.source.deviceType):\(parts.joined(separator: " "))"
    }
}
