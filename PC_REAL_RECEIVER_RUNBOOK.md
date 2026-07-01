# PC real receiver runbook

This runbook is for the Windows/backend engineer who will verify MobilePoseLab against a real SPICExLAB/MobilePoser, mobile_6Dof, or IMU_VIZ receiver.

## Goal

Prove the real backend can receive MobilePoseLab packets from iPhone, Apple Watch, and AirPods, not only the local smoke tools.

The full thread goal is not complete until one of these is observed:

- IMU_VIZ receives live MobilePoseLab UDP data and shows the devices.
- SPICExLAB/MobilePoser or mobile_6Dof receiver parses `phone`, `watch`, and `headphone`.
- Stock `live_demo.py` receives adapter output and proceeds through calibration / visualization.

## Files to copy to PC

Copy the whole project folder if possible:

```text
/Users/qinchenxin/Documents/New project/MobilePoseLab
```

At minimum copy:

```text
Tools/
HANDOFF_INDEX.md
README.md
BACKEND_DATA_HANDOFF.md
WINDOWS_MOBILEPOSER_HANDOFF.md
GRAVITY_CALIBRATION_BACKEND_HANDOFF.md
GOAL_COMPLETION_AUDIT.md
```

## Step 1: verify tools on PC

From the copied project folder:

```bash
python Tools/run_local_smoke_tests.py
```

Expected:

```text
PASS: local MobilePoseLab smoke tests completed.
```

This does not need iPhone hardware. It confirms:

- Python tools run on this PC.
- Current CSV schema is understood.
- Official MobilePoser side IDs are accepted.
- CSV replay can reconstruct UDP packets.
- The stock `live_demo.py` adapter can emit `acc#quat$` aggregate frames.

If this fails, fix the PC Python environment before trying live iPhone streaming.

## Step 2: choose backend route

There are two different receiver routes. Do not mix them.

### Route A: iOS/mobile_6Dof parser route

Use this route if the backend has a parser similar to:

```text
device_id;device_type:host_time device_time ax ay az qx qy qz qw [gx gy gz]
```

Expected app defaults:

```text
right;phone
left;watch
left;headphone
```

For stock SPICExLAB `sensor_utils.process_data()`, these become:

```text
Right_phone
Left_watch
Left_headphone
```

Run the real receiver on PC, usually listening on UDP `8001`. Then set the iPhone app:

```text
Computer IP = PC LAN IP
UDP Port = 8001
```

Tap `Start Upload` on iPhone. Wait for:

```text
3 s placement
3 s stand-still gravity baseline
Streaming
```

Success criteria:

- PC receiver logs packets from `phone/right`, `watch/left`, and optionally `headphone/left`.
- No `KeyError` for device IDs.
- Quaternion norms are near 1.
- Acceleration values are m/s^2.
- Backend can continue to global alignment / T-pose calibration.

### Route B: stock live_demo.py route

Use this route only for the older `live_demo.py` socket that expects:

```text
acc0,acc1,...,acc14#qw0,qx0,qy0,qz0,...,qw4,qx4,qy4,qz4$
```

Start the adapter first:

```bash
python Tools/mobileposer_live_demo_adapter.py --listen-port 8001 --output-host 127.0.0.1 --output-port 7777
```

Then start stock `live_demo.py` so it reads UDP `7777`.

Set iPhone app:

```text
Computer IP = PC LAN IP
UDP Port = 8001
```

Success criteria:

- Adapter prints increasing `received=` and `forwarded=`.
- `active_slots` includes:

```text
1: left watch
2: left headphone, if AirPods are connected
3: right phone
```

- `live_demo.py` proceeds past its UDP read stage.

If the body direction or translation scale is clearly wrong, try:

```bash
python Tools/mobileposer_live_demo_adapter.py --accel-mode negative-g
```

Long-term cleaner option: patch the PC receiver to consume `m/s^2` directly and remove hidden `-9.8` multiplication.

## Step 3: replay CSV before live app if needed

If live iPhone streaming is inconvenient, first replay a current-schema CSV:

```bash
python Tools/validate_stream_csv.py path/to/mobile_pose_lab.csv --target-hz 30 --require phone,watch
python Tools/check_mobileposer_packet_compat.py path/to/mobile_pose_lab.csv
python Tools/check_spicexlab_sensor_utils.py path/to/MobilePoser path/to/mobile_pose_lab.csv
python Tools/replay_csv_udp.py path/to/mobile_pose_lab.csv --host 127.0.0.1 --port 8001
```

For Route B, keep the adapter running and send replay to adapter port `8001`.

For Route A, send replay directly to the real receiver port.

For stock `live_demo.py`, you can skip the adapter and replay CSV directly as aggregate `acc#quat$` packets:

```bash
python Tools/replay_csv_to_live_demo.py path/to/mobile_pose_lab.csv --host 127.0.0.1 --port 7777
```

Use `--dry-run` first if you want to inspect the aggregate packet text before sending.

## Step 4: firewall and port checks

On Windows, allow Python through Windows Defender Firewall for private networks.

If the iPhone app shows packets sent but PC sees nothing:

1. Confirm Mac/iPhone and PC are on the same Wi-Fi or hotspot.
2. Confirm iPhone app `Computer IP` is the PC LAN IPv4 address.
3. Confirm UDP port is `8001`.
4. Temporarily run:

```bash
python Tools/udp_smoke_receiver.py --host 0.0.0.0 --port 8001
```

5. Start iPhone streaming again and look for `phone/right`, `watch/left`, `headphone/left`.

## Step 5: what to report back

Report these exact observations:

```text
Route used: A iOS/mobile_6Dof parser OR B stock live_demo adapter
PC OS:
Python version:
Receiver command:
App target IP/port:
Devices enabled:
Observed device IDs:
Observed Hz per device:
Any parser errors:
Any calibration errors:
Whether visualization moved:
Whether direction/scale looked wrong:
```

If there is a failure, include the first 20 lines of receiver output and one raw UDP packet sample.

## Known caveats

- App output acceleration is `m/s^2`.
- Stock `live_demo.py` historically multiplies received acceleration by `-9.8`.
- App output quaternion is xyzw.
- Stock `live_demo.py` aggregate adapter outputs quaternion as wxyz because the old socket expects that order.
- Cross-device alignment should use `host_time_s`.
- `device_time_s` is diagnostic and may not share the same absolute clock as iPhone `host_time_s`.
- The 3 s gravity baseline is metadata for backend alignment, not a completed body/global calibration.
