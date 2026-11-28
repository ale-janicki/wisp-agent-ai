from __future__ import annotations

import asyncio
import ctypes
import platform
import socket
import sys
import threading
import time
from typing import Callable, Protocol

from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

PROCESS_ROWS = 5
UNAVAILABLE_PROCESSES = "Não consegui listar os processos"
ELEVATED = {"System Idle Process", "Idle"}


class Probe(Protocol):
    def machine(self) -> dict: ...
    def cpu_fraction(self) -> float | None: ...
    def memory(self) -> dict | None: ...
    def network(self) -> dict | None: ...
    def volumes(self) -> list[dict]: ...
    def battery(self) -> dict | None: ...
    def temperatures(self) -> dict | None: ...
    def processes(self) -> list[dict] | None: ...


def pressure(used_fraction: float) -> str:
    return "critical" if used_fraction >= 0.9 else "warning" if used_fraction >= 0.75 else "normal"


class Sampler:
    def __init__(self, probe: Probe, clock: Callable[[], float] = time.monotonic) -> None:
        self.probe, self.clock = probe, clock
        self._net: tuple[str, int, int, float] | None = None
        self._machine: dict | None = None
        self._lock = threading.Lock()

    def machine(self) -> dict:
        if self._machine is None:
            self._machine = self.probe.machine()
        return self._machine

    def sample(self) -> dict:
        with self._lock:
            memory = self.probe.memory()
            if memory is not None:
                total = memory["total"]
                memory = {**memory, "used_fraction": min(1.0, memory["used"] / total) if total else 0.0}
                memory["pressure"] = pressure(memory["used_fraction"])
            processes = self.probe.processes()
            return {"cpu": self._cpu(), "memory": memory, "network": self._network(),
                    "volumes": self.probe.volumes(), "temperature": self.probe.temperatures(),
                    "battery": self.probe.battery(),
                    "top_cpu": None if processes is None else sorted(
                        processes, key=lambda p: (p["cpu"], p["pid"]), reverse=True)[:PROCESS_ROWS],
                    "top_memory": None if processes is None else sorted(
                        processes, key=lambda p: (p["rss"], p["pid"]), reverse=True)[:PROCESS_ROWS]}

    def _cpu(self) -> dict | None:
        total = self.probe.cpu_fraction()
        return None if total is None else {"total": min(1.0, max(0.0, total))}

    def _network(self) -> dict | None:
        info = self.probe.network()
        if info is None:
            self._net = None
            return None
        now = self.clock()
        rate = None
        if self._net and self._net[0] == info["interface"] and now > self._net[3]:
            seconds = now - self._net[3]
            rate = {"down": max(0, int((info["received"] - self._net[1]) / seconds)),
                    "up": max(0, int((info["sent"] - self._net[2]) / seconds))}
        self._net = (info["interface"], info["received"], info["sent"], now)
        return {"interface": info["interface"], "address": info.get("address"), "rate": rate}


class PsutilProbe:
    def __init__(self) -> None:
        import psutil
        self.ps = psutil
        self._procs: dict[int, "psutil.Process"] = {}
        psutil.cpu_percent(None)

    def machine(self) -> dict:
        ps = self.ps
        build = platform.version()
        major = platform.system()
        if major == "Windows":
            try:
                number = int(build.split(".")[-1])
            except ValueError:
                number = 0
            release = "11" if number >= 22000 else platform.release()
            os_label = f"Windows {release}"
        else:
            os_label, build = f"{major} {platform.release()}", ""
        return {"name": socket.gethostname(), "cpu": _cpu_name(), "os": os_label, "build": build,
                "cores": ps.cpu_count(logical=False) or ps.cpu_count(logical=True) or 0,
                "threads": ps.cpu_count(logical=True) or 0, "boot_time": ps.boot_time()}

    def cpu_fraction(self) -> float | None:
        return self.ps.cpu_percent(None) / 100.0

    def memory(self) -> dict | None:
        mem, swap = self.ps.virtual_memory(), self.ps.swap_memory()
        return {"total": mem.total, "used": mem.total - mem.available, "available": mem.available,
                "swap_total": swap.total, "swap_used": swap.used}

    def network(self) -> dict | None:
        ps = self.ps
        stats, addresses, counters = ps.net_if_stats(), ps.net_if_addrs(), ps.net_io_counters(pernic=True)
        best = None
        for name, stat in stats.items():
            ipv4 = next((a.address for a in addresses.get(name, []) if a.family == socket.AF_INET), None)
            if not stat.isup or not ipv4 or ipv4.startswith(("127.", "169.254.")) or name not in counters:
                continue
            traffic = counters[name].bytes_recv + counters[name].bytes_sent
            if best is None or traffic > best[0]:
                best = (traffic, name, ipv4)
        if best is None:
            return None
        counter = counters[best[1]]
        return {"interface": best[1], "address": best[2], "received": counter.bytes_recv, "sent": counter.bytes_sent}

    def volumes(self) -> list[dict]:
        import os
        boot = os.environ.get("SystemDrive", "C:").upper() + "\\" if sys.platform == "win32" else "/"
        found = []
        for part in self.ps.disk_partitions(all=False):
            if sys.platform == "win32" and ("cdrom" in part.opts or not part.fstype):
                continue
            try:
                usage = self.ps.disk_usage(part.mountpoint)
            except OSError:
                continue
            found.append({"id": part.mountpoint, "name": part.mountpoint, "total": usage.total,
                          "available": usage.free, "is_boot": part.mountpoint.upper() == boot.upper()})
        return found

    def battery(self) -> dict | None:
        status = _power_status()
        if status is not None:
            return status
        battery = self.ps.sensors_battery()
        if battery is None:
            return None
        plugged = bool(battery.power_plugged)
        state = "charged" if plugged and battery.percent >= 100 else "charging" if plugged else "discharging"
        left = battery.secsleft if isinstance(battery.secsleft, int) and battery.secsleft > 0 else None
        return {"percent": int(round(battery.percent)), "state": state,
                "minutes_to_empty": left // 60 if left and state == "discharging" else None}

    def temperatures(self) -> dict | None:
        reader = getattr(self.ps, "sensors_temperatures", None)
        try:
            groups = reader() if reader else {}
        except (OSError, AttributeError):
            return None
        readings = [r.current for entries in groups.values() for r in entries if r.current and 0 < r.current < 130]
        return {"average": sum(readings) / len(readings), "max": max(readings)} if readings else None

    def processes(self) -> list[dict] | None:
        ps, rows, alive = self.ps, [], set()
        try:
            for proc in ps.process_iter():
                alive.add(proc.pid)
                cached = self._procs.setdefault(proc.pid, proc)
                try:
                    name = cached.name()
                    if name in ELEVATED:
                        continue
                    with cached.oneshot():
                        rows.append({"pid": cached.pid, "name": name, "cpu": cached.cpu_percent(None),
                                     "rss": cached.memory_info().rss})
                except (ps.NoSuchProcess, ps.AccessDenied, ps.ZombieProcess):
                    continue
        except OSError:
            return None
        for pid in set(self._procs) - alive:
            del self._procs[pid]
        return rows


def _cpu_name() -> str:
    if sys.platform == "win32":
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"HARDWARE\DESCRIPTION\System\CentralProcessor\0") as key:
                return " ".join(str(winreg.QueryValueEx(key, "ProcessorNameString")[0]).split())
        except OSError:
            pass
    return platform.processor() or ""


def _power_status() -> dict | None:
    if sys.platform != "win32":
        return None
    from ctypes import wintypes

    class Status(ctypes.Structure):
        _fields_ = [("ACLineStatus", ctypes.c_ubyte), ("BatteryFlag", ctypes.c_ubyte),
                    ("BatteryLifePercent", ctypes.c_ubyte), ("SystemStatusFlag", ctypes.c_ubyte),
                    ("BatteryLifeTime", wintypes.DWORD), ("BatteryFullLifeTime", wintypes.DWORD)]

    status = Status()
    if not ctypes.WinDLL("kernel32").GetSystemPowerStatus(ctypes.byref(status)) or status.BatteryFlag & 128 \
            or status.BatteryFlag == 255 or status.BatteryLifePercent > 100:
        return None
    online = status.ACLineStatus == 1
    state = ("charging" if status.BatteryFlag & 8 else "charged" if online and status.BatteryLifePercent >= 100
             else "on_ac" if online else "discharging")
    remaining = status.BatteryLifeTime
    minutes = remaining // 60 if state == "discharging" and remaining != 0xFFFFFFFF else None
    return {"percent": status.BatteryLifePercent, "state": state, "minutes_to_empty": minutes}


_sampler: Sampler | None = None


def sampler() -> Sampler | None:
    global _sampler
    if _sampler is None:
        try:
            _sampler = Sampler(PsutilProbe())
        except ImportError:
            return None
    return _sampler


async def get_machine(request: Request) -> Response:
    current = sampler()
    if current is None:
        return JSONResponse({"error": "psutil não está instalado"}, status_code=501)
    return JSONResponse(await asyncio.to_thread(current.machine))


async def get_sample(request: Request) -> Response:
    current = sampler()
    if current is None:
        return JSONResponse({"error": "psutil não está instalado"}, status_code=501)
    return JSONResponse(await asyncio.to_thread(current.sample))


routes = [Route("/machine", get_machine, methods=["GET"]), Route("/sample", get_sample, methods=["GET"])]
