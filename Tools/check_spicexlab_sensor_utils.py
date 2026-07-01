#!/usr/bin/env python3
"""Check MobilePoseLab packets with SPICExLAB/MobilePoser sensor_utils.process_data.

This optional checker imports the real SPICExLAB/MobilePoser parser from a local
clone and feeds it MobilePoseLab UDP packets. It is stronger than
`check_mobileposer_packet_compat.py`, which only checks the naming convention.

Example:

    python Tools/check_spicexlab_sensor_utils.py /path/to/MobilePoser \
      "right;phone:1000 1000 0.1 0.2 0.3 0 0 0 1 0.01 0.02 0.03"

Or check the first rows of a current-schema MobilePoseLab CSV:

    python Tools/check_spicexlab_sensor_utils.py /path/to/MobilePoser exported.csv
"""

from __future__ import annotations

import argparse
import csv
import importlib
import importlib.util
import sys
import types
from pathlib import Path
from typing import Any


def import_process_data(repo_path: Path) -> Any:
    repo_path = repo_path.expanduser().resolve()
    config_path = repo_path / "mobileposer" / "config.py"
    sensor_utils_path = repo_path / "mobileposer" / "utils" / "sensor_utils.py"
    if not sensor_utils_path.exists():
        raise FileNotFoundError(f"sensor_utils.py not found under {repo_path}")
    if not config_path.exists():
        raise FileNotFoundError("MobilePoser config.py not found")

    # Avoid importing mobileposer/__init__.py, which may pull training dependencies
    # such as lightning. The parser only needs config.py and constants.py.
    package = types.ModuleType("mobileposer")
    package.__path__ = [str(repo_path / "mobileposer")]
    utils_package = types.ModuleType("mobileposer.utils")
    utils_package.__path__ = [str(repo_path / "mobileposer" / "utils")]
    sys.modules["mobileposer"] = package
    sys.modules["mobileposer.utils"] = utils_package

    constants_module = types.ModuleType("mobileposer.constants")
    constants_module.KEYS = [
        "unix_timestamp",
        "sensor_timestamp",
        "accel_x",
        "accel_y",
        "accel_z",
        "quart_x",
        "quart_y",
        "quart_z",
        "quart_w",
        "roll",
        "pitch",
        "yaw",
    ]
    constants_module.STOP = "stop"
    constants_module.SEP = ":"
    constants_module.BUFFER_SIZE = 50
    sys.modules["mobileposer.constants"] = constants_module

    for module_name, module_path in (
        ("mobileposer.config", config_path),
        ("mobileposer.utils.sensor_utils", sensor_utils_path),
    ):
        spec = importlib.util.spec_from_file_location(module_name, module_path)
        if spec is None or spec.loader is None:
            raise ImportError(f"cannot load {module_name} from {module_path}")
        module = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = module
        spec.loader.exec_module(module)

    return sys.modules["mobileposer.utils.sensor_utils"].process_data


def packet_from_csv_row(row: dict[str, str]) -> str:
    required = [
        "device_id",
        "device_type",
        "host_time_s",
        "device_time_s",
        "ax_m_s2",
        "ay_m_s2",
        "az_m_s2",
        "quat_x",
        "quat_y",
        "quat_z",
        "quat_w",
    ]
    missing = [name for name in required if name not in row]
    if missing:
        raise ValueError("CSV row missing columns: " + ", ".join(missing))

    values = [
        row["host_time_s"],
        row["device_time_s"],
        row["ax_m_s2"],
        row["ay_m_s2"],
        row["az_m_s2"],
        row["quat_x"],
        row["quat_y"],
        row["quat_z"],
        row["quat_w"],
    ]
    if row.get("gyro_available") == "1":
        values.extend([row.get("gx_rad_s", "0"), row.get("gy_rad_s", "0"), row.get("gz_rad_s", "0")])
    return f"{row['device_id']};{row['device_type']}:{' '.join(values)}"


def packets_from_input(input_text: str, limit: int) -> list[str]:
    path = Path(input_text).expanduser()
    if not path.exists():
        return [input_text]

    packets: list[str] = []
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            packets.append(packet_from_csv_row(row))
            if len(packets) >= limit:
                break
    return packets


def check_packet(process_data: Any, packet: str) -> tuple[bool, str]:
    try:
        result = process_data(packet.encode("utf-8"))
    except Exception as exc:  # noqa: BLE001 - report exact official parser exception.
        return False, f"official process_data raised {type(exc).__name__}: {exc}"

    if result is None:
        return False, "official process_data returned None"

    try:
        _send_str, device_name, curr_acc, curr_ori, timestamps = result
    except Exception as exc:  # noqa: BLE001 - malformed official return is useful to report.
        return False, f"official process_data returned unexpected shape: {exc}"

    return (
        True,
        f"device={device_name} acc_shape={getattr(curr_acc, 'shape', None)} "
        f"ori_shape={getattr(curr_ori, 'shape', None)} timestamps={timestamps}",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mobileposer_repo", type=Path, help="Path to local SPICExLAB/MobilePoser clone")
    parser.add_argument("input", help="MobilePoseLab packet string or current-schema CSV path")
    parser.add_argument("--limit", type=int, default=20, help="Maximum CSV rows to check")
    args = parser.parse_args()

    try:
        process_data = import_process_data(args.mobileposer_repo)
        packets = packets_from_input(args.input, args.limit)
    except Exception as exc:  # noqa: BLE001 - CLI should print concise setup failure.
        print(f"FAIL: {exc}", file=sys.stderr)
        return 2

    failures = 0
    for index, packet in enumerate(packets, start=1):
        ok, message = check_packet(process_data, packet)
        print(f"{index}: {'OK' if ok else 'FAIL'} - {message}")
        failures += 0 if ok else 1

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
