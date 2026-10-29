#!/usr/bin/env python3
"""Focused regression tests for wait_for_run_output (Hermes run polling).

Covers the Hermes API shape change: current Hermes returns
{"status": "completed", "output": ...} with no `completed` boolean, while
older versions also set "completed": true. Both shapes must yield the output;
non-completed terminal states must return None.

Run: python3 -m unittest discover -s backend -v
Stdlib only, no network — urlopen and sleep are mocked.
"""

import json
import unittest
from unittest import mock

import server


class _FakeResponse:
    def __init__(self, payload):
        self._body = json.dumps(payload).encode()

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def _urlopen_replaying(payloads):
    """urlopen stand-in: yields payloads in order, then keeps replaying the last."""
    it = iter(payloads)
    last = payloads[-1]

    def fake_urlopen(req, timeout=None):
        nonlocal last
        try:
            last = next(it)
        except StopIteration:
            pass
        return _FakeResponse(last)

    return fake_urlopen


class WaitForRunOutputTests(unittest.TestCase):
    def _poll(self, payloads):
        with mock.patch("urllib.request.urlopen", side_effect=_urlopen_replaying(payloads)), \
             mock.patch("time.sleep", lambda *_: None):
            return server.wait_for_run_output("run_test")

    def test_status_completed_without_boolean_field(self):
        # Current Hermes shape: status only, no `completed` key.
        out = self._poll([{"status": "completed", "output": "Erledigt."}])
        self.assertEqual(out, "Erledigt.")

    def test_legacy_completed_boolean_still_works(self):
        out = self._poll([{"status": "completed", "completed": True, "output": "hi"}])
        self.assertEqual(out, "hi")

    def test_running_then_status_completed(self):
        out = self._poll([
            {"status": "running"},
            {"status": "completed", "output": "done"},
        ])
        self.assertEqual(out, "done")

    def test_failed_run_returns_none(self):
        self.assertIsNone(self._poll([{"status": "failed", "error": "boom"}]))

    def test_cancelled_run_returns_none(self):
        self.assertIsNone(self._poll([{"status": "cancelled"}]))

    def test_completed_with_empty_output_returns_none(self):
        self.assertIsNone(self._poll([{"status": "completed", "output": "  "}]))


if __name__ == "__main__":
    unittest.main()
