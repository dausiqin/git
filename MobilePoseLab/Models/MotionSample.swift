import Foundation
import CoreMotion

enum SensorSource: String, Codable, CaseIterable, Identifiable {
    case iPhone
    case appleWatch
    case airPods

    var id: String { rawValue }

    var deviceType: String {
        switch self {
        case .iPhone: return "phone"
        case .appleWatch: return "watch"
        case .airPods: return "headphone"
        }
    }
}

enum BodyPlacement: String, Codable, CaseIterable, Identifiable {
    case rightPocket
    case leftPocket
    case leftHand
    case rightHand
    case leftWrist
    case rightWrist
    case head
    case sternum
    case lumbar
    case leftFoot
    case rightFoot
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rightPocket: return "Right pocket"
        case .leftPocket: return "Left pocket"
        case .leftHand: return "Left hand"
        case .rightHand: return "Right hand"
        case .leftWrist: return "Left wrist"
        case .rightWrist: return "Right wrist"
        case .head: return "Head"
        case .sternum: return "Sternum"
        case .lumbar: return "Lumbar"
        case .leftFoot: return "Left foot"
        case .rightFoot: return "Right foot"
        case .unknown: return "Unknown"
        }
    }
}

enum CapturePhase: String, Codable, CaseIterable, Identifiable {
    case idle
    case calibration
    case recording

    var id: String { rawValue }
}

enum MotionReferenceFrame: String, Codable {
    case xArbitraryCorrectedZVertical
    case headphoneDeviceMotion
}

struct StreamingConfig: Equatable {
    var targetHost = "192.168.1.100"
    var targetPort = 8001
    var sendPhone = true
    var sendWatch = true
    var sendAirPods = true
    var phoneDeviceID = "right"
    var watchDeviceID = "left"
    var airPodsDeviceID = "left"
}

struct WatchIMUBatch: Codable {
    var captureToken: String
    var samples: [[Double]]
}

struct Vector3: Codable, Equatable {
    var x: Double
    var y: Double
    var z: Double

    static let zero = Vector3(x: 0, y: 0, z: 0)
}

struct Quaternion: Codable, Equatable {
    var x: Double
    var y: Double
    var z: Double
    var w: Double

    static let identity = Quaternion(x: 0, y: 0, z: 0, w: 1)

    var norm: Double {
        sqrt(x * x + y * y + z * z + w * w)
    }
}

struct Matrix3: Codable, Equatable {
    var m00: Double
    var m01: Double
    var m02: Double
    var m10: Double
    var m11: Double
    var m12: Double
    var m20: Double
    var m21: Double
    var m22: Double

    static let identity = Matrix3(
        m00: 1, m01: 0, m02: 0,
        m10: 0, m11: 1, m12: 0,
        m20: 0, m21: 0, m22: 1
    )
}

struct MotionSample: Codable, Identifiable, Equatable {
    var id = UUID()
    var sessionId: UUID
    var source: SensorSource
    var placement: BodyPlacement
    var capturePhase: CapturePhase = .recording
    var referenceFrame: MotionReferenceFrame = .xArbitraryCorrectedZVertical
    var timestampNs: Int64
    var secondsElapsed: Double
    var acceleration: Vector3
    var rotationRate: Vector3
    var gravity: Vector3
    var attitude: Quaternion
    var magneticField: Vector3?
    var heartRateBpm: Double?
    var eventLabel: String?
    var calibrationTimestampNs: Int64?
    var calibrationGravity: Vector3?
    var calibrationAttitude: Quaternion?

    static var csvHeader: String {
        [
            "session_id", "timestamp_ns", "seconds_elapsed", "source", "placement",
            "capture_phase", "calibration_phase", "event_label", "reference_frame",
            "accel_x_g", "accel_y_g", "accel_z_g",
            "linear_accel_x_m_s2", "linear_accel_y_m_s2", "linear_accel_z_m_s2",
            "gyro_x_rad_s", "gyro_y_rad_s", "gyro_z_rad_s",
            "gravity_x_g", "gravity_y_g", "gravity_z_g",
            "quat_x", "quat_y", "quat_z", "quat_w",
            "rot_00", "rot_01", "rot_02",
            "rot_10", "rot_11", "rot_12",
            "rot_20", "rot_21", "rot_22",
            "gravity_aligned_accel_x_g", "gravity_aligned_accel_y_g", "gravity_aligned_accel_z_g",
            "gravity_aligned_linear_accel_x_m_s2", "gravity_aligned_linear_accel_y_m_s2", "gravity_aligned_linear_accel_z_m_s2",
            "gravity_aligned_gravity_x_g", "gravity_aligned_gravity_y_g", "gravity_aligned_gravity_z_g",
            "gravity_aligned_rot_00", "gravity_aligned_rot_01", "gravity_aligned_rot_02",
            "gravity_aligned_rot_10", "gravity_aligned_rot_11", "gravity_aligned_rot_12",
            "gravity_aligned_rot_20", "gravity_aligned_rot_21", "gravity_aligned_rot_22",
            "mag_x_uT", "mag_y_uT", "mag_z_uT", "heart_rate_bpm",
            "calibration_timestamp_ns",
            "calib_gravity_x_g", "calib_gravity_y_g", "calib_gravity_z_g",
            "calib_quat_x", "calib_quat_y", "calib_quat_z", "calib_quat_w"
        ].joined(separator: ",")
    }

    var csvRow: String {
        let gravityAlignedAcceleration = gravityAlignedAcceleration
        let gravityAlignedGravity = gravityAlignedGravity
        let gravityAlignedRotationMatrix = gravityAlignedRotationMatrix
        let values: [String] = [
            sessionId.uuidString,
            String(timestampNs),
            String(format: "%.9f", secondsElapsed),
            source.rawValue,
            placement.rawValue,
            capturePhase.rawValue,
            capturePhase == .calibration ? "1" : "0",
            eventLabel ?? "",
            referenceFrame.rawValue,
            acceleration.x.csv, acceleration.y.csv, acceleration.z.csv,
            acceleration.x.metersPerSecondSquared.csv,
            acceleration.y.metersPerSecondSquared.csv,
            acceleration.z.metersPerSecondSquared.csv,
            rotationRate.x.csv, rotationRate.y.csv, rotationRate.z.csv,
            gravity.x.csv, gravity.y.csv, gravity.z.csv,
            attitude.x.csv, attitude.y.csv, attitude.z.csv, attitude.w.csv,
            attitude.rotationMatrix.0.csv, attitude.rotationMatrix.1.csv, attitude.rotationMatrix.2.csv,
            attitude.rotationMatrix.3.csv, attitude.rotationMatrix.4.csv, attitude.rotationMatrix.5.csv,
            attitude.rotationMatrix.6.csv, attitude.rotationMatrix.7.csv, attitude.rotationMatrix.8.csv,
            gravityAlignedAcceleration?.x.csv ?? "",
            gravityAlignedAcceleration?.y.csv ?? "",
            gravityAlignedAcceleration?.z.csv ?? "",
            gravityAlignedAcceleration?.x.metersPerSecondSquared.csv ?? "",
            gravityAlignedAcceleration?.y.metersPerSecondSquared.csv ?? "",
            gravityAlignedAcceleration?.z.metersPerSecondSquared.csv ?? "",
            gravityAlignedGravity?.x.csv ?? "",
            gravityAlignedGravity?.y.csv ?? "",
            gravityAlignedGravity?.z.csv ?? "",
            gravityAlignedRotationMatrix?.m00.csv ?? "",
            gravityAlignedRotationMatrix?.m01.csv ?? "",
            gravityAlignedRotationMatrix?.m02.csv ?? "",
            gravityAlignedRotationMatrix?.m10.csv ?? "",
            gravityAlignedRotationMatrix?.m11.csv ?? "",
            gravityAlignedRotationMatrix?.m12.csv ?? "",
            gravityAlignedRotationMatrix?.m20.csv ?? "",
            gravityAlignedRotationMatrix?.m21.csv ?? "",
            gravityAlignedRotationMatrix?.m22.csv ?? "",
            magneticField?.x.csv ?? "",
            magneticField?.y.csv ?? "",
            magneticField?.z.csv ?? "",
            heartRateBpm?.csv ?? "",
            calibrationTimestampNs.map(String.init) ?? "",
            calibrationGravity?.x.csv ?? "",
            calibrationGravity?.y.csv ?? "",
            calibrationGravity?.z.csv ?? "",
            calibrationAttitude?.x.csv ?? "",
            calibrationAttitude?.y.csv ?? "",
            calibrationAttitude?.z.csv ?? "",
            calibrationAttitude?.w.csv ?? ""
        ]
        return values.joined(separator: ",")
    }

    private var gravityAlignmentMatrix: Matrix3? {
        guard let calibrationGravity else { return nil }
        return Matrix3.aligning(from: calibrationGravity, to: Vector3(x: 0, y: -1, z: 0))
    }

    var gravityAlignedAcceleration: Vector3? {
        gravityAlignmentMatrix?.applying(to: acceleration)
    }

    var gravityAlignedGravity: Vector3? {
        gravityAlignmentMatrix?.applying(to: gravity)
    }

    var gravityAlignedRotationMatrix: Matrix3? {
        guard let alignment = gravityAlignmentMatrix else { return nil }
        return alignment.multiplied(by: attitude.matrix)
    }

    var deviceTimeSeconds: Double {
        Double(timestampNs) / 1_000_000_000
    }

    func packetDeviceTime(hostTime: Double) -> Double {
        switch source {
        case .iPhone, .airPods:
            return hostTime
        case .appleWatch:
            return deviceTimeSeconds
        }
    }

    var accelerationMetersPerSecondSquared: Vector3 {
        Vector3(
            x: acceleration.x.metersPerSecondSquared,
            y: acceleration.y.metersPerSecondSquared,
            z: acceleration.z.metersPerSecondSquared
        )
    }

    var gravityMetersPerSecondSquared: Vector3 {
        Vector3(
            x: gravity.x.metersPerSecondSquared,
            y: gravity.y.metersPerSecondSquared,
            z: gravity.z.metersPerSecondSquared
        )
    }

    var gyroAvailable: Bool {
        source != .airPods || rotationRate.length > 0
    }

    func deviceID(config: StreamingConfig) -> String {
        switch source {
        case .iPhone: return config.phoneDeviceID
        case .appleWatch: return config.watchDeviceID
        case .airPods: return config.airPodsDeviceID
        }
    }
}

extension Double {
    var csv: String { String(format: "%.10f", self) }
    var fixed6: String { String(format: "%.6f", self) }
    var metersPerSecondSquared: Double { self * 9.80665 }
}

extension String {
    var csvEscaped: String {
        if contains(",") || contains("\"") || contains("\n") {
            return "\"\(replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return self
    }
}

extension Date {
    var unixNanoseconds: Int64 {
        Int64((timeIntervalSince1970 * 1_000_000_000).rounded())
    }
}

extension Vector3 {
    init(_ acceleration: CMAcceleration) {
        self.init(x: acceleration.x, y: acceleration.y, z: acceleration.z)
    }

    init(_ rotationRate: CMRotationRate) {
        self.init(x: rotationRate.x, y: rotationRate.y, z: rotationRate.z)
    }

    var length: Double {
        sqrt(x * x + y * y + z * z)
    }

    var metersPerSecondSquared: Vector3 {
        Vector3(
            x: x.metersPerSecondSquared,
            y: y.metersPerSecondSquared,
            z: z.metersPerSecondSquared
        )
    }

    var normalized: Vector3? {
        let length = length
        guard length > 1e-8 else { return nil }
        return Vector3(x: x / length, y: y / length, z: z / length)
    }

    func dot(_ other: Vector3) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    func cross(_ other: Vector3) -> Vector3 {
        Vector3(
            x: y * other.z - z * other.y,
            y: z * other.x - x * other.z,
            z: x * other.y - y * other.x
        )
    }
}

extension Quaternion {
    init(_ quaternion: CMQuaternion) {
        self.init(x: quaternion.x, y: quaternion.y, z: quaternion.z, w: quaternion.w)
    }

    var matrix: Matrix3 {
        let rotationMatrix = rotationMatrix
        return Matrix3(
            m00: rotationMatrix.0, m01: rotationMatrix.1, m02: rotationMatrix.2,
            m10: rotationMatrix.3, m11: rotationMatrix.4, m12: rotationMatrix.5,
            m20: rotationMatrix.6, m21: rotationMatrix.7, m22: rotationMatrix.8
        )
    }

    var rotationMatrix: (Double, Double, Double, Double, Double, Double, Double, Double, Double) {
        let xx = x * x
        let yy = y * y
        let zz = z * z
        let xy = x * y
        let xz = x * z
        let yz = y * z
        let wx = w * x
        let wy = w * y
        let wz = w * z

        return (
            1 - 2 * (yy + zz),
            2 * (xy - wz),
            2 * (xz + wy),
            2 * (xy + wz),
            1 - 2 * (xx + zz),
            2 * (yz - wx),
            2 * (xz - wy),
            2 * (yz + wx),
            1 - 2 * (xx + yy)
        )
    }
}

extension Matrix3 {
    static func aligning(from source: Vector3, to target: Vector3) -> Matrix3? {
        guard let source = source.normalized, let target = target.normalized else { return nil }
        let dot = max(-1, min(1, source.dot(target)))

        if dot > 0.999_999 {
            return .identity
        }

        if dot < -0.999_999 {
            let fallbackAxis = abs(source.x) < 0.9 ? Vector3(x: 1, y: 0, z: 0) : Vector3(x: 0, y: 0, z: 1)
            guard let axis = source.cross(fallbackAxis).normalized else { return .identity }
            return rotation(axis: axis, angle: .pi)
        }

        guard let axis = source.cross(target).normalized else { return .identity }
        return rotation(axis: axis, angle: acos(dot))
    }

    static func rotation(axis: Vector3, angle: Double) -> Matrix3 {
        let c = cos(angle)
        let s = sin(angle)
        let t = 1 - c
        let x = axis.x
        let y = axis.y
        let z = axis.z

        return Matrix3(
            m00: t * x * x + c,
            m01: t * x * y - s * z,
            m02: t * x * z + s * y,
            m10: t * x * y + s * z,
            m11: t * y * y + c,
            m12: t * y * z - s * x,
            m20: t * x * z - s * y,
            m21: t * y * z + s * x,
            m22: t * z * z + c
        )
    }

    func applying(to vector: Vector3) -> Vector3 {
        Vector3(
            x: m00 * vector.x + m01 * vector.y + m02 * vector.z,
            y: m10 * vector.x + m11 * vector.y + m12 * vector.z,
            z: m20 * vector.x + m21 * vector.y + m22 * vector.z
        )
    }

    func multiplied(by other: Matrix3) -> Matrix3 {
        Matrix3(
            m00: m00 * other.m00 + m01 * other.m10 + m02 * other.m20,
            m01: m00 * other.m01 + m01 * other.m11 + m02 * other.m21,
            m02: m00 * other.m02 + m01 * other.m12 + m02 * other.m22,
            m10: m10 * other.m00 + m11 * other.m10 + m12 * other.m20,
            m11: m10 * other.m01 + m11 * other.m11 + m12 * other.m21,
            m12: m10 * other.m02 + m11 * other.m12 + m12 * other.m22,
            m20: m20 * other.m00 + m21 * other.m10 + m22 * other.m20,
            m21: m20 * other.m01 + m21 * other.m11 + m22 * other.m21,
            m22: m20 * other.m02 + m21 * other.m12 + m22 * other.m22
        )
    }
}
