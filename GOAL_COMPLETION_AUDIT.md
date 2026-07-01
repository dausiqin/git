# MobilePoseLab goal completion audit

Date: 2026-06-27

This document checks the current MobilePoseLab app against the original MobilePoser / mobile_6Dof / IMU_VIZ frontend collection goal.

## Current status

The app is now a working SwiftUI iOS app with a watchOS companion. It collects iPhone, Apple Watch, and AirPods motion, sends UDP packets from the iPhone, and exports raw CSV. The current implementation also adds a lightweight start procedure:

1. 3 s placement delay
2. 3 s standing gravity baseline capture
3. UDP and CSV output begin after the 6 s preparation window

The gravity baseline is metadata only. The app still does not do MobilePoser tensor generation, T-pose alignment, device2bone, SMPL, or full body/global coordinate conversion.

## Verified evidence

Build:

```bash
xcodebuild -allowProvisioningUpdates \
  -project MobilePoseLab/MobilePoseLab.xcodeproj \
  -scheme MobilePoseLab \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  build
```

Result observed on 2026-06-27:

```text
BUILD SUCCEEDED
```

Tool syntax:

```bash
python3 -m py_compile \
  MobilePoseLab/Tools/udp_smoke_receiver.py \
  MobilePoseLab/Tools/validate_stream_csv.py \
  MobilePoseLab/Tools/replay_csv_udp.py \
  MobilePoseLab/Tools/replay_csv_to_live_demo.py \
  MobilePoseLab/Tools/check_mobileposer_packet_compat.py \
  MobilePoseLab/Tools/check_spicexlab_sensor_utils.py \
  MobilePoseLab/Tools/mobileposer_live_demo_adapter.py \
  MobilePoseLab/Tools/run_local_smoke_tests.py
```

Result: success, no Python syntax errors.

Local UDP smoke test:

```bash
python3 MobilePoseLab/Tools/udp_smoke_receiver.py --port 8001
```

Then three synthetic UDP packets were sent for:

- `right;phone`
- `left;watch`
- `left;headphone`

Receiver output:

```text
headphone/left: count=1 hz=0.0 age=... errors=0 |
phone/right: count=1 hz=0.0 age=... errors=0 |
watch/left: count=1 hz=0.0 age=... errors=0
```

This proves the local packet parser accepts the current wire format. It does not prove real `mobile_6Dof` or IMU_VIZ receiver compatibility.

SPICExLAB/MobilePoser official naming check:

```bash
python3 MobilePoseLab/Tools/check_mobileposer_packet_compat.py \
  "right;phone:1000 1000 0.1 0.2 0.3 0 0 0 1 0.01 0.02 0.03"
```

Expected result:

```text
OK - Right_phone is accepted by official naming rules.
```

SPICExLAB/MobilePoser official parser check:

```bash
python3 Tools/check_spicexlab_sensor_utils.py /tmp/SPICExLAB-MobilePoser \
  "right;phone:1000 1000 0.1 0.2 0.3 0 0 0 1 0.01 0.02 0.03"
```

Observed result:

```text
1: OK - device=3 acc_shape=(1, 3) ori_shape=(1, 4) timestamps=[1000.0, 1000.0]
```

Stock `live_demo.py` adapter smoke test:

```bash
python3 MobilePoseLab/Tools/mobileposer_live_demo_adapter.py \
  --listen-host 127.0.0.1 \
  --listen-port 8001 \
  --output-port 7777 \
  --dry-run \
  --print-outgoing \
  --max-packets 3
```

Three synthetic packets were sent for `right;phone`, `left;watch`, and `left;headphone`.

Observed result:

```text
received=3 forwarded=3 errors=0 active_slots=1:1,2:1,3:1
```

The adapter printed aggregate `acc#quat$` frames suitable for the stock `live_demo.py` UDP input shape. This proves the adapter transforms the app packet shape into the older aggregate socket shape locally. It still does not prove full MobilePoser model inference or visualization.

One-command local toolchain smoke test:

```bash
cd "/Users/qinchenxin/Documents/New project/MobilePoseLab"
python3 Tools/run_local_smoke_tests.py
```

Observed result on 2026-06-27:

```text
PASS: local MobilePoseLab smoke tests completed.
```

This generated a temporary current-schema CSV, validated the raw CSV schema, checked official MobilePoser naming, dry-ran CSV-to-UDP replay, and verified the live-demo adapter output.

The same one-command smoke test also verifies direct CSV-to-`live_demo.py` replay:

```text
would send 3 aggregate packets to 127.0.0.1:7777; rows=9; errors=0; active_slots=1,2,3
```

## Requirement-by-requirement audit

### 1. iOS SwiftUI frontend

Status: implemented and builds.

Evidence:

- `MobilePoseLab/MobilePoseLab/MobilePoseLabApp.swift`
- `MobilePoseLab/MobilePoseLab/Views/CaptureDashboardView.swift`
- Xcode build succeeded.

### 2. User input for computer IP and UDP port

Status: implemented.

Evidence:

- `CaptureDashboardView.swift` has `Computer IP` and UDP port controls.
- `StreamingConfig` defaults to host `192.168.1.100`, port `8001`.
- `UDPSender.start(host:port:)` uses the UI config.

### 3. Device toggles and placement metadata

Status: implemented.

Evidence:

- `StreamingConfig` has `sendPhone`, `sendWatch`, and `sendAirPods`.
- `CaptureProfile` stores phone, watch, and headphone placement.
- CSV rows include `placement`.

### 4. iPhone CoreMotion capture

Status: implemented.

Evidence:

- `PhoneMotionRecorder.swift` uses `CMMotionManager`.
- Uses `.xArbitraryCorrectedZVertical`.
- Captures `userAcceleration`, `rotationRate`, `gravity`, and `attitude.quaternion`.

### 5. Apple Watch companion app

Status: implemented.

Evidence:

- `WatchCompanion/WatchMotionStreamer.swift`
- Uses `CMMotionManager`, `WCSession`, `HKWorkoutSession`, `HKLiveWorkoutBuilder`, and `WKExtendedRuntimeSession`.
- Watch UI shows reachability, runtime, workout, motion Hz, last send age, sent/buffer/drop counts.

### 6. Watch HealthKit / workout stability mode

Status: implemented.

Evidence:

- `WatchMotionStreamer.startWorkoutSession()`
- Watch extension Info.plist includes HealthKit usage strings and workout background mode.
- Watch extension entitlements include HealthKit.

### 7. AirPods Pro / headphone motion

Status: implemented.

Evidence:

- `AirPodsMotionRecorder.swift`
- Uses `CMHeadphoneMotionManager`.
- Tracks availability, connection, and authorization status.
- Sends `headphone` device type.

### 8. UDP packet format

Status: implemented and locally smoke-tested.

Evidence:

- `PacketFormatter.formatUDPPacket(sample:config:hostTime:)`
- Output shape:

```text
device_id;device_type:host_time device_time ax ay az qx qy qz qw [gx gy gz]
```

Notes:

- Acceleration is converted to `m/s^2`.
- Gyro is `rad/s`.
- Quaternion order is xyzw.
- AirPods gyro is omitted only if unavailable.

Official SPICExLAB/MobilePoser note:

- `sensor_utils.process_data()` builds device lookup keys as `f"{device_id.capitalize()}_{device_type}"`.
- The current defaults are `phone=right`, `watch=left`, `headphone=left`, producing `Right_phone`, `Left_watch`, and `Left_headphone`.
- Custom backends may use descriptive IDs like `iphone_001`, but stock SPICExLAB receiver naming is side-based.
- Stock `live_demo.py` also has an older Noitom UDP format (`acc#quat$`) and should not be treated as the same socket format as the iOS/mobile_6Dof parser path.
- `Tools/mobileposer_live_demo_adapter.py` can bridge current app packets on UDP 8001 to stock `live_demo.py` aggregate packets on UDP 7777.
- `Tools/replay_csv_to_live_demo.py` can replay exported CSV directly into stock `live_demo.py` aggregate UDP format without running the live adapter.

### 9. iPhone as unified forwarding center

Status: implemented.

Evidence:

- iPhone samples are appended directly.
- Watch samples arrive via `WatchConnectivityReceiver` and are forwarded by `CaptureSessionStore`.
- AirPods samples are captured on iPhone and forwarded by `CaptureSessionStore`.
- UDP is sent only by the iOS app.

Important backend note:

- Use `host_time_s` for cross-device alignment.
- `device_time_s` is source-device time and should be treated as diagnostic/drift metadata, especially for Watch.

### 10. Local raw CSV export

Status: implemented.

Evidence:

- `CaptureSessionStore.streamCSVHeader`
- `CaptureSessionStore.csvRow(for:hostTime:receiveTime:)`
- `CaptureDashboardView` has `Export CSV` and `ShareLink`.

Current raw CSV header:

```text
session_id,source,device_type,device_id,placement,packet_seq,host_time_s,device_time_s,receive_time_s,ax_m_s2,ay_m_s2,az_m_s2,gx_rad_s,gy_rad_s,gz_rad_s,gyro_available,quat_x,quat_y,quat_z,quat_w,gravity_x_m_s2,gravity_y_m_s2,gravity_z_m_s2,user_accel_x_m_s2,user_accel_y_m_s2,user_accel_z_m_s2,raw_extra_json
```

### 11. Gravity baseline metadata

Status: implemented as lightweight metadata.

Evidence:

- `CaptureSessionStore.updateGravityCalibration(with:hostTime:)`
- `CaptureSessionStore.finalizeGravityCalibration()`
- `raw_extra_json` includes:

```json
{
  "reference_frame": "xArbitraryCorrectedZVertical",
  "capture_phase": "recording",
  "gravity_calibration_samples": 90,
  "gravity_calibration_baseline_m_s2": {
    "x": 0.0,
    "y": -9.81,
    "z": 0.0
  },
  "gravity_calibration_norm_m_s2": 9.81
}
```

This is not a formal calibration output. Backend should use it to estimate Up/Down and check stationary quality.

### 12. UI status and quality metrics

Status: implemented.

Evidence:

- iOS dashboard shows per-source Hz, packet count, packet age, dropped-frame estimate, acceleration norm, quaternion norm.
- Diagnostics show UDP packet count, CSV rows, preparation status, gravity baseline count, Watch reachability/latency, AirPods availability/connection/auth.

### 13. No app-side MobilePoser inference or formal calibration

Status: implemented as intended.

Evidence:

- No MobilePoser model code.
- No SMPL or device2bone output.
- UDP/CSV output remains raw API coordinates plus metadata.
- The old legacy local sample export can still include gravity-aligned diagnostic columns only if no stream CSV rows exist, but the normal streaming/export path uses the raw schema above.

## Remaining unproven acceptance criteria

The original goal says the final proof is:

1. Computer runs IMU_VIZ or mobile_6Dof receiver.
2. App sends phone/watch/headphone UDP to computer IP:8001.
3. Backend recognizes iOS format.
4. IMU_VIZ shows device data.
5. mobile_6Dof `IMU_receiver.py` receives devices.
6. Computer-side Global Alignment and T-pose Calibration can proceed.

Current evidence does not yet prove those six items. The local smoke receiver proves packet shape, but it is not the real receiver. Therefore the overall goal should remain open until one of these is done:

- Run the app against a real IMU_VIZ receiver and confirm all selected devices appear.
- Run the app against the real `mobile_6Dof/IMU_receiver.py` and confirm `phone`, `watch`, and `headphone` devices are parsed.
- Or replay a current-schema MobilePoseLab CSV into the actual receiver using `Tools/replay_csv_udp.py` and confirm the receiver accepts it.

The exact PC-side procedure is documented in:

```text
HANDOFF_INDEX.md
PC_REAL_RECEIVER_RUNBOOK.md
```

## Recommended next verification step

On the backend computer:

```bash
cd <mobile_6Dof_or_IMU_VIZ_repo>
python IMU_receiver.py
```

On the Mac, either use live app streaming or replay a CSV:

```bash
cd "/Users/qinchenxin/Documents/New project/MobilePoseLab"
python3 Tools/replay_csv_udp.py /path/to/current_schema_mobile_pose_lab.csv --host <PC_IP> --port 8001
```

Then verify on the backend:

- all expected device IDs appear
- device types are `phone`, `watch`, `headphone`
- acceleration magnitude and quaternion norm look sane
- global alignment / T-pose calibration can be triggered from the PC side

## Conclusion

The frontend implementation is substantially complete and locally verified. The only major missing proof is real receiver integration with IMU_VIZ or mobile_6Dof. Until that integration is observed, the full goal is not completed.
