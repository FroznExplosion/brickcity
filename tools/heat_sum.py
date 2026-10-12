"""The heat log over a test run, in one line: the peak temperature and whether
the chip was held back (CLAUDE.md, "the PC crashes": say both after every
windowed or long run).

    python tools/heat_sum.py 14:02 14:09        a run's start and end (today)
    python tools/heat_sum.py 14:02              from then to now
    python tools/heat_sum.py --last 10          the last 10 minutes
    python tools/heat_sum.py 14:02 14:09 --date 2026-10-11

Held back: any sample at or over HOT_C (the chip throttles itself there and
Windows' passive_pct does not show it), passive_pct under 100, or a throttle
reason. The log is tools/heat_log.ps1's, %LOCALAPPDATA%/brickcity-heat.
Exit code 2 when it was held back, 1 when there are no samples, else 0.
"""
import argparse
import csv
import datetime
import os
import sys

HOT_C = 99.0  # as heat_log.ps1
WARM_C = 90.0  # CLAUDE.md: 90 C or more is worth saying


def _hms(t: str) -> str:
    return t if t.count(":") == 2 else t + ":00"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("start", nargs="?")
    ap.add_argument("end", nargs="?")
    ap.add_argument("--last", type=float, help="minutes back from now")
    ap.add_argument("--date", default=str(datetime.date.today()))
    a = ap.parse_args()
    now = datetime.datetime.now()
    if a.last is not None:
        start = (now - datetime.timedelta(minutes=a.last)).strftime("%H:%M:%S")
        end = now.strftime("%H:%M:%S")
    elif a.start:
        start, end = _hms(a.start), _hms(a.end) if a.end else now.strftime("%H:%M:%S")
    else:
        ap.error("give a start time or --last")
    path = os.path.join(os.environ["LOCALAPPDATA"], "brickcity-heat", "heat_%s.csv" % a.date)
    if not os.path.exists(path):
        print("no heat log for %s -- the logger is not running (Startup: 'brickcity heat log')" % a.date)
        return 1
    with open(path, newline="") as f:
        rows = [r for r in csv.DictReader(f) if start <= r["time"] <= end and r["temp_c"]]
    if not rows:
        print("no heat samples %s-%s (%s)" % (start, end, path))
        return 1
    temps = [float(r["temp_c"]) for r in rows]
    peak = max(rows, key=lambda r: float(r["temp_c"]))
    step = 7.0  # seconds a sample stands for, about
    if len(rows) > 1:
        t0 = datetime.datetime.strptime(rows[0]["time"], "%H:%M:%S")
        t1 = datetime.datetime.strptime(rows[-1]["time"], "%H:%M:%S")
        step = max(1.0, (t1 - t0).total_seconds() / (len(rows) - 1))
    held = {}
    for r, t in zip(rows, temps):
        # Files begun before heat_log.ps1 wrote "limit" carry it without a header.
        why = set(filter(None, (r.get("limit") or r.get(None, [""])[0] or "").split("+")))
        if t >= HOT_C:
            why.add("hot")
        if r["passive_pct"] and int(r["passive_pct"]) < 100:
            why.add("passive")
        if r["throttle"] and int(r["throttle"]) != 0:
            why.add("reasons")
        for w in why:
            held.setdefault(w, []).append(r["time"])
    print("heat %s-%s: %d samples, avg %.0f C, peak %.1f C at %s, %s"
          % (start, end, len(rows), sum(temps) / len(temps), max(temps), peak["time"],
             "warm (90 C+)" if max(temps) >= WARM_C else "under 90 C"))
    if held:
        for w, ts in sorted(held.items()):
            print("  HELD BACK (%s): %d samples, about %.0f s, first %s, last %s"
                  % (w, len(ts), len(ts) * step, ts[0], ts[-1]))
    else:
        print("  not held back (no sample at %.0f C+, passive 100%%, no throttle reason)" % HOT_C)
    seen = {g.strip().rsplit(" ", 1)[0] for r in rows for g in r["godot"].split(";") if g.strip()}
    print("  godot:", "; ".join(sorted(seen)) or "none")
    return 2 if held else 0


if __name__ == "__main__":
    sys.exit(main())
