"""The in-app log reader must not grow memory or CPU with log volume.

With Debug Trace on, Wine writes faster than LogTail reads, so its read loop
never returns and the GCD queue's autorelease pool never drains. Each line's
Foundation bridging left ~5 small objects behind; Kincaid and a Unity game were
killed by iOS at ~4.2 GB after ~3 minutes. Removing each line from the front of
the buffer also kept that queue near 100% CPU.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "testrepos/Madeira/app/Madeira"


def function_body(source, signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for i in range(brace, len(source)):
        if source[i] == "{":
            depth += 1
        elif source[i] == "}":
            depth -= 1
            if depth == 0:
                return source[brace:i + 1]
    raise AssertionError("unbalanced braces after " + signature)


class LogTailMemoryTests(unittest.TestCase):
    def test_read_loop_drains_an_autorelease_pool_per_chunk(self):
        tail = (APP / "LogTail.swift").read_text()
        body = function_body(tail, "private func readAvailable()")
        loop = function_body(body, "while true")
        self.assertIn("autoreleasepool", loop)
        pool = function_body(loop, "autoreleasepool")
        self.assertIn("read(fd", pool)
        self.assertIn("flushLines()", pool)

    def test_lines_are_not_removed_one_at_a_time(self):
        tail = (APP / "LogTail.swift").read_text()
        body = function_body(tail, "private func flushLines()")
        loop = function_body(body, "while let nlIdx")
        self.assertNotIn("removeSubrange", loop)
        self.assertEqual(len(re.findall(r"removeSubrange", body)), 1)

    def test_callback_lines_from_wine_threads_use_a_pool(self):
        store = (APP / "LogStore.swift").read_text()
        body = function_body(store, "private func handleRawLine(_ raw: String)")
        self.assertIn("autoreleasepool", body)
        self.assertIn("handleRawLineInPool(raw)", body)
        self.assertIn("private func handleRawLineInPool(_ raw: String)", store)


if __name__ == "__main__":
    unittest.main()
