# MobilePoseLab -> MobilePoser Windows Handoff

本文档用于把当前 iOS / watchOS 数据采集项目交接到下一个对话，继续在 Windows 电脑上复现 MobilePoser，并把 MobilePoseLab 导出的 CSV 接入 MobilePoser 推理流程。

真实 receiver 联调请优先照着这个 runbook 做：

```text
PC_REAL_RECEIVER_RUNBOOK.md
```

## 当前项目位置

当前本地项目在 Mac 上：

```text
/Users/qinchenxin/Documents/New project/MobilePoseLab
```

这是一个自建的 iOS + watchOS 采集 app，不是原始 MobilePoser 仓库。

## 当前 App 已完成的功能

MobilePoseLab 现在可以采集三类日常 Apple 设备的 IMU 数据：

- iPhone：CoreMotion `CMDeviceMotion`
- Apple Watch：watchOS companion app 采集 `CMDeviceMotion`，通过 WatchConnectivity 传回 iPhone
- AirPods：`CMHeadphoneMotionManager`

实时/导出格式：

- UDP 实时流，默认发到电脑 `IP:8001`
- raw CSV，通过 iOS share sheet 导出

当前采样设计：

- 默认目标频率：30 Hz
- iPhone：按 profile targetHz 设置
- Watch：手机 start 命令会把 targetHz 发给 Watch
- AirPods：底层可能高于 30 Hz，但 app 端已做节流，导出接近 30 Hz

已加入的稳定性改动：

- Watch 低腕/暗屏时，启动 `WKExtendedRuntimeSession`，尽量保持采集继续运行
- Watch 实时连接可用时优先使用 `sendMessageData` 发送 JSON 编码的 `WatchIMUBatch`
- Watch 低腕或实时连接不可用时，回退到 `transferUserInfo` 后台排队传输，减少 drop
- Watch 界面显示 `Runtime active / idle`、`Sent`、`Buf`、`Drop`

当前采集流程：

- iOS 点击 `Start Upload`
- 0-3 秒：给用户放手机/戴设备
- 3-6 秒：站直不动，app 记录各设备 `gravity` 均值作为调试 baseline
- 6 秒后：正式 UDP 输出
- 上传和本地 CSV 录制现在是分离的：`Start Upload` 只发 UDP；`Start Local CSV Recording` 只本地保存；`Start Upload + CSV` 才会同时上传和录制
- app 端不做 T-pose、global alignment、device2bone 或 MobilePoser tensor

## 关键代码文件

数据模型：

```text
MobilePoseLab/MobilePoseLab/Models/MotionSample.swift
MobilePoseLab/MobilePoseLab/Models/CaptureProfile.swift
```

iOS 采集和会话：

```text
MobilePoseLab/MobilePoseLab/Session/CaptureSessionStore.swift
MobilePoseLab/MobilePoseLab/Sensors/PhoneMotionRecorder.swift
MobilePoseLab/MobilePoseLab/Sensors/AirPodsMotionRecorder.swift
MobilePoseLab/MobilePoseLab/Sensors/WatchConnectivityReceiver.swift
MobilePoseLab/MobilePoseLab/Views/CaptureDashboardView.swift
```

watchOS 采集：

```text
MobilePoseLab/WatchCompanion/WatchMotionStreamer.swift
MobilePoseLab/WatchCompanion/WatchCaptureView.swift
```

## 当前 UDP 格式

每帧一条 UTF-8 UDP 字符串：

```text
device_id;device_type:host_time device_time ax ay az qx qy qz qw [gx gy gz]
```

字段约定：

```text
device_type: phone / watch / headphone
host_time: iPhone 统一时间，秒
device_time: 设备自身时间，秒；iPhone/AirPods 当前等于 host_time，Watch 使用 watch sample timestamp
ax ay az: userAcceleration，m/s^2
qx qy qz qw: CoreMotion quaternion，xyzw 顺序
gx gy gz: rotationRate，rad/s；AirPods 不可用时可省略
```

## 官方 SPICExLAB receiver 注意事项

官方仓库里有两个容易混淆的 UDP 入口。

第一种是 `mobileposer/utils/sensor_utils.py` 的 iOS/mobile_6Dof 风格解析，它支持当前 app 的格式：

```text
device_id;device_type:host_time device_time ax ay az qx qy qz qw [gx gy gz]
```

但是它会按下面规则查设备：

```python
sensor.device_ids[f"{device_id.capitalize()}_{device_type}"]
```

所以 app 当前默认 ID 是：

```text
right;phone
left;watch
left;headphone
```

它们会对应到官方的：

```text
Right_phone
Left_watch
Left_headphone
```

不要在 stock SPICExLAB receiver 下使用 `iphone_001;phone` 这类 ID，除非你同步改了 PC 端 parser。

第二种是 stock `live_demo.py` 的老 Noitom 聚合输入，它不是上面的 packet，而是：

```text
acc0,acc1,...,acc14#qw0,qx0,qy0,qz0,...,qw4,qx4,qy4,qz4$
```

如果要直接跑 stock `live_demo.py`，先在 PC 上启动 adapter：

```bash
python3 Tools/mobileposer_live_demo_adapter.py --listen-port 8001 --output-port 7777
```

然后 app 仍然发到 PC 的 `8001`，adapter 会转成 `live_demo.py` 监听的 `7777` 聚合格式。

注意单位坑：app 输出加速度是 `m/s^2`，而 stock `live_demo.py` 会再乘 `-9.8`。adapter 默认 `--accel-mode g`，先把 `m/s^2` 转成 g-like 值。如果虚拟人方向明显反了，可以试：

```bash
python3 Tools/mobileposer_live_demo_adapter.py --accel-mode negative-g
```

## 当前导出 CSV 字段

CSV 是 long format，一行是一台设备的一帧 raw IMU。当前 raw schema 是：

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

`device_type` 可能是：

```text
phone
watch
headphone
```

`raw_extra_json` 当前包含 reference frame、capture phase、gravity calibration sample count 和站直 3 秒的 gravity baseline。它只用于后端调试，不表示 app 已经完成 body frame/global alignment。

当前建议的身体位置映射：

```text
Apple Watch -> left wrist, MobilePoser 中类似 lw
iPhone -> right pocket 或 lumbar, MobilePoser 中类似 rp
AirPods -> head
```

最优先尝试的 MobilePoser 设备组合：

```text
lw_rp_h
```

如果没有 AirPods：

```text
lw_rp
```

## 下一阶段目标

不要一上来训练模型。下一阶段先完成三件事：

1. 在 Windows 上跑通 MobilePoser 官方预训练 demo
2. 确认官方虚拟人显示和推理流程可运行
3. 写转换脚本，把 MobilePoseLab CSV 转成 MobilePoser 可用输入

## 是否需要仿真软件

目前不需要 Unity、Unreal Engine 或其他大型姿态仿真软件。

MobilePoser 的可视化不是必须依赖游戏引擎。它主要使用 Python 推理代码、SMPL 人体模型和 viewer/visualization 工具。

你需要的是：

- MobilePoser 代码
- Python 依赖
- 作者提供的预训练权重
- SMPL 人体模型文件

## Windows 电脑准备清单

优先使用 Windows，尤其是有 NVIDIA GPU 的机器。

需要准备：

- Windows 电脑
- Anaconda 或 Miniconda
- Git
- Python 3.9 conda 环境
- PyTorch
- 如果有 NVIDIA GPU，安装 CUDA 版本 PyTorch
- MobilePoser 仓库
- MobilePoser 预训练权重 `weights.pth`
- SMPL 模型文件 `basicmodel_m.pkl`

MacBook 继续负责：

- iOS / watchOS app 开发
- 数据采集
- CSV 导出
- 轻量数据检查

Windows 负责：

- MobilePoser 环境
- 预训练模型推理
- 可视化
- 后续可能的训练或 finetune

## MobilePoser 官方仓库

```text
https://github.com/SPICExLAB/MobilePoser
```

项目页：

```text
https://spice-lab.org/projects/MobilePoser/
```

## Windows 上的第一步命令草案

打开 Anaconda Prompt 或 PowerShell：

```bash
conda create -n mobileposer python=3.9
conda activate mobileposer
git clone https://github.com/SPICExLAB/MobilePoser.git
cd MobilePoser
```

然后安装依赖。具体 PyTorch 命令要根据 Windows 电脑是否有 NVIDIA GPU 决定。

有 NVIDIA GPU 时，先确认：

```bash
nvidia-smi
```

如果能看到显卡信息，再安装 CUDA 版 PyTorch。具体命令以后按当前 PyTorch 官网给出的版本来定。

之后再安装 MobilePoser 依赖：

```bash
pip install -r requirements.txt
pip install -e .
```

## 需要下载/放置的文件

MobilePoser 预训练权重：

```text
weights.pth
```

SMPL 男性模型：

```text
basicmodel_m.pkl
```

可能的目录结构示例：

```text
MobilePoser/
  checkpoints/
    weights.pth
  smpl/
    basicmodel_m.pkl
```

之后需要修改 MobilePoser 的 `config.py`，让它指向这些路径。

## 第一阶段验收标准

第一阶段只验收官方 MobilePoser 是否能跑，不使用自己的 CSV。

目标：

- 环境可以 import MobilePoser
- 可以加载 `weights.pth`
- 可以加载 SMPL 模型
- 可以运行官方 example
- 电脑上能看到官方虚拟人/姿态输出

这一步完成后，才进入自己的 CSV 转换。

## 第二阶段：接入 MobilePoseLab CSV

要写一个转换脚本，暂定文件名：

```text
convert_mobileposelab_to_mobileposer.py
```

转换流程：

1. 读取 MobilePoseLab 导出的 CSV
2. 先运行 `Tools/validate_stream_csv.py` 检查 raw schema、Hz、gap、quaternion norm
3. 按 `device_type/device_id` 分成 phone / watch / headphone
4. 使用 `host_time_s` 或 `receive_time_s` 建立共同时间轴
5. 重采样到 30 Hz
6. 处理缺失设备：
   - 没有 AirPods 时，用缺失 mask 或置零
   - Watch / iPhone 短暂缺失时，做插值或标记
7. 使用 `raw_extra_json.gravity_calibration_baseline_m_s2` 作为检查 Up 方向和静止质量的参考
8. 把设备映射到 MobilePoser 组合：
   - watch -> lw
   - phone -> rp 或 lumbar，需要实验确认
   - headphone -> h
9. 输出 MobilePoser 推理需要的 tensor / npz / pkl
10. 调用 MobilePoser 预训练模型做离线推理
11. 输出人体姿态结果和可视化

后端调试工具：

```text
Tools/run_local_smoke_tests.py
  一键生成临时 CSV，检查 schema、官方命名、CSV replay dry-run 和 live_demo adapter

Tools/validate_stream_csv.py
  检查 CSV schema、每路 Hz、gap、quaternion norm、gravity norm

Tools/check_spicexlab_sensor_utils.py
  直接调用本地 SPICExLAB/MobilePoser 仓库里的 sensor_utils.process_data，检查 packet/CSV 是否能被官方 parser 本体解析

Tools/replay_csv_udp.py
  把已导出的 CSV 重放成 app 实时发送时同样的 UDP packet

Tools/replay_csv_to_live_demo.py
  把已导出的 CSV 直接重放成 stock live_demo.py 的 acc#quat$ 聚合 UDP packet

Tools/udp_smoke_receiver.py
  轻量 UDP receiver，用来检查 packet 格式

Tools/mobileposer_live_demo_adapter.py
  把 app 的 iOS/mobile_6Dof UDP packet 转成 stock live_demo.py 的 acc#quat$ 聚合格式
```

## 第三阶段：研究方向

当前研究目标不是简单复刻 MobilePoser，而是借鉴其方法，用日常设备研究：

- 脊柱姿态
- 躯干弯曲/旋转
- 日常姿势模式
- 步态周期
- 足部受力 proxy

注意：仅靠 IMU 不能直接测真实足底压力。更稳妥的表述是：

```text
用日常 IMU 设备估计 gait phase、foot contact、impact、步态不对称，
并作为足部受力/足底压力的 proxy。
```

如果未来要做真实足底压力，需要额外标签设备，例如：

- 压力鞋垫
- 力板
- 带压力传感器的鞋垫原型

## 给下一个对话的开场提示

可以在新对话里直接贴下面这段：

```text
我现在要在 Windows 电脑上继续 MobilePoseLab -> MobilePoser 的工作。

Mac 上已经完成了 iOS/watchOS app，能采集 iPhone、Apple Watch、AirPods 的 raw IMU。app 点击 Start Upload 后会自动经历 3 秒放设备、3 秒站直 gravity baseline，然后输出 UDP；如果需要本地 CSV，要单独点 Start Local CSV Recording，或点 Start Upload + CSV。UDP 格式是 device_id;device_type:host_time device_time ax ay az qx qy qz qw [gx gy gz]，目标频率 30Hz。app 端不做 T-pose、global alignment、device2bone 或 MobilePoser tensor。

当前我要做下一步：在 Windows 上安装 SPICExLAB/MobilePoser，下载预训练权重和 SMPL 模型，先跑通官方 example / visualization，然后用 Tools/validate_stream_csv.py 检查 MobilePoseLab CSV，再写脚本把 CSV 转成 MobilePoser 输入。必要时可以用 Tools/replay_csv_udp.py 把 CSV 重放成 UDP 来调 receiver。

请先帮我检查 Windows 环境，包括 conda、Python、GPU、CUDA、PyTorch，然后一步步搭建 MobilePoser。
```

## 当前最重要的原则

不要先训练。

正确顺序是：

```text
官方预训练 demo 跑通
-> 官方可视化跑通
-> MobilePoseLab CSV 转换
-> 用自己的 CSV 做离线推理
-> 检查坐标系/时间同步/placement
-> 再考虑 finetune 或重新训练
```
