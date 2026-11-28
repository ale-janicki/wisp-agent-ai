import { rowDetail, rowLabel, severityOf, usageRows } from "./usage";

describe("usage rows", () => {
  it("rounds the percentage, flags severity at 75 and 90, and calls an expired window renewed", () => {
    const rows = usageRows(
      { five_hour: { utilization: 0.75, resets_at: 2_000_000_000 }, seven_day: { utilization: 0.9, resets_at: 1_000 } },
      1_999_999_000,
    );
    expect(rows[0]).toMatchObject({ kind: "session", state: "used", percent: 75, severity: "warning" });
    expect(rowLabel(rows[0]!)).toBe("Sessão 75%");
    expect(rows[1]).toEqual({ kind: "week", state: "renewed" });
    expect(rowLabel(rows[1]!)).toBe("Semana renovado");
    expect([0.74, 0.75, 0.89, 0.9].map(severityOf)).toEqual(["normal", "warning", "warning", "critical"]);
  });

  it("has no reset text without a reset time and an empty window reads 0%", () => {
    const [session, week] = usageRows({ five_hour: null, seven_day: { utilization: 0.1, resets_at: null } }, 0);
    expect(rowLabel(session!)).toBe("Sessão 0%");
    expect(rowDetail(week!)).toBeNull();
    const [timed] = usageRows({ five_hour: { utilization: 0.2, resets_at: 4_102_444_800 }, seven_day: null }, 0);
    expect(rowDetail(timed!)).toMatch(/^renova \d{2}:\d{2}$/);
  });
});
