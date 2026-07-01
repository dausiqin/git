# MobilePoseLab Backend Data Handoff

本文档用于交接给 Windows / Python / MobilePoser 端的数据分析工程师。当前 iOS + watchOS app 的目标是采集日常设备 IMU，并把数据接入 SPICExLAB/MobilePoser 类似的离线推理流程。

## 当前 App 位置

本地项目：

```text
/Users/qinchenxin/Documents/New project/MobilePoseLab
```

Xcode scheme：

```text
MobilePoseLab
```

包含：

```text
iOS app: MobilePoseLab
watchOS companion app: MobilePoseLabWatch
```

## 代码模块对应关系

当前是在既有 `MobilePoseLab` 工程上实现 streamer，不是另起一个 `MobilePoseLabStreamer` 目录。核心类和文件对应如下：

```text
UDPSender / PacketFormatter
  /Users/qinchenxin/Documents/New project/MobilePoseLab/MobilePoseLab/Session/CaptureSessionStore.swift

PhoneMotionManager
  /Users/qinchenxin/Documents/New project/MobilePoseLab/MobilePoseLab/Sensors/PhoneMotionRecorder.swift

HeadphoneMotionManager
  /Users/qinchenxin/Documents/New project/MobilePoseLab/MobilePoseLab/Sensors/AirPodsMotionRecorder.swift

WatchSessionManager
  /Users/qinchenxin/Documents/New project/MobilePoseLab/MobilePoseLab/Sensors/WatchConnectivityReceiver.swift

CSVLogger / session state
  /Users/qinchenxin/Documents/New project/MobilePoseLab/MobilePoseLab/Session/CaptureSessionStore.swift

MainView
  /Users/qinchenxin/Documents/New project/MobilePoseLab/MobilePoseLab/Views/CaptureDashboardView.swift

WatchMotionManager / WatchWorkoutManager / WatchConnectivitySender
  /Users/qinchenxin/Documents/New project/MobilePoseLab/WatchCompanion/WatchMotionStreamer.swift

WatchMainView
  /Users/qinchenxin/Documents/New project/MobilePoseLab/WatchCompanion/WatchCaptureView.swift

UDP smoke receiver
  /Users/qinchenxin/Documents/New project/MobilePoseLab/Tools/udp_smoke_receiver.py

CSV validator
  /Users/qinchenxin/Documents/New project/MobilePoseLab/Tools/validate_stream_csv.py

CSV UDP replay
  /Users/qinchenxin/Documents/New project/MobilePoseLab/Tools/replay_csv_udp.py
```

## 采集流程

用户点击 iOS app 里的 `Start Upload` 后，app 不会立刻正式输出运动数据，而是自动走一个准备流程：

```text
0-3 s: Place devices
      给用户把手机放进口袋、戴好设备的时间

3-6 s: Stand still calibration
      用户站直不动
      app 采集每个设备这 3 秒内的 gravity 向量均值，作为该设备本次 session 的重力基线

6 s 后: Streaming
      开始正式 UDP 输出
```

也就是说，UDP 的正式数据默认已经去掉了开头放手机和站直校准的 6 秒准备段。上传和本地 CSV 录制现在是分离的：`Start Upload` 只发 UDP，不自动保存 CSV；`Start Local CSV Recording` 只保存本地 CSV；`Start Upload + CSV` 才会同时上传和本地记录。

## 频率

当前目标频率：

```text
30 Hz
```

这是为了先贴近 MobilePoser 的常见 30 FPS / 30 Hz 处理流程。真实设备频率可能略有波动，尤其 Apple Watch 和 AirPods 需要在后端按时间戳重采样。

后端不要假设三路数据天然逐行对齐。应该用 `host_time_s` / `receive_time_s` 作为主时间轴，把不同设备重采样到统一 30 Hz timeline。

iPhone 和 AirPods 的 CoreMotion delivery queue 已经放到后台 `OperationQueue`，避免采样回调直接占用 UI 主线程。Apple Watch 端也使用独立 motion queue，再通过 WatchConnectivity 批量传回 iPhone。

UI 里的 packet count、Hz、drop estimate、last packet age 等状态按约 0.5 秒节流刷新。UDP 发送仍然是每帧发送；UI 数字不是逐帧实时递增。

Apple Watch 实时通道优先使用 `WCSession.sendMessageData` 发送 JSON 编码的 `WatchIMUBatch`，iPhone 端通过 `didReceiveMessageData` 解码后立即转发 UDP。若 data channel 失败，Watch 会回退到旧的 `sendMessage` / `transferUserInfo` 路径。Watch UI 会明确显示 `Phone reachable` / `Phone not reachable`、workout 状态、motion Hz 和 last send age。

iOS 端 Diagnostics 会显示 UDP packets、CSV rows、AirPods motion availability、AirPods connected、AirPods motion authorization、WatchConnectivity supported/reachable，以及 Watch 最新接收延迟。

## UDP 格式

iOS app 会向指定电脑 IP 和端口发送 UDP packet。

默认端口：

```text
8001
```

单条 UDP packet 格式：

```text
device_id;device_type:host_time device_time ax ay az qx qy qz qw [gx gy gz]
```

示例：

```text
left;watch:12345.123456 1790000000.123456 0.120000 -0.030000 0.450000 0.010000 0.020000 0.030000 0.999000 0.001000 -0.002000 0.003000
```

字段含义：

```text
device_id       用户在 app 里设置的设备 ID；官方 SPICExLAB receiver 建议使用 right / left
device_type     phone / watch / headphone
host_time       iPhone 接收或生成该 sample 时的 ProcessInfo.systemUptime，单位秒
device_time     设备自身 sample timestamp，单位秒；iPhone / AirPods 当前与 host_time 相同，Watch 使用 Watch 端 sample timestamp
ax ay az        userAcceleration，单位 m/s^2
qx qy qz qw     CoreMotion quaternion，顺序为 xyzw
gx gy gz        rotationRate，单位 rad/s；如果不可用可能缺省
```

注意：UDP packet 发送 raw IMU，不把 gravity calibration 后的字段塞进实时 packet。

## UDP Smoke Test

在接入完整 IMU_VIZ / mobile_6Dof 前，可以先用仓库里的轻量 receiver 检查 UDP 字符串格式：

```text
python3 Tools/udp_smoke_receiver.py --port 8001
```

然后在 iPhone app 里把 Computer IP 设置成运行该脚本的电脑局域网 IP，端口保持 `8001`，点击 `Start Upload`。脚本会检查：

```text
device_id;device_type:host_time device_time ax ay az qx qy qz qw [gx gy gz]
```

并输出每个 source 的 count、Hz、age 和 parse error 数。这个脚本只验证线缆格式和基础数值范围，不执行 MobilePoser/global alignment/T-pose。

## CSV Validation

拿到 iOS app 导出的 CSV 后，后端第一步建议运行：

```text
python3 Tools/validate_stream_csv.py path/to/mobile_pose_lab_xxx.csv --target-hz 30
```

如果本次实验要求三台设备都必须出现，可以加：

```text
python3 Tools/validate_stream_csv.py path/to/mobile_pose_lab_xxx.csv --target-hz 30 --require phone,watch,headphone
```

这个脚本会检查：

```text
CSV 列名是否严格匹配 raw schema
每个 device_type/device_id 的 count、duration、Hz
按 host_time_s 估计的大 gap 数量和最大 gap
quaternion norm 中位数
acceleration / gravity norm 中位数
phone/watch 是否都有 gyro_available=1
raw_extra_json 是否可解析
gravity_calibration_baseline_m_s2 是否存在
```

## SPICExLAB/MobilePoser official receiver naming

如果后端直接使用 SPICExLAB/MobilePoser 官方 `mobileposer/utils/sensor_utils.py` 里的 `process_data()`，注意它会这样找设备：

```python
device_name = sensor.device_ids[f"{device_id.capitalize()}_{device_type}"]
```

因此官方 receiver 不是用 `iphone_001;phone` 这种默认示例 ID，而是更适合：

```text
right;phone:...
left;watch:...
left;headphone:...
```

当前 app 默认已经改成：

```text
phone device_id: right
watch device_id: left
AirPods/headphone device_id: left
```

如果你接的是自己的泛化 UDP receiver，可以继续在 app UI 里改成 `iphone_001` / `watch_001` / `airpods_001`。但跑官方 SPICExLAB/MobilePoser receiver 时，建议保持 `right` / `left` 这类 side ID，否则官方 `sensor.device_ids` lookup 很可能失败。

另一个重要差异：官方 `live_demo.py` 里旧的 Noitom 直连 UDP 格式是：

```text
acc_values#quat_values$
```

而当前 app 输出的是 `sensor_utils.process_data()` 支持的 iOS/mobile_6Dof 风格：

```text
device_id;device_type:host_time device_time ax ay az qx qy qz qw [gx gy gz]
```

所以不要把 app 直接接到未改造的 `live_demo.py` Noitom socket 上；应该先走官方 calibration/receiver 解析路径，或在 PC 端写 adapter 把 iOS packet 转成 `live_demo.py` 的 `acc#quat$` 聚合格式。

可用这个工具先检查命名是否会被官方 `process_data()` 接受：

```bash
python3 Tools/check_mobileposer_packet_compat.py "right;phone:1000 1000 0.1 0.2 0.3 0 0 0 1 0.01 0.02 0.03"
python3 Tools/check_mobileposer_packet_compat.py /path/to/mobile_pose_lab.csv
```

它只做数据质量验收，不会做重采样、坐标对齐、T-pose、global alignment 或 MobilePoser 推理。

如果后端工程师要直接跑 stock `live_demo.py` 的老 UDP 输入，可以先在 PC 上开 adapter：

```bash
python3 Tools/mobileposer_live_demo_adapter.py --listen-port 8001 --output-port 7777
```

然后让 app 或 CSV replay 继续发到 PC 的 `8001`。adapter 会输出 `live_demo.py` 需要的：

```text
acc0,acc1,...,acc14#qw0,qx0,qy0,qz0,...,qw4,qx4,qy4,qz4$
```

注意：app 发出的加速度是 `m/s^2`，但 stock `live_demo.py` 会对收到的 acc 再乘 `-9.8`。adapter 默认用 `--accel-mode g` 把 `m/s^2` 转成 g-like 值；如果真实显示方向反了或位移尺度异常，可以试：

```bash
python3 Tools/mobileposer_live_demo_adapter.py --accel-mode negative-g
```

长期更干净的方式是修改 PC receiver，让它明确消费 `m/s^2`，不要再隐式乘 `-9.8`。

## CSV UDP Replay

如果后端工程师想在没有 iPhone / Watch / AirPods 真机的情况下调试 `IMU_receiver.py` 或 IMU_VIZ receiver，可以把已导出的 CSV 重放成同样的 UDP packet：

```text
python3 Tools/replay_csv_udp.py path/to/mobile_pose_lab_xxx.csv --host 192.168.1.100 --port 8001
```

常用选项：

```text
--speed 10
  以 10 倍速度重放，适合快速检查 receiver 是否能解析

--device-types phone,watch
  只重放某些 device_type

--device-ids right,left
  只重放某些 device_id

--dry-run
  只打印 UDP 字符串，不真正发送
```

这个工具从 CSV 的 raw 字段重新拼出：

```text
device_id;device_type:host_time device_time ax ay az qx qy qz qw [gx gy gz]
```

它不做重采样、坐标对齐、T-pose、global alignment 或 MobilePoser tensor 转换，只用于后端 receiver / parser 联调。

## CSV 格式

iOS app 导出的 CSV 是 long format，不是宽表。每一行是一台设备的一帧 IMU。

CSV 主表严格保持 raw schema，不保存 gravity-aligned acceleration、body frame、device2bone、T-pose 或 MobilePoser tensor。3 秒静止窗口只用于采集流程提示和 `raw_extra_json` 里的调试元信息。

主要字段：

```text
session_id
source
device_type
device_id
placement
packet_seq
host_time_s
device_time_s
receive_time_s
ax_m_s2
ay_m_s2
az_m_s2
gx_rad_s
gy_rad_s
gz_rad_s
gyro_available
quat_x
quat_y
quat_z
quat_w
gravity_x_m_s2
gravity_y_m_s2
gravity_z_m_s2
user_accel_x_m_s2
user_accel_y_m_s2
user_accel_z_m_s2
raw_extra_json
```

## Raw 字段

Raw 字段：

```text
ax_m_s2 / ay_m_s2 / az_m_s2
user_accel_x_m_s2 / user_accel_y_m_s2 / user_accel_z_m_s2
gx_rad_s / gy_rad_s / gz_rad_s
quat_x / quat_y / quat_z / quat_w
gravity_x_m_s2 / gravity_y_m_s2 / gravity_z_m_s2
```

这些字段直接来自 CoreMotion 的 device motion 数据，只做了单位换算：

```text
CoreMotion userAcceleration: g -> m/s^2, multiply by 9.80665
CoreMotion gravity: g -> m/s^2, multiply by 9.80665
rotationRate: rad/s, 不换算
quaternion: xyzw, 不换算
```

`raw_extra_json` 当前包含：

```text
reference_frame
capture_phase
gravity_calibration_samples
gravity_calibration_baseline_m_s2
gravity_calibration_norm_m_s2
```

其中 `gravity_calibration_baseline_m_s2` 是该 source 在 `Stand still calibration` 阶段的 CoreMotion gravity 均值，格式类似：

```json
{"x":0.123456,"y":-9.765432,"z":0.456789}
```

这个值可以作为后端计算 Up 方向、检查设备是否静止、检查坐标系是否合理的参考。它不是 body frame、不是 global alignment，也不是 MobilePoser 的 device-to-bone calibration。

重要：CSV 不含 gravity-aligned 字段。后端如果要做 Up/Forward/Left、body frame、device-to-bone、T-pose 或 MobilePoser tensor 映射，应在电脑端完成。

## 后端建议读取方式

第一阶段优先使用 raw 字段做转换，因为 MobilePoser 官方流程通常假设输入端会有自己的坐标/骨骼映射逻辑。不要期待 app 端已经完成坐标对齐。

## 对齐流程建议

Python 端建议：

```text
1. 读取 CSV long format
2. 按 source/device_id 分组
3. 检查每组 host_time_s 的 duration、平均 Hz、gap
4. 用 host_time_s 或 receive_time_s 建立统一时间轴
5. 重采样到 30 Hz
6. 对每个目标时间点插值：
   - acceleration: linear interpolation
   - gyro: linear interpolation
   - quaternion: slerp，至少先 normalize
7. 根据 placement 映射设备：
   - watch/rightWrist 或 leftWrist
   - phone/rightPocket 或 leftPocket
   - headphone/head
8. 再转换到 MobilePoser 需要的 IMU tensor
```

不要按 CSV 行号对齐三台设备。Apple Watch 通过 WatchConnectivity 传输，天然会有批量到达和延迟；正确做法是按时间戳对齐。

## 目前最需要后端验证的点

1. `userAcceleration` 单位是否已经正确转为 `m/s^2`
2. MobilePoser 转换脚本中是否还错误地把加速度除以 30
3. 模型期望的 acceleration 是否需要 `* 9.80665` 或 `- * 9.80665`
4. quaternion 顺序是否被错误读成 `wxyz`
5. Watch / Phone / AirPods 是否被映射到了正确 placement
6. 重采样后每台设备是否都是稳定 30 Hz
7. 脚接触概率是否开始出现左右交替，而不是长期双脚高接触

## 一句话交接

MobilePoseLab 现在输出的是三设备 raw IMU；后端应先按 `host_time_s` 重采样到 30 Hz，再在电脑端做 MobilePoser 的设备坐标、global alignment、T-pose 和 body frame 映射。
