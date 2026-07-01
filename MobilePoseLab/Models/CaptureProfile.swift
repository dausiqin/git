import Foundation

struct CaptureProfile: Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var targetHz: Double
    var phonePlacement: BodyPlacement
    var watchPlacement: BodyPlacement
    var headphonePlacement: BodyPlacement
    var notes: String

    static let mobilePoserBaseline = CaptureProfile(
        name: "MobilePoser 30Hz lw_rp_h",
        targetHz: 30,
        phonePlacement: .rightPocket,
        watchPlacement: .leftWrist,
        headphonePlacement: .head,
        notes: "Matches the official MobilePoser dataset FPS. Exported streams should still be resampled onto one 30 Hz timeline during preprocessing."
    )

    static let imuPoserCompatible = CaptureProfile(
        name: "IMUPoser 25Hz lw_rp_h",
        targetHz: 25,
        phonePlacement: .rightPocket,
        watchPlacement: .leftWrist,
        headphonePlacement: .head,
        notes: "Matches IMUPoser-style 25 Hz capture, capped by AirPods in the original study."
    )

    static let debugStable = CaptureProfile(
        name: "Debug stable 30Hz",
        targetHz: 30,
        phonePlacement: .rightPocket,
        watchPlacement: .leftWrist,
        headphonePlacement: .head,
        notes: "Lower-rate debugging profile for checking connectivity and CSV quality."
    )

    static let spineStudy = CaptureProfile(
        name: "Spine posture study",
        targetHz: 30,
        phonePlacement: .lumbar,
        watchPlacement: .leftWrist,
        headphonePlacement: .head,
        notes: "For daily-device posture studies. Use a belt/waist mount for the phone when possible."
    )

    static let footLoadingPilot = CaptureProfile(
        name: "Foot loading pilot",
        targetHz: 30,
        phonePlacement: .rightPocket,
        watchPlacement: .leftWrist,
        headphonePlacement: .head,
        notes: "IMU-only proxy for gait phases and foot contact. True plantar pressure still needs instrumented insoles or force plates for labels."
    )

    static let defaults: [CaptureProfile] = [
        .mobilePoserBaseline,
        .imuPoserCompatible,
        .debugStable,
        .spineStudy,
        .footLoadingPilot
    ]
}
