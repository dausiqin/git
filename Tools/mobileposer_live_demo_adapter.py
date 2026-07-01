#!/usr/bin/env python3
"""Bridge MobilePoseLab iOS UDP packets to SPICExLAB/MobilePoser live_demo.py.

MobilePoseLab emits one packet per source:

    device_id;device_type:host_time device_time ax ay az qx qy qz qw [gx gy gz]

The stock SPICExLAB/MobilePoser `live_demo.py` reads an older aggregate packet:

    acc0,acc1,...,acc14#qw0,qx0,qy0,qz0,...,qw4,qx4,qy4,qz4$

This adapter listens for MobilePoseLab packets, fills the 5 official MobilePoser
sensor slots, and forwards aggregate frames to `live_demo.py`'s UDP input port.

Official slot order from `mobileposer.config.sensor.device_ids`:

    0 Left_phone
    1 Left_watch
    2 Left_headphone
    3 Right_phone
    4 Right_watch

Important acceleration note:

MobilePoseLab packets use m/s^2. The stock `live_demo.py` path multiplies its
received acceleration by `-9.8`, so this adapter defaults to forwarding
g-like acceleration (`m/s^2 / 9.80665`). If the reconstructed motion is inverted
or too small/large, try `--accel-mode negative-g` or patch the PC receiver to
consume m/s^2 directly.
"""

from __future__ import annotations

import argparse
import math
import socket
import sys
import time
from dataclasses import dataclass, field


G = 9.80665
VALID_DEVICE_TYPES = {"phone", "watch", "headphone"}
OFFICIAL_SLOTS = {
    ("left", "phone"): 0,
    ("left", "watch"): 1,
    ("left", "headphone"): 2,
    ("right", "phone"): 3,
    ("right", "watch"): 4,
}


@dataclass
class SlotState:
    acc_m_s2: tuple[float, float, float] = (0.0, 0.0, 0.0)
    quat_xyzw: tuple[float, float, float, float] = (0.0, 0.0, 0.0, 1.0)
    last_host_time: float = 0.0
    count: int = 0


@dataclass
class AdapterState:
    slots: list[SlotState] = field(default_factory=lambda: [SlotState() for _ in range(5)])
    received: int = 0
    forwarded: int = 0
    errors: int = 0


def parse_packet(text: str) -> tuple[str, str, list[float]]:
    if ";" not in text or ":" not in text:
        raise ValueError("packet must contain ';' and ':'")

    device_id, rest = text.strip().split(";", 1)
    device_type, values_text = rest.split(":", 1)
    device_id = device_id.strip().lower()
    device_type = device_type.strip().lower()

    if device_type not in VALID_DEVICE_TYPES:
        raise ValueError(f"invalid device_type {device_type!r}")

    values = [float(part) for part in values_text.split()]
    if len(values) not in (9, 12):
        raise ValueError(f"expected 9 or 12 values, got {len(values)}")

    quat = values[5:9]
    quat_norm = math.sqrt(sum(value * value for value in quat))
    if not 0.5 <= quat_norm <= 1.5:
        raise ValueError(f"unexpected quaternion norm {quat_norm:.3f}")

    return device_id, device_type, values


def slot_for(device_id: str, device_type: str) -> int:
    key = (device_id, device_type)
    if key not in OFFICIAL_SLOTS:
        raise ValueError(
            f"{device_id};{device_type} is not an official MobilePoser slot. "
            "Use left/right device IDs for the stock receiver."
        )
    return OFFICIAL_SLOTS[key]


def convert_acc(value: float, accel_mode: str) -> float:
    if accel_mode == "g":
        return value / G
    if accel_mode == "negative-g":
        return -value / G
    if accel_mode == "m_s2":
        return value
    raise ValueError(f"unknown accel mode {accel_mode}")


def aggregate_packet(state: AdapterState, accel_mode: str) -> str:
    acc_values: list[float] = []
    quat_values: list[float] = []

    for slot in state.slots:
        acc_values.extend(convert_acc(value, accel_mode) for value in slot.acc_m_s2)
        x, y, z, w = slot.quat_xyzw
        quat_values.extend([w, x, y, z])

    acc_text = ",".join(f"{value:g}" for value in acc_values)
    quat_text = ",".join(f"{value:g}" for value in quat_values)
    return f"{acc_text}#{quat_text}$"


def print_summary(state: AdapterState, started: float) -> None:
    elapsed = max(time.monotonic() - started, 1e-9)
    active = [
        f"{index}:{slot.count}"
        for index, slot in enumerate(state.slots)
        if slot.count > 0
    ]
    print(
        f"received={state.received} forwarded={state.forwarded} "
        f"errors={state.errors} out_hz={state.forwarded / elapsed:.1f} "
        f"active_slots={','.join(active) if active else 'none'}",
        flush=True,
    )


def run(args: argparse.Namespace) -> int:
    state = AdapterState()
    started = time.monotonic()
    last_forward = 0.0
    last_summary = started
    min_forward_interval = 1.0 / max(args.output_hz, 1e-9)

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as in_sock, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as out_sock:
        in_sock.bind((args.listen_host, args.listen_port))
        in_sock.settimeout(0.2)
        target = (args.output_host, args.output_port)
        print(
            f"Listening on {args.listen_host}:{args.listen_port}; "
            f"forwarding aggregate MobilePoser frames to {args.output_host}:{args.output_port}",
            flush=True,
        )

        while True:
            if args.max_packets and state.received >= args.max_packets:
                print_summary(state, started)
                return 0 if state.errors == 0 else 1

            try:
                data, address = in_sock.recvfrom(4096)
            except socket.timeout:
                now = time.monotonic()
                if now - last_summary >= args.summary_interval:
                    print_summary(state, started)
                    last_summary = now
                continue

            text = data.decode("utf-8", errors="replace")
            try:
                device_id, device_type, values = parse_packet(text)
                slot_index = slot_for(device_id, device_type)
            except Exception as exc:  # noqa: BLE001 - CLI adapter should keep running and report bad packets.
                state.errors += 1
                print(f"ERROR from {address}: {exc}; packet={text.strip()!r}", file=sys.stderr, flush=True)
                if state.errors >= args.max_errors:
                    return 1
                continue

            state.received += 1
            slot = state.slots[slot_index]
            slot.acc_m_s2 = (values[2], values[3], values[4])
            slot.quat_xyzw = (values[5], values[6], values[7], values[8])
            slot.last_host_time = values[0]
            slot.count += 1

            now = time.monotonic()
            if now - last_forward < min_forward_interval:
                continue
            last_forward = now

            packet = aggregate_packet(state, args.accel_mode)
            if args.print_outgoing:
                print(packet, flush=True)
            if not args.dry_run:
                out_sock.sendto(packet.encode("utf-8"), target)
            state.forwarded += 1

            if now - last_summary >= args.summary_interval:
                print_summary(state, started)
                last_summary = now


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen-host", default="0.0.0.0", help="Input bind host, default 0.0.0.0")
    parser.add_argument("--listen-port", type=int, default=8001, help="Input MobilePoseLab UDP port, default 8001")
    parser.add_argument("--output-host", default="127.0.0.1", help="Output host for live_demo.py, default 127.0.0.1")
    parser.add_argument("--output-port", type=int, default=7777, help="Output UDP port for live_demo.py, default 7777")
    parser.add_argument("--output-hz", type=float, default=30, help="Max aggregate output rate, default 30")
    parser.add_argument("--accel-mode", choices=["g", "negative-g", "m_s2"], default="g", help="Acceleration conversion before live_demo.py sees it")
    parser.add_argument("--summary-interval", type=float, default=2.0, help="Summary interval seconds")
    parser.add_argument("--max-errors", type=int, default=20, help="Stop after this many parse errors")
    parser.add_argument("--max-packets", type=int, default=0, help="Stop after this many input packets, for tests")
    parser.add_argument("--dry-run", action="store_true", help="Do not send output UDP")
    parser.add_argument("--print-outgoing", action="store_true", help="Print aggregate live_demo.py packets")
    args = parser.parse_args(argv)

    for port_name in ("listen_port", "output_port"):
        port = getattr(args, port_name)
        if not 0 <= port <= 65_535:
            print(f"{port_name} must be between 0 and 65535", file=sys.stderr)
            return 2

    return run(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
