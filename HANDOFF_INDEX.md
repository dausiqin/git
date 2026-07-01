# MobilePoseLab handoff index

Use this as the first page when continuing the project in another Codex thread or on the Windows backend computer.

## Current project

Local Mac path:

```text
/Users/qinchenxin/Documents/New project/MobilePoseLab
```

Xcode project:

```text
MobilePoseLab.xcodeproj
```

Main scheme:

```text
MobilePoseLab
```

The app is an iOS + watchOS IMU collection frontend for MobilePoser / mobile_6Dof / IMU_VIZ style experiments.

## Read in this order

1. `README.md`
   - Project overview, Xcode build command, Apple Watch install flow, backend tools.

2. `PC_REAL_RECEIVER_RUNBOOK.md`
   - Step-by-step Windows/PC procedure for proving the real backend receives data.
   - This is the most important next document.

3. `WINDOWS_MOBILEPOSER_HANDOFF.md`
   - Longer Windows-side handoff for MobilePoser setup and CSV conversion work.

4. `BACKEND_DATA_HANDOFF.md`
   - Exact UDP packet format, CSV schema, receiver naming rules, replay tools.

5. `GRAVITY_CALIBRATION_BACKEND_HANDOFF.md`
   - What the 3-second stand-still gravity baseline means and how backend should use it.

6. `GOAL_COMPLETION_AUDIT.md`
   - Requirement-by-requirement status and remaining proof needed before the full goal is complete.

## One-command local verification

Run this on Mac or PC after copying the project:

```bash
python Tools/run_local_smoke_tests.py
```

Expected:

```text
PASS: local MobilePoseLab smoke tests completed.
```

This checks the Python toolchain, current CSV schema, official MobilePoser side-ID naming, CSV-to-UDP replay, direct CSV-to-`live_demo.py` replay, and the live adapter path.

## Current UDP defaults

For stock SPICExLAB/MobilePoser receiver compatibility, the app defaults to:

```text
right;phone
left;watch
left;headphone
```

Those map to the official receiver keys:

```text
Right_phone
Left_watch
Left_headphone
```

The packet shape is:

```text
device_id;device_type:host_time device_time ax ay az qx qy qz qw [gx gy gz]
```

Units:

```text
acceleration: m/s^2
gyro: rad/s
quaternion: xyzw
```

## Current app recording flow

When the user taps `Start Upload`:

```text
0-3 s: place phone / prepare devices
3-6 s: stand still for gravity baseline
6 s+: stream UDP
```

Local CSV recording is separate. Use `Start Local CSV Recording` for local-only data, or `Start Upload + CSV` when both UDP upload and local CSV are needed.

The app does not do T-pose, global alignment, device2bone, SMPL, or MobilePoser tensor generation.

## Backend routes

Route A: iOS/mobile_6Dof parser

```text
App -> UDP 8001 -> real receiver parsing device_id;device_type:...
```

Route B: stock `live_demo.py`

```text
App -> UDP 8001 -> Tools/mobileposer_live_demo_adapter.py -> UDP 7777 -> live_demo.py
```

Offline stock `live_demo.py` test from CSV:

```bash
python Tools/replay_csv_to_live_demo.py path/to/mobile_pose_lab.csv --host 127.0.0.1 --port 7777
```

## Completion status

Frontend implementation and local tooling are substantially complete and verified locally.

The full thread goal is still open until a real Windows/PC backend proves one of these:

- IMU_VIZ shows live MobilePoseLab device data.
- mobile_6Dof / SPICExLAB receiver parses phone/watch/headphone packets.
- stock `live_demo.py` receives adapter output and proceeds through calibration / visualization.
