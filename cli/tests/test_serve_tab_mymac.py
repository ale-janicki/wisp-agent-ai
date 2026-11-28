import pytest

from serve_tab_helpers import client
from wisp.serve.features import mymac


class FakeProbe:
    def __init__(self):
        self.net = {"interface": "Wi-Fi", "address": "192.168.0.7", "received": 1_000, "sent": 500}
        self.procs = [{"pid": 4, "name": "a.exe", "cpu": 3.0, "rss": 900}, {"pid": 5, "name": "b.exe", "cpu": 80.0, "rss": 10},
                      {"pid": 6, "name": "c.exe", "cpu": 80.0, "rss": 500}]
        self.used = 6

    def machine(self):
        return {"name": "PC-DA-MARIA", "cpu": "CPU X", "os": "Windows 11", "build": "10.0.22631", "cores": 4,
                "threads": 8, "boot_time": 1.0}

    def cpu_fraction(self):
        return 0.25

    def memory(self):
        return {"total": 8, "used": self.used, "available": 8 - self.used, "swap_total": 0, "swap_used": 0}

    def network(self):
        return self.net

    def volumes(self):
        return [{"id": "C:\\", "name": "C:\\", "total": 100, "available": 40, "is_boot": True}]

    def battery(self):
        return None

    def temperatures(self):
        return None

    def processes(self):
        return self.procs


def test_network_rate_is_the_counter_delta_over_the_elapsed_time():
    probe, now = FakeProbe(), [10.0]
    sampler = mymac.Sampler(probe, clock=lambda: now[0])
    assert sampler.sample()["network"]["rate"] is None
    probe.net = {**probe.net, "received": 3_000, "sent": 1_500}
    now[0] = 12.0
    assert sampler.sample()["network"] == {"interface": "Wi-Fi", "address": "192.168.0.7", "rate": {"down": 1000, "up": 500}}


def test_a_new_interface_or_a_dropped_link_restarts_the_rate():
    probe, now = FakeProbe(), [0.0]
    sampler = mymac.Sampler(probe, clock=lambda: now[0])
    sampler.sample()
    probe.net = {**probe.net, "interface": "Ethernet", "received": 9_999_999}
    now[0] = 1.0
    assert sampler.sample()["network"]["rate"] is None
    probe.net = None
    assert sampler.sample()["network"] is None


@pytest.mark.parametrize("used,label", [(5, "normal"), (6, "warning"), (8, "critical")])
def test_memory_pressure_label_follows_how_full_memory_is(used, label):
    probe = FakeProbe()
    probe.used = used
    memory = mymac.Sampler(probe).sample()["memory"]
    assert memory["pressure"] == label and memory["used_fraction"] == used / 8


def test_top_processes_are_sorted_with_pid_as_tiebreak():
    sample = mymac.Sampler(FakeProbe()).sample()
    assert [p["pid"] for p in sample["top_cpu"]] == [6, 5, 4]
    assert [p["pid"] for p in sample["top_memory"]] == [4, 6, 5]


def test_unreadable_process_list_is_null_not_empty():
    probe = FakeProbe()
    probe.procs = None
    sample = mymac.Sampler(probe).sample()
    assert sample["top_cpu"] is None and sample["top_memory"] is None


def test_routes_serve_machine_and_sample(monkeypatch):
    monkeypatch.setattr(mymac, "_sampler", mymac.Sampler(FakeProbe()))
    c = client()
    assert c.get("/api/mymac/machine").json()["name"] == "PC-DA-MARIA"
    assert c.get("/api/mymac/sample").json()["cpu"] == {"total": 0.25}


def test_psutil_probe_reads_this_machine():
    pytest.importorskip("psutil")
    sample = mymac.Sampler(mymac.PsutilProbe()).sample()
    assert 0 <= sample["cpu"]["total"] <= 1 and sample["memory"]["total"] > 0 and sample["volumes"]
