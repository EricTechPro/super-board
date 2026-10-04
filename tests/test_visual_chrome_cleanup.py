#!/usr/bin/env python3
"""Late Chrome profile writes must not discard a successful DOM result."""
import errno
import os
import shutil
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills/visual/scripts"))
import visual


class ChromeCleanupTests(unittest.TestCase):
    def test_profile_cleanup_race_preserves_output(self):
        rmtree = shutil.rmtree
        popen = subprocess.Popen

        def late_profile_write(path, *, onerror=None, onexc=None, **kwargs):
            try:
                raise OSError(errno.ENOTEMPTY, "Directory not empty", path)
            except OSError as error:
                try:
                    if onexc:
                        onexc(os.rmdir, path, error)
                    else:
                        onerror(os.rmdir, path, sys.exc_info())
                finally:
                    rmtree(path)

        def emit_dom(command, **kwargs):
            return popen([sys.executable, "-c", "print('<html>ready</html>')"], **kwargs)

        with patch("tempfile._shutil.rmtree", side_effect=late_profile_write), \
                patch.object(visual.subprocess, "Popen", side_effect=emit_dom):
            # A real process exits before its profile is cleaned up, just as Chrome does.
            result = visual.chrome("chrome")
        self.assertEqual(result.strip(), "<html>ready</html>")

    def test_launch_errors_are_still_reported(self):
        with self.assertRaises(FileNotFoundError):
            visual.chrome("/no-such-chrome-binary")


if __name__ == "__main__":
    unittest.main()
