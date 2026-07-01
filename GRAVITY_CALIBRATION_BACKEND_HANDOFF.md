# MobilePoseLab gravity calibration handoff

This note is for the Windows/backend engineer who will convert MobilePoseLab iPhone, Apple Watch, and AirPods IMU data into MobilePoser/mobile_6Dof inputs.

## Current app behavior

The iOS app now has a lightweight gravity calibration stage before real recording starts.

When the user taps Start Upload:

1. 0-3 s: placement delay. The user can put the phone into the pocket and prepare the devices.
2. 3-6 s: stand-still gravity calibration. The user should stand upright and keep devices still.
3. After 6 s: real UDP streaming begins. Local CSV writing begins only if the user also started local CSV recording or used `Start Upload + CSV`.

Important: the app does not perform full global alignment, body-frame conversion, T-pose calibration, device2bone calibration, or MobilePoser tensor generation. The 3-second calibration only records per-device gravity baselines as metadata for backend processing and quality checks.

## UDP output

UDP packets keep the mobile_6Dof / IMU_VIZ-compatible format:

```text
device_id;device_type:host_time device_time ax ay az qx qy qz qw [gx gy gz]
```

Fields:

- `device_id`: official SPICExLAB/MobilePoser receiver naming works best with side IDs such as `right` for phone and `left` for watch/headphone; custom receivers can use descriptive IDs such as `iphone_001`
- `device_type`: `phone`, `watch`, or `headphone`
- `host_time`: iPhone-side unified timestamp in seconds
- `device_time`: source device timestamp in seconds
- `ax ay az`: CoreMotion user acceleration, converted to `m/s^2`
- `qx qy qz qw`: CoreMotion quaternion in xyzw order
- `gx gy gz`: gyro rotation rate in `rad/s`, included when available

UDP does not include the gravity calibration baseline. Use the CSV for calibration metadata.

For the stock SPICExLAB/MobilePoser `sensor_utils.process_data()` path, keep the app defaults:

```text
right;phone:...
left;watch:...
left;headphone:...
```

Those become `Right_phone`, `Left_watch`, and `Left_headphone` inside the official `sensor.device_ids` lookup. Descriptive IDs such as `iphone_001` are fine only if the backend parser accepts them.

## CSV output

The CSV header is:

```text
session_id,source,device_type,device_id,placement,packet_seq,host_time_s,device_time_s,receive_time_s,ax_m_s2,ay_m_s2,az_m_s2,gx_rad_s,gy_rad_s,gz_rad_s,gyro_available,quat_x,quat_y,quat_z,quat_w,gravity_x_m_s2,gravity_y_m_s2,gravity_z_m_s2,user_accel_x_m_s2,user_accel_y_m_s2,user_accel_z_m_s2,raw_extra_json
```

Key columns:

- `host_time_s`: unified iPhone timeline. Use this for cross-device alignment.
- `device_time_s`: source device time. Useful for drift checks, especially Apple Watch.
- `receive_time_s`: when the iPhone received or accepted the sample.
- `ax_m_s2, ay_m_s2, az_m_s2`: user acceleration in `m/s^2`.
- `gravity_x_m_s2, gravity_y_m_s2, gravity_z_m_s2`: CoreMotion gravity vector in `m/s^2`.
- `quat_x, quat_y, quat_z, quat_w`: quaternion in xyzw order.
- `raw_extra_json`: JSON metadata string.

`raw_extra_json` contains:

```json
{
  "reference_frame": "xArbitraryCorrectedZVertical",
  "capture_phase": "recording",
  "gravity_calibration_samples": 90,
  "gravity_calibration_baseline_m_s2": {
    "x": 0.123456,
    "y": -9.801234,
    "z": 0.234567
  },
  "gravity_calibration_norm_m_s2": 9.807654
}
```

For AirPods, `reference_frame` may be `headphoneDeviceMotion`.

## How backend should use gravity calibration

Recommended use:

1. Parse `raw_extra_json.gravity_calibration_baseline_m_s2` per `session_id + device_type + device_id`.
2. Check that `gravity_calibration_norm_m_s2` is close to `9.81`. A rough acceptable range is about `9.3-10.3 m/s^2`; outside that range means the device was probably moving or the capture was bad.
3. Use the baseline as the device-local Up/Down reference for backend coordinate alignment.
4. Resample all selected devices onto a shared 30 Hz timeline using `host_time_s`.
5. Keep phone/watch/headphone axes raw until backend alignment. Do not assume the app already converted them to `x=Left, y=Up, z=Forward`.

Do not treat the app CSV as already body-aligned. The app is intentionally only doing lightweight baseline capture.

## Important conversion notes

- CoreMotion `userAcceleration` is originally in `g`; the app exports it as `m/s^2`.
- CoreMotion `gravity` is originally in `g`; the app exports it as `m/s^2`.
- Gyro is already `rad/s`.
- Quaternion order is xyzw, not wxyz.
- MobilePoser-style preprocessing should still test whether acceleration sign or axis mapping needs to match the official code path.
- The app default capture profile is 30 Hz because MobilePoser data is typically consumed on a 30 Hz timeline.

## Suggested backend validation

Before running MobilePoser inference:

1. Validate each source's duration and Hz.
2. Plot `host_time_s` per source and confirm overlapping intervals.
3. Plot acceleration norm and gravity norm.
4. Confirm quaternion norm is near 1.
5. Confirm `gravity_calibration_samples` is nonzero for every source used in the model.
6. Trim to the shared time interval across required devices.
7. Resample/interpolate to 30 Hz.
8. Apply backend coordinate alignment using gravity baseline plus placement assumptions.

## Useful local tools

From the Mac project:

```bash
cd "/Users/qinchenxin/Documents/New project/MobilePoseLab"
python3 Tools/validate_stream_csv.py /path/to/mobile_pose_lab.csv --target-hz 30
python3 Tools/udp_smoke_receiver.py --port 8001
python3 Tools/replay_csv_udp.py /path/to/mobile_pose_lab.csv --host <PC_IP> --port 8001
```

The CSV validator checks schema, per-source Hz, gaps, quaternion norms, gravity norms, gyro availability, and whether `raw_extra_json` is parseable.

## One-sentence summary

MobilePoseLab now records raw iPhone, Apple Watch, and AirPods IMU on a unified iPhone timeline, starts real output only after 3 s placement plus 3 s stand-still gravity baseline, exports acceleration/gravity in `m/s^2`, quaternion as xyzw, gyro as `rad/s`, and provides gravity baseline metadata in CSV for backend alignment while leaving full body/global calibration to the PC pipeline.
