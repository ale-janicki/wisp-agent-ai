import json
import threading
import time

import pytest

from wisp import approvals
from wisp.paths import WispPaths


def _paths(home):
    return WispPaths.for_os("Darwin", home, {})


def _wait_pending(paths):
    for _ in range(500):
        found = approvals.pending(paths)
        if found:
            return found[0]
        time.sleep(0.01)
    raise AssertionError("request never appeared")


def _run_decider(paths, allow):
    def go():
        req = _wait_pending(paths)
        assert approvals.decide(paths, req.id, allow) is True

    t = threading.Thread(target=go)
    t.start()
    return t


def _empty(paths):
    return [f for f in (paths.state / "approvals").iterdir() if f.suffix != ".done"] == []


def test_allow_round_trip(fake_home):
    paths = _paths(fake_home)
    t = _run_decider(paths, True)
    result = approvals.request(paths, "send_email", "Enviar", "corpo", poll=0.01)
    t.join()
    assert result == "allow"
    assert _empty(paths)
    assert ((paths.state / "approvals").stat().st_mode & 0o777) == 0o700


def test_deny(fake_home):
    paths = _paths(fake_home)
    t = _run_decider(paths, False)
    result = approvals.request(paths, "send_email", "Enviar", "corpo", poll=0.01)
    t.join()
    assert result == "deny"
    assert _empty(paths)


def test_timeout_removes_request(fake_home):
    paths = _paths(fake_home)
    ticks = iter([0.0, 601.0, 602.0, 603.0])
    result = approvals.request(
        paths, "send_email", "Enviar", "corpo", clock=lambda: next(ticks), sleep=lambda s: None
    )
    assert result == "timeout"
    assert _empty(paths)


def test_first_decision_wins(fake_home):
    paths = _paths(fake_home)
    seen = {}

    def sleep(_):
        req = approvals.pending(paths)[0]
        seen["first"] = approvals.decide(paths, req.id, True)
        seen["second"] = approvals.decide(paths, req.id, False)

    result = approvals.request(paths, "t", "s", "d", sleep=sleep)
    assert seen == {"first": True, "second": False}
    assert result == "allow"
    assert _empty(paths)


def test_decide_missing_request(fake_home):
    assert approvals.decide(_paths(fake_home), "nope", True) is False


def test_request_json_keys_and_thread(fake_home):
    paths = _paths(fake_home)
    seen = {}

    def sleep(_):
        req = approvals.pending(paths)[0]
        seen["keys"] = sorted(json.loads((paths.state / "approvals" / f"{req.id}.json").read_text()))
        seen["thread"] = req.thread
        approvals.decide(paths, req.id, False)

    approvals.request(paths, "t", "s", "d", thread=42, sleep=sleep)
    assert seen["keys"] == ["created", "detail", "id", "summary", "thread", "tool"]
    assert seen["thread"] == 42


def test_pending_lists_oldest_first(fake_home):
    paths = _paths(fake_home)
    def make(tool, created):
        approvals._write_request(paths, approvals.ApprovalRequest(tool * 32, tool, "s", "d", created, None))

    make("b", 2.0)
    make("a", 1.0)
    (paths.state / "approvals" / "orphan.decision").write_text("allow")
    assert [r.tool for r in approvals.pending(paths)] == ["a", "b"]
    for r in approvals.pending(paths):
        (paths.state / "approvals" / f"{r.id}.json").unlink()


@pytest.mark.parametrize("garbage", ["all", "", "yes"])
def test_garbage_decision_ignored(fake_home, garbage):
    paths = _paths(fake_home)
    ticks = iter([0.0, 1.0, 2.0, 601.0, 602.0])
    wrote = []

    def sleep(_):
        if not wrote:
            req = approvals.pending(paths)[0]
            (paths.state / "approvals" / f"{req.id}.decision").write_text(garbage)
            wrote.append(1)

    result = approvals.request(paths, "t", "s", "d", clock=lambda: next(ticks), sleep=sleep)
    assert result == "timeout"
    assert _empty(paths)


def test_pending_skips_corrupt_json(fake_home):
    paths = _paths(fake_home)
    approvals._write_request(paths, approvals.ApprovalRequest("a" * 32, "ok", "s", "d", 1.0, None))
    (paths.state / "approvals" / "bad.json").write_text("{not json")
    assert [r.tool for r in approvals.pending(paths)] == ["ok"]


def test_pending_does_not_create_dir(fake_home):
    paths = _paths(fake_home)
    assert approvals.pending(paths) == []
    assert not (paths.state / "approvals").exists()


def test_decide_after_finished(fake_home):
    paths = _paths(fake_home)
    captured = []

    def sleep(_):
        req = approvals.pending(paths)[0]
        captured.append(req.id)
        approvals.decide(paths, req.id, True)

    approvals.request(paths, "t", "s", "d", sleep=sleep)
    assert approvals.decide(paths, captured[0], True) is False
    assert _empty(paths)


def test_decide_rejects_traversal(fake_home):
    paths = _paths(fake_home)
    approvals._write_request(paths, approvals.ApprovalRequest("a" * 32, "t", "s", "d", 1.0, None))
    (paths.state / "evil.json").write_text("{}")
    assert approvals.decide(paths, "../evil", True) is False
    assert not (paths.state / "evil.decision").exists()
    assert not list((paths.state / "approvals").glob("*.decision"))


def test_existing_dir_mode_fixed(fake_home):
    paths = _paths(fake_home)
    d = paths.state / "approvals"
    d.mkdir(parents=True, mode=0o755)
    d.chmod(0o755)
    approvals.pending(paths)
    approvals._write_request(paths, approvals.ApprovalRequest("a" * 32, "t", "s", "d", 1.0, None))
    assert d.stat().st_mode & 0o777 == 0o700


def test_symlinked_dir_refused(fake_home):
    paths = _paths(fake_home)
    target = fake_home / "elsewhere"
    target.mkdir()
    paths.state.mkdir(parents=True)
    (paths.state / "approvals").symlink_to(target)
    with pytest.raises(approvals.ApprovalDirError):
        approvals.request(paths, "t", "s", "d", sleep=lambda s: None)
    assert list(target.iterdir()) == []


def test_pending_skips_already_decided(fake_home):
    paths = _paths(fake_home)
    approvals._write_request(paths, approvals.ApprovalRequest("a" * 32, "t", "s", "d", 1.0, None))
    approvals._write_request(paths, approvals.ApprovalRequest("b" * 32, "t", "s", "d", 2.0, None))
    assert approvals.decide(paths, "a" * 32, True) is True
    assert [r.id for r in approvals.pending(paths)] == ["b" * 32]


def test_wall_clock_deadline_survives_sleep(fake_home):
    """The monotonic clock stands still while the Mac sleeps; the wall clock still ends the wait."""
    paths = _paths(fake_home)
    walls = iter([1000.0, 1000.0, 1300.0, 1601.0])
    result = approvals.request(
        paths, "t", "s", "d", clock=lambda: 0.0, wall=lambda: next(walls), sleep=lambda s: None
    )
    assert result == "timeout"
    assert _empty(paths)


def test_pending_requires_id_to_match_the_filename(fake_home):
    paths = _paths(fake_home)
    approvals._write_request(paths, approvals.ApprovalRequest("a" * 32, "ok", "s", "d", 1.0, None))
    d = paths.state / "approvals"
    (d / ("b" * 32 + ".json")).write_text(json.dumps({"id": "c" * 32, "tool": "x", "summary": "s", "detail": "d", "created": 2.0, "thread": None}))
    (d / "NOT-AN-ID.json").write_text(json.dumps({"id": "NOT-AN-ID", "tool": "y", "summary": "s", "detail": "d", "created": 3.0, "thread": None}))
    assert [r.tool for r in approvals.pending(paths)] == ["ok"]


def _tombstones(paths):
    return {f.stem: json.loads(f.read_text()) for f in (paths.state / "approvals").glob("*.done")}


def _only_tombstone(paths):
    found = _tombstones(paths)
    assert len(found) == 1
    id, data = next(iter(found.items()))
    assert data["id"] == id
    return data


def test_allow_and_deny_leave_a_tombstone(fake_home):
    for allow, outcome in ((True, "allow"), (False, "deny")):
        paths = _paths(fake_home)
        for f in (paths.state / "approvals").glob("*") if (paths.state / "approvals").exists() else []:
            f.unlink()
        t = _run_decider(paths, allow)
        approvals.request(paths, "t", "s", "d", poll=0.01)
        t.join()
        assert _only_tombstone(paths)["outcome"] == outcome
        assert sorted(p.suffix for p in (paths.state / "approvals").iterdir()) == [".done"]


def test_timeout_leaves_an_expired_tombstone(fake_home):
    paths = _paths(fake_home)
    ticks = iter([0.0, 601.0, 602.0, 603.0])
    approvals.request(paths, "t", "s", "d", clock=lambda: next(ticks), sleep=lambda s: None)
    assert _only_tombstone(paths)["outcome"] == "expired"


def test_exception_leaves_a_cancelled_tombstone(fake_home):
    paths = _paths(fake_home)

    def sleep(_):
        raise KeyboardInterrupt

    with pytest.raises(KeyboardInterrupt):
        approvals.request(paths, "t", "s", "d", sleep=sleep)
    assert _only_tombstone(paths)["outcome"] == "cancelled"
    assert sorted(p.suffix for p in (paths.state / "approvals").iterdir()) == [".done"]


def test_async_cancellation_leaves_a_cancelled_tombstone(fake_home):
    import asyncio

    paths = _paths(fake_home)

    async def go():
        task = asyncio.ensure_future(approvals.request_async(paths, "t", "s", "d", poll=0.01, sleep=asyncio.sleep))
        for _ in range(200):
            if approvals.pending(paths):
                break
            await asyncio.sleep(0.01)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

    asyncio.run(go())
    assert _only_tombstone(paths)["outcome"] == "cancelled"


def test_pending_ignores_tombstones_and_removes_stale_ones(fake_home):
    import os

    paths = _paths(fake_home)
    approvals._write_request(paths, approvals.ApprovalRequest("a" * 32, "ok", "s", "d", 1.0, None))
    d = paths.state / "approvals"
    fresh, stale = d / ("b" * 32 + ".done"), d / ("c" * 32 + ".done")
    for f in (fresh, stale):
        f.write_text(json.dumps({"id": f.stem, "outcome": "allow"}))
    old = time.time() - 601
    os.utime(stale, (old, old))
    assert [r.tool for r in approvals.pending(paths)] == ["ok"]
    assert fresh.exists() and not stale.exists()


def _tombstone(paths, id, outcome):
    (paths.state / "approvals" / f"{id}.done").write_text(json.dumps({"id": id, "outcome": outcome}))


def _open_request(paths):
    req = approvals.ApprovalRequest("c" * 32, "email_send", "Enviar", "corpo", time.time(), None)
    approvals._write_request(paths, req)
    return req


def test_timeout_takes_the_decision_file_so_a_late_allow_fails(fake_home):
    paths = _paths(fake_home)
    req = _open_request(paths)
    decision = paths.state / "approvals" / f"{req.id}.decision"
    outcome = approvals._outcome(req, decision, 0.0, 600.0, lambda: 601.0, time.time)
    assert outcome == "timeout"
    assert decision.read_text() == "timeout"
    assert approvals.decide(paths, req.id, True) is False
    assert approvals.pending(paths) == []


def test_an_answer_that_lands_as_the_timeout_hits_still_wins(fake_home):
    paths = _paths(fake_home)
    req = _open_request(paths)
    decision = paths.state / "approvals" / f"{req.id}.decision"
    decision.write_text("allow")
    assert approvals._claim_timeout(decision) == "allow"
    assert decision.read_text() == "allow"


def test_a_forged_decision_file_counts_as_timeout(fake_home):
    paths = _paths(fake_home)
    req = _open_request(paths)
    decision = paths.state / "approvals" / f"{req.id}.decision"
    decision.write_text("sure")
    assert approvals._claim_timeout(decision) == "timeout"


@pytest.mark.parametrize("outcome", ["expired", "cancelled"])
def test_decide_after_the_tool_gave_up_is_refused_and_leaves_nothing(fake_home, outcome):
    paths = _paths(fake_home)
    req = _open_request(paths)
    _tombstone(paths, req.id, outcome)
    assert approvals.decide(paths, req.id, True) is False
    assert not (paths.state / "approvals" / f"{req.id}.decision").exists()


def test_decide_after_the_request_vanished_without_tombstone_is_refused(fake_home):
    paths = _paths(fake_home)
    req = _open_request(paths)
    real = approvals._still_open
    assert real(paths.state / "approvals", req.id) is True
    (paths.state / "approvals" / f"{req.id}.json").unlink()
    assert real(paths.state / "approvals", req.id) is False


def test_decide_while_the_tool_is_picking_it_up_still_counts(fake_home):
    paths = _paths(fake_home)
    req = _open_request(paths)
    _tombstone(paths, req.id, "allow")
    (paths.state / "approvals" / f"{req.id}.json").unlink()
    assert approvals._still_open(paths.state / "approvals", req.id) is True


def test_the_tool_leaves_its_tombstone_before_removing_the_request(fake_home):
    paths = _paths(fake_home)
    directory = paths.state / "approvals"
    order = []
    real_unlink = approvals.Path.unlink

    def spying(self, *a, **k):
        if self.suffix == ".json":
            order.append("done" if any(f.suffix == ".done" for f in directory.iterdir()) else "no tombstone")
        return real_unlink(self, *a, **k)

    ticks = iter([0.0, 601.0, 602.0, 603.0])
    approvals.Path.unlink = spying
    try:
        approvals.request(paths, "t", "s", "d", clock=lambda: next(ticks), sleep=lambda s: None)
    finally:
        approvals.Path.unlink = real_unlink
    assert order == ["done"]
