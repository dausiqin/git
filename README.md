# Mobile Pose Lab

Native SwiftUI scaffold for collecting iPhone, Apple Watch, and AirPods IMU data for MobilePoser-style research.

For handoff to another Codex thread or the Windows backend, start with `HANDOFF_INDEX.md`.

## Open

Open:

```sh
/Users/qinchenxin/Documents/New\ project/MobilePoseLab/MobilePoseLab.xcodeproj
```

The project contains the iOS app target, a companion Watch App target, and a Watch Extension target.

## What Works Now

- iPhone `CMDeviceMotion` capture.
- AirPods `CMHeadphoneMotionManager` capture.
- Apple Watch payload receiver via `WatchConnectivity`.
- Apple Watch companion app that streams watch IMU data to the iPhone.
- Unified `MotionSample` schema with timestamp, device source, body placement, acceleration, rotation rate, gravity, and quaternion.
- UDP streaming in the `mobile_6Dof` / `IMU_VIZ` packet format.
- Raw CSV export for Python preprocessing.
- Backend helper tools in `Tools/` for UDP smoke tests, CSV validation, and CSV-to-UDP replay.
- Research profiles for MobilePoser baseline, spine posture, and foot-loading pilot studies.

## MobilePoser Receiver IDs

The default UDP device IDs are set for the SPICExLAB/MobilePoser `sensor_utils.process_data()` naming rule:

```text
right;phone:...
left;watch:...
left;headphone:...
```

That receiver builds keys such as `Right_phone`, `Left_watch`, and `Left_headphone`. If you use a custom backend, you can change the IDs in the app UI to names like `iphone_001`, `watch_001`, and `airpods_001`.

## Verified Build

The full iOS app with embedded Watch app builds with the `MobilePoseLab` scheme:

```sh
xcodebuild -allowProvisioningUpdates \
  -project /Users/qinchenxin/Documents/New\ project/MobilePoseLab/MobilePoseLab.xcodeproj \
  -scheme MobilePoseLab \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  build
```

That scheme builds the iOS app, the embedded watchOS app, and the Watch extension in dependency order. For local backend-tool checks, run:

```sh
cd /Users/qinchenxin/Documents/New\ project/MobilePoseLab
python3 Tools/run_local_smoke_tests.py
```

## Install On Apple Watch

1. Pair the Apple Watch with your iPhone.
2. Connect the iPhone to the Mac.
3. Open `MobilePoseLab.xcodeproj` in Xcode.
4. Select the `MobilePoseLab` target/scheme and choose your physical iPhone as the run device.
5. Make sure both iPhone and Apple Watch have Developer Mode enabled if Xcode asks for it.
6. Press Run. Xcode installs the iPhone app and the embedded `MobilePoseLabWatch` app on the paired Apple Watch.
7. Open `MobilePoseLab` on the iPhone, enter the computer IP and keep UDP port `8001`.
8. Tap `Start Upload` to send UDP only, or `Start Upload + CSV` if you explicitly want UDP upload and local CSV recording at the same time. The app gives 3 seconds to place devices and 3 seconds to stand still for a gravity baseline before upload starts.
9. Open `MobilePoseLabWatch` if you want to inspect watch-side status; the iPhone can also start/stop watch capture through WatchConnectivity.

## Backend Tools

```sh
python3 Tools/udp_smoke_receiver.py --port 8001
python3 Tools/validate_stream_csv.py path/to/mobile_pose_lab.csv --target-hz 30
python3 Tools/check_mobileposer_packet_compat.py path/to/mobile_pose_lab.csv
python3 Tools/check_spicexlab_sensor_utils.py /path/to/MobilePoser path/to/mobile_pose_lab.csv
python3 Tools/replay_csv_udp.py path/to/mobile_pose_lab.csv --host 127.0.0.1 --port 8001
python3 Tools/mobileposer_live_demo_adapter.py --listen-port 8001 --output-port 7777
python3 Tools/replay_csv_to_live_demo.py path/to/mobile_pose_lab.csv --host 127.0.0.1 --port 7777
python3 Tools/run_local_smoke_tests.py
```

`mobileposer_live_demo_adapter.py` is only for the stock SPICExLAB `live_demo.py` path that expects aggregate `acc#quat$` packets on UDP 7777. For the iOS/mobile_6Dof parser path, send MobilePoseLab packets directly to UDP 8001.

`run_local_smoke_tests.py` creates a temporary current-schema CSV and checks the validator, official MobilePoser naming, CSV-to-UDP replay dry-run, and live-demo adapter without requiring iOS hardware.

## Next Steps

1. Follow `PC_REAL_RECEIVER_RUNBOOK.md` on the Windows/PC backend.
2. Validate with the real IMU_VIZ, mobile_6Dof receiver, or stock MobilePoser `live_demo.py` via adapter.
3. Add clock offset estimation before serious multi-device experiments.
4. Write the Python converter from exported long-format CSV to MobilePoser tensors.
