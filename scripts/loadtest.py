#!/usr/bin/env python3
"""Load test for the Home feed and AI search. Run it through scripts/loadtest.sh.

Talks to a private load-test server (UITEST_HOOKS=1 LOAD_TEST=1, loopback
only): makes qa_ui_ accounts through the /api/test hooks, sends the load,
prints response times per step, and always deletes the run's accounts.
Standard library only.
"""
import json
import os
import random
import secrets
import string
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

BASE = os.environ["LOADTEST_SERVER"].rstrip("/")
TOKEN = os.environ["LOADTEST_TOKEN"]

FEED_STEPS = [int(x) for x in os.environ.get("LOADTEST_FEED_USERS", "10,25,50").split(",")]
FEED_SECONDS = float(os.environ.get("LOADTEST_FEED_SECONDS", "30"))
SEARCH_STEPS = [int(x) for x in os.environ.get("LOADTEST_SEARCH_USERS", "1,2,4,8").split(",")]
SEARCHES_EACH = int(os.environ.get("LOADTEST_SEARCHES_EACH", "3"))
TIMEOUT = 120

HOBBIES = ["woodworking", "beekeeping", "photography", "badminton", "chess", "pottery", "hiking",
           "guitar", "baking", "cycling", "painting", "running", "board games", "gardening",
           "swimming", "film photography", "calligraphy", "yoga", "rock climbing", "coffee brewing"]
PLACES = ["in District 1", "in Thu Duc", "near Landmark 81", "in Binh Thanh", "in Go Vap",
          "in District 7", "near me", "in Tan Binh", "in Phu Nhuan", ""]


def request(method, path, body=None, bearer=None, hooks=False):
    """(status, seconds, parsed JSON or None). Never raises for HTTP errors."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if bearer:
        req.add_header("Authorization", f"Bearer {bearer}")
    if hooks:
        req.add_header("X-UITest-Token", TOKEN)
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            raw = resp.read()
            status = resp.status
    except urllib.error.HTTPError as e:
        raw, status = e.read(), e.code
    except Exception:  # connection reset, timeout
        return 0, time.perf_counter() - start, None
    elapsed = time.perf_counter() - start
    try:
        return status, elapsed, json.loads(raw) if raw else None
    except ValueError:
        return status, elapsed, None


def make_accounts(run, n):
    accounts = []
    while len(accounts) < n:
        count = min(5, n - len(accounts))
        interests = random.sample(["Woodworking", "Beekeeping", "Photography", "Chess", "Hiking", "Guitar"], 2)
        status, _, body = request("POST", "/api/test/users", {
            "run_id": run, "count": count,
            "bio": f"Loves {interests[0].lower()} and {interests[1].lower()} on weekends.",
            "interests": interests,
        }, hooks=True)
        if status != 200:
            sys.exit(f"Creating test accounts failed: HTTP {status} {body}")
        accounts += body
    return accounts


def report(label, results, wall):
    times = sorted(t for s, t in results if s == 200)
    errors = sum(1 for s, _ in results if s != 200)
    codes = sorted({s for s, _ in results if s != 200})

    def pct(p):
        return times[min(len(times) - 1, int(round(p / 100 * (len(times) - 1))))] * 1000 if times else float("nan")

    rps = len(results) / wall if wall else 0
    err = f"{errors} ({100 * errors / len(results):.1f}%)" if results else "0"
    if codes:
        err += f" codes {codes}"
    print(f"  {label:<12} {len(results):>6} req  {rps:>7.1f} req/s  "
          f"p50 {pct(50):>7.0f} ms  p95 {pct(95):>7.0f} ms  p99 {pct(99):>7.0f} ms  "
          f"max {(times[-1] * 1000 if times else float('nan')):>7.0f} ms  errors {err}", flush=True)


def feed_step(accounts, users):
    results, lock = [], threading.Lock()
    stop = time.perf_counter() + FEED_SECONDS

    def worker(acc):
        while time.perf_counter() < stop:
            status, t, _ = request("GET", "/api/feed/recommendations?mode=hobby&limit=20", bearer=acc["token"])
            with lock:
                results.append((status, t))

    start = time.perf_counter()
    with ThreadPoolExecutor(max_workers=users) as pool:
        for i in range(users):
            pool.submit(worker, accounts[i % len(accounts)])
    report(f"{users} users", results, time.perf_counter() - start)


def search_step(accounts, users, cached):
    results, lock = [], threading.Lock()
    fixed = "friends who love woodworking and beekeeping"

    def query():
        if cached:
            return fixed
        # A fresh combination plus a word the cache hasn't seen, so the query
        # parser (Ollama) runs every time.
        word = "".join(random.choices(string.ascii_lowercase, k=5))
        return f"people who enjoy {random.choice(HOBBIES)} {random.choice(PLACES)} {word}".strip()

    def worker(acc):
        for _ in range(SEARCHES_EACH):
            status, t, _ = request("POST", "/api/search/ai", {"query": query(), "mode": "hobby"}, bearer=acc["token"])
            with lock:
                results.append((status, t))

    if cached:  # warm the cache once, outside the measurement
        request("POST", "/api/search/ai", {"query": fixed, "mode": "hobby"}, bearer=accounts[0]["token"])
    start = time.perf_counter()
    with ThreadPoolExecutor(max_workers=users) as pool:
        for i in range(users):
            pool.submit(worker, accounts[i % len(accounts)])
    report(f"{users} at once", results, time.perf_counter() - start)


def main():
    run = "".join(secrets.choice(string.ascii_lowercase + string.digits) for _ in range(8))
    needed = max(FEED_STEPS + SEARCH_STEPS)
    print(f"Run {run}: making {needed} test accounts…", flush=True)
    try:
        accounts = make_accounts(run, needed)
        status, t, _ = request("POST", f"/api/test/runs/{run}/embed", hooks=True)
        print(f"Embedded the test accounts for search (HTTP {status}, {t:.1f} s)")

        print(f"\nHome feed: GET /api/feed/recommendations, {FEED_SECONDS:.0f} s per step, "
              f"each user requesting back to back")
        for users in FEED_STEPS:
            feed_step(accounts, users)

        print(f"\nAI search, new queries (the query parser runs on Ollama each time), "
              f"{SEARCHES_EACH} searches per user")
        for users in SEARCH_STEPS:
            search_step(accounts, users, cached=False)

        print(f"\nAI search, one repeated query (its parse comes from the 24 h cache), "
              f"{SEARCHES_EACH} searches per user")
        for users in SEARCH_STEPS:
            search_step(accounts, users, cached=True)
    finally:
        status, _, body = request("DELETE", f"/api/test/runs/{run}", hooks=True)
        users = body.get("users") if isinstance(body, dict) else "?"
        print(f"\nDeleted run {run}: HTTP {status}, {users} accounts")


if __name__ == "__main__":
    main()
