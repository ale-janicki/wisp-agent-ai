import { eventsOnDay, monthWeeks, parseEvent, place, rangeFor, segmentOn, sentenceCase, startOfDay, titleFor, weekStart } from "./calendar";
import type { ApiEvent } from "./types";

const api = (over: Partial<ApiEvent> = {}): ApiEvent => ({
  id: "e",
  title: "Reunião",
  start: "2026-12-01T10:00:00-03:00",
  end: "2026-12-01T11:00:00-03:00",
  all_day: false,
  time_zone: null,
  location: null,
  notes: null,
  html_link: null,
  meeting: null,
  attendees: [],
  my_status: null,
  declined: false,
  can_respond: false,
  recurring: false,
  busy: true,
  cancelled: false,
  ...over,
});

const local = (y: number, m: number, d: number, h = 0, min = 0) => new Date(y, m - 1, d, h, min);

describe("calendar maths", () => {
  it("reads an all-day event as local midnights with an exclusive end", () => {
    const e = parseEvent(api({ all_day: true, start: "2026-12-01", end: "2026-12-03" }));
    expect(e.start).toEqual(local(2026, 12, 1));
    expect(e.end).toEqual(local(2026, 12, 4));
  });

  it("starts weeks on Sunday as the Mac does in pt-BR and builds month grids of whole weeks", () => {
    expect(weekStart(local(2026, 11, 28))).toEqual(local(2026, 11, 22));
    expect(weekStart(local(2026, 11, 22))).toEqual(local(2026, 11, 22));
    const weeks = monthWeeks(local(2026, 11, 15));
    expect(weeks[0]![0]).toEqual(local(2026, 11, 1));
    expect(weeks.at(-1)!.at(-1)).toEqual(local(2026, 12, 5));
    expect(weeks.every((w) => w.length === 7)).toBe(true);
  });

  it("titles the view in sentence-case pt-BR", () => {
    expect(titleFor("month", local(2026, 12, 3))).toBe("Dezembro de 2026");
    expect(titleFor("day", local(2026, 12, 3))).toBe("Quinta-feira, 3 de dezembro");
    expect(titleFor("week", local(2026, 12, 3))).toBe("Dezembro de 2026");
    expect(sentenceCase("")).toBe("");
  });

  it("asks the sidecar for exactly what the view shows", () => {
    const week = rangeFor("week", local(2026, 12, 3));
    expect([week.start, week.end]).toEqual([local(2026, 11, 29), local(2026, 12, 6)]);
    const day = rangeFor("day", local(2026, 12, 3, 15));
    expect([day.start, day.end]).toEqual([local(2026, 12, 3), local(2026, 12, 4)]);
    const month = rangeFor("month", local(2026, 12, 3));
    expect([month.start, month.end]).toEqual([local(2026, 11, 29), local(2027, 1, 3)]);
  });

  it("puts a multi-day event on every day it touches, all-day first", () => {
    const trip = parseEvent(api({ id: "t", all_day: true, start: "2026-12-01", end: "2026-12-03" }));
    const meet = parseEvent(api({ id: "m", start: "2026-12-02T09:00:00", end: "2026-12-02T10:00:00" }));
    const overnight = parseEvent(api({ id: "o", start: "2026-12-02T22:00:00", end: "2026-12-03T02:00:00" }));
    const all = [meet, trip, overnight];
    expect(eventsOnDay(all, local(2026, 12, 1)).map((e) => e.id)).toEqual(["t"]);
    expect(eventsOnDay(all, local(2026, 12, 2)).map((e) => e.id)).toEqual(["t", "m", "o"]);
    expect(eventsOnDay(all, local(2026, 12, 3)).map((e) => e.id)).toEqual(["t", "o"]);
    expect(eventsOnDay(all, local(2026, 12, 4))).toEqual([]);
  });

  it("clamps a segment to its day and never draws it shorter than 20 minutes", () => {
    const overnight = parseEvent(api({ id: "o", start: "2026-12-02T22:00:00", end: "2026-12-03T02:00:00" }));
    expect(segmentOn(overnight, local(2026, 12, 2))).toEqual({ id: "o", startMinute: 1320, endMinute: 1440 });
    expect(segmentOn(overnight, local(2026, 12, 3))).toEqual({ id: "o", startMinute: 0, endMinute: 120 });
    const quick = parseEvent(api({ id: "q", start: "2026-12-02T09:00:00", end: "2026-12-02T09:05:00" }));
    expect(segmentOn(quick, local(2026, 12, 2))).toEqual({ id: "q", startMinute: 540, endMinute: 560 });
    expect(segmentOn(quick, local(2026, 12, 5))).toBeNull();
    const allDay = parseEvent(api({ all_day: true, start: "2026-12-02", end: "2026-12-02" }));
    expect(segmentOn(allDay, local(2026, 12, 2))).toBeNull();
  });

  it("lays out overlaps in columns and widens an event over free columns", () => {
    const placed = place([
      { id: "a", startMinute: 540, endMinute: 660 },
      { id: "b", startMinute: 570, endMinute: 600 },
      { id: "c", startMinute: 600, endMinute: 720 },
      { id: "z", startMinute: 800, endMinute: 860 },
    ]);
    const byId = Object.fromEntries(placed.map((p) => [p.id, p]));
    expect([byId.a!.column, byId.a!.columns, byId.a!.span]).toEqual([0, 2, 1]);
    expect([byId.b!.column, byId.b!.span]).toEqual([1, 1]);
    expect([byId.c!.column, byId.c!.span]).toEqual([1, 1]);
    expect([byId.z!.column, byId.z!.columns, byId.z!.span]).toEqual([0, 1, 1]);
  });

  it("start of day drops the time", () => {
    expect(startOfDay(local(2026, 12, 3, 17, 45))).toEqual(local(2026, 12, 3));
  });
});
