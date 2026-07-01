# Mobile Pose Lab

Mobile Pose Lab is a native SwiftUI research app scaffold for collecting synchronized IMU streams from iPhone, Apple Watch, and AirPods. The first target is to produce clean datasets for reproducing MobilePoser-style experiments, then extend the protocol toward daily-device spine posture and foot-loading studies.

## Why a new native app

- `AppleRawData` is useful watchOS sample code, but it only reads accelerometer values and does not provide iPhone/AirPods capture, session storage, or export.
- `react-native-headphone-motion` proves the AirPods CoreMotion API path, but the research app should keep timing, storage, and future CoreML inference in Swift.
- `awesome-sensor-logger` is documentation and analysis tooling, not the app source. Its timestamp and export conventions are still useful design references.

## Data flow

1. iPhone samples `CMDeviceMotion` using `PhoneMotionRecorder`.
2. AirPods samples `CMHeadphoneMotionManager` using `AirPodsMotionRecorder`.
3. Apple Watch samples `CMDeviceMotion` in `WatchMotionStreamer` and sends payloads to the phone with `WatchConnectivity`.
4. `CaptureSessionStore` normalizes all samples into `MotionSample`.
5. `CaptureSessionStore` forwards enabled sources as UDP packets in the `mobile_6Dof` / `IMU_VIZ` wire format.
6. The app buffers and exports raw CSV for Python preprocessing, receiver replay, and MobilePoser feature conversion.

## MobilePoser mapping

The baseline profile is `MobilePoser lw_rp baseline`:

- Apple Watch: `leftWrist`
- iPhone: `rightPocket`
- AirPods: `head`, optional extra IMU not present in the original baseline

The exported CSV keeps every sample in long format. A Python preprocessing step should resample streams to a common frequency, interpolate by `host_time_s` or `receive_time_s`, and create the model tensors expected by MobilePoser. The app does not perform T-pose calibration, global alignment, device-to-bone mapping, or MobilePoser tensor generation.

## Research extension

For spine research, prioritize controlled labels before daily use:

- phone at `lumbar` or `sternum`
- AirPods at `head`
- watch at `leftWrist`
- labels from video, clinical posture scoring, or optical motion capture

For foot-loading research, consumer IMUs can estimate gait phase and foot contact timing, but plantar pressure needs labels from instrumented insoles or force plates. Treat phone/watch/AirPods as proxy sensors until labeled calibration data exists.

## Next engineering steps

1. Validate the live UDP stream against the real IMU_VIZ or mobile_6Dof receiver.
2. Add NTP or peer clock-offset estimation before serious multi-device experiments.
3. Add a Python converter from exported raw CSV to MobilePoser tensors.
4. Use labeled protocols to test phone pocket/lumbar orientation and watch wrist side mappings.
5. Convert trained MobilePoser modules to CoreML only if on-device inference becomes required.
