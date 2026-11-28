import json
import os
from datetime import datetime, timedelta, timezone

from wisp.serve.features.home_usage import UsageIndex

NOW = datetime(2026, 12, 3, 15, 0).astimezone()


def line(ident, when, input_=10, output=5, creation=3, read=100, model="claude-x"):
    return json.dumps({"type": "assistant", "uuid": "u-" + ident, "timestamp": when.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
                       "message": {"id": ident, "model": model, "usage": {"input_tokens": input_, "output_tokens": output,
                                                                       "cache_creation_input_tokens": creation, "cache_read_input_tokens": read}}})


def write(path, *lines, newline=True):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + ("\n" if newline else ""))


def test_today_and_week_count_billable_tokens_and_leave_cache_reads_out(tmp_path):
    write(tmp_path / "p/a.jsonl", line("m1", NOW), line("m2", NOW - timedelta(days=2)), line("old", NOW - timedelta(days=9)))
    assert UsageIndex(tmp_path).summary(NOW) == {"today": 18, "week": 36}


def test_a_message_counted_in_two_transcripts_counts_once(tmp_path):
    write(tmp_path / "p/a.jsonl", line("m1", NOW))
    write(tmp_path / "p/b.jsonl", line("m1", NOW), line("m3", NOW))
    assert UsageIndex(tmp_path).summary(NOW)["today"] == 36


def test_synthetic_and_non_usage_lines_are_ignored(tmp_path):
    write(tmp_path / "p/a.jsonl", line("s", NOW, model="<synthetic>"), '{"type":"user","message":{"content":"oi"}}', "not json", line("ok", NOW))
    assert UsageIndex(tmp_path).summary(NOW)["today"] == 18


def test_a_grown_file_is_read_from_where_it_stopped_and_a_half_written_line_is_counted_but_reread(tmp_path):
    path = tmp_path / "p/a.jsonl"
    write(path, line("m1", NOW))
    index = UsageIndex(tmp_path)
    assert index.summary(NOW)["today"] == 18
    with path.open("a") as handle:
        handle.write(line("m2", NOW))
    assert index.summary(NOW)["today"] == 36
    state = index._files[path]
    assert len(state.entries) == 1 and len(state.tail) == 1
    with path.open("a") as handle:
        handle.write("\n")
    assert index.summary(NOW)["today"] == 36 and len(index._files[path].entries) == 2


def test_files_untouched_inside_the_window_are_not_opened(tmp_path):
    path = tmp_path / "p/a.jsonl"
    write(path, line("m1", NOW))
    long_ago = (NOW - timedelta(days=30)).timestamp()
    os.utime(path, (long_ago, long_ago))
    index = UsageIndex(tmp_path)
    assert index.summary(NOW) == {"today": 0, "week": 0} and index._files == {}


def test_a_missing_folder_is_zero(tmp_path):
    assert UsageIndex(tmp_path / "nope").summary(NOW) == {"today": 0, "week": 0}
