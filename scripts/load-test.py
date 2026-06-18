#!/usr/bin/env python3
"""
AeroMed Load Test — concurrent requests to all 6 services simultaneously.

Usage:
  python3 scripts/load-test.py [--duration 60] [--workers 20] [--ramp 5]

Output:
  Per-service table of requests/s, avg latency, p95 latency, error rate.
"""

import argparse
import concurrent.futures
import statistics
import sys
import time
import urllib.error
import urllib.request

SERVICES = {
    "api-gateway":        "http://localhost:5000/api/status",
    "flight-operations":  "http://localhost:5001/api/status",
    "patient-records":    "http://localhost:5002/api/status",
    "medical-equipment":  "http://localhost:5003/api/status",
    "emergency-dispatch": "http://localhost:5004/api/status",
    "aircraft-comms":     "http://localhost:5005/api/status",
}

ANSI = {
    "red":    "\033[0;31m",
    "green":  "\033[0;32m",
    "yellow": "\033[1;33m",
    "cyan":   "\033[0;36m",
    "bold":   "\033[1m",
    "reset":  "\033[0m",
}

def c(colour: str, text: str) -> str:
    if sys.stdout.isatty():
        return f"{ANSI[colour]}{text}{ANSI['reset']}"
    return text


class ServiceStats:
    def __init__(self, name: str):
        self.name = name
        self.latencies: list[float] = []
        self.errors: int = 0
        self.lock = None  # assigned later (avoids import-time threading dependency)

    def record(self, latency_ms: float, ok: bool) -> None:
        self.latencies.append(latency_ms)
        if not ok:
            self.errors += 1

    @property
    def total(self) -> int:
        return len(self.latencies)

    @property
    def ok_count(self) -> int:
        return self.total - self.errors

    def avg_ms(self) -> float:
        return statistics.mean(self.latencies) if self.latencies else 0.0

    def p95_ms(self) -> float:
        if not self.latencies:
            return 0.0
        s = sorted(self.latencies)
        idx = max(0, int(len(s) * 0.95) - 1)
        return s[idx]

    def p99_ms(self) -> float:
        if not self.latencies:
            return 0.0
        s = sorted(self.latencies)
        idx = max(0, int(len(s) * 0.99) - 1)
        return s[idx]

    def error_rate(self) -> float:
        return (self.errors / self.total * 100) if self.total else 0.0

    def rps(self, duration: float) -> float:
        return self.total / duration if duration > 0 else 0.0


def hit(url: str, timeout: float = 5.0) -> tuple[int, float]:
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            resp.read()
            return resp.status, (time.perf_counter() - t0) * 1000
    except urllib.error.HTTPError as e:
        return e.code, (time.perf_counter() - t0) * 1000
    except Exception:
        return 0, (time.perf_counter() - t0) * 1000


def run_load_test(duration: int, workers: int, ramp: int) -> dict[str, ServiceStats]:
    import threading

    stats: dict[str, ServiceStats] = {name: ServiceStats(name) for name in SERVICES}
    for s in stats.values():
        s.lock = threading.Lock()

    deadline = time.time() + duration
    ramp_end = time.time() + ramp

    def worker_loop() -> None:
        urls = list(SERVICES.items())
        idx = 0
        while time.time() < deadline:
            # Ramp: initially sleep to avoid cold-start thundering herd
            if time.time() < ramp_end:
                time.sleep(0.05)
            name, url = urls[idx % len(urls)]
            idx += 1
            code, ms = hit(url)
            ok = 200 <= code < 400
            with stats[name].lock:
                stats[name].record(ms, ok)

    print(c("cyan", c("bold", "\n  AeroMed Load Test Starting")))
    print(f"  Duration: {duration}s | Workers: {workers} | Ramp: {ramp}s")
    print(f"  Targets:  {len(SERVICES)} services\n")

    start = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futs = [pool.submit(worker_loop) for _ in range(workers)]

        # Progress ticker
        tick = 0
        while time.time() < deadline:
            elapsed = time.time() - start
            total_req = sum(s.total for s in stats.values())
            total_err = sum(s.errors for s in stats.values())
            overall_rps = total_req / elapsed if elapsed > 0 else 0
            pct = int(elapsed / duration * 40)
            bar = "█" * pct + "░" * (40 - pct)
            print(
                f"\r  [{bar}] {elapsed:4.0f}/{duration}s  "
                f"req={total_req:5d}  rps={overall_rps:5.1f}  err={total_err}",
                end="",
                flush=True,
            )
            time.sleep(0.5)
            tick += 1

        for fut in futs:
            try:
                fut.result(timeout=2)
            except Exception:
                pass

    actual_duration = time.time() - start
    print(f"\r  {'█'*40}  Done ({actual_duration:.1f}s)          \n")
    return stats, actual_duration


def print_report(stats: dict[str, ServiceStats], duration: float) -> None:
    W = [28, 8, 10, 10, 10, 8, 10]
    headers = ["Service", "Req/s", "Avg (ms)", "p95 (ms)", "p99 (ms)", "Errors", "Error %"]
    sep = "─" * (sum(W) + len(W) * 3 + 1)

    print(c("bold", f"  {sep}"))
    row = "  │"
    for h, w in zip(headers, W):
        row += f" {h:<{w}} │"
    print(c("bold", row))
    print(c("bold", f"  {sep}"))

    total_req = 0
    total_err = 0
    for name, s in stats.items():
        rps   = s.rps(duration)
        avg   = s.avg_ms()
        p95   = s.p95_ms()
        p99   = s.p99_ms()
        errs  = s.errors
        epct  = s.error_rate()
        total_req += s.total
        total_err += errs

        # Colour error rate
        epct_str = f"{epct:.1f}%"
        if epct > 5:
            epct_str = c("red", epct_str)
        elif epct > 0:
            epct_str = c("yellow", epct_str)
        else:
            epct_str = c("green", epct_str)

        # Colour avg latency
        avg_str = f"{avg:.1f}"
        if avg > 2000:
            avg_str = c("red", avg_str)
        elif avg > 500:
            avg_str = c("yellow", avg_str)
        else:
            avg_str = c("green", avg_str)

        vals = [name, f"{rps:.1f}", avg_str, f"{p95:.1f}", f"{p99:.1f}", str(errs), epct_str]
        row = "  │"
        for v, w in zip(vals, W):
            # Strip ANSI for width calc
            plain = v
            for code in ANSI.values():
                plain = plain.replace(code, "")
            pad = w - len(plain)
            row += f" {v}{' ' * max(0, pad)} │"
        print(row)

    print(c("bold", f"  {sep}"))

    overall_rps = total_req / duration if duration > 0 else 0
    overall_err = (total_err / total_req * 100) if total_req else 0
    print(f"\n  {c('bold', 'Summary')}")
    print(f"    Total requests:  {total_req}")
    print(f"    Overall req/s:   {overall_rps:.1f}")
    print(f"    Total errors:    {total_err}")
    print(f"    Overall error %: {overall_err:.2f}%")
    print(f"    Duration:        {duration:.1f}s")
    print()

    if overall_err < 0.1 and overall_rps > 0:
        print(c("green", c("bold", "  RESULT: PASS — platform handled load with <0.1% errors\n")))
    elif overall_err < 5:
        print(c("yellow", c("bold", f"  RESULT: DEGRADED — {overall_err:.1f}% error rate under load\n")))
    else:
        print(c("red", c("bold", f"  RESULT: FAIL — {overall_err:.1f}% error rate exceeds 5% SLO\n")))


def main() -> None:
    parser = argparse.ArgumentParser(description="AeroMed load test")
    parser.add_argument("--duration", type=int, default=60, help="Test duration in seconds (default: 60)")
    parser.add_argument("--workers",  type=int, default=20, help="Concurrent worker threads (default: 20)")
    parser.add_argument("--ramp",     type=int, default=5,  help="Ramp-up period in seconds (default: 5)")
    parser.add_argument("--url",      type=str, default=None, help="Override all targets with a single URL")
    args = parser.parse_args()

    if args.url:
        SERVICES.clear()
        SERVICES["custom-target"] = args.url

    # Quick pre-flight: check at least one service is up
    print(c("cyan", "\n  Pre-flight check..."))
    reachable = 0
    for name, url in SERVICES.items():
        code, ms = hit(url, timeout=3)
        if code == 200:
            print(f"  {c('green', '✓')}  {name:<28} {ms:.0f}ms")
            reachable += 1
        else:
            print(f"  {c('red', '✗')}  {name:<28} HTTP {code}")

    if reachable == 0:
        print(c("red", "\n  No services reachable. Is the stack running?"))
        print("  Run: ./scripts/start.sh\n")
        sys.exit(1)

    print(f"\n  {reachable}/{len(SERVICES)} services reachable — starting load test\n")

    stats, actual_duration = run_load_test(args.duration, args.workers, args.ramp)
    print_report(stats, actual_duration)


if __name__ == "__main__":
    main()
