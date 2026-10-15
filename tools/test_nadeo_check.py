import contextlib
import io
import os
from unittest import TestCase, mock

import check_nadeo_discovery


class ServiceAccountCheckTests(TestCase):
    def test_console_check_leaks_no_login_or_password(self):
        out = io.StringIO()
        with (mock.patch("builtins.input", return_value="pmchakymi"),
              mock.patch.object(check_nadeo_discovery, "read_hidden", return_value="private-test-password"),
              mock.patch.object(check_nadeo_discovery, "fetch_official", return_value=[
                  {"type": "totd", "releaseAt": "2026-10-15T19:00:00Z"}]),
              contextlib.redirect_stdout(out)):
            self.assertEqual(check_nadeo_discovery.main(), 0)
        self.assertIn("1 TOTD", out.getvalue())
        self.assertIn("Contrôle Nadeo v2", out.getvalue())
        self.assertNotIn("pmchakymi", out.getvalue())
        self.assertNotIn("private-test-password", out.getvalue())
        self.assertNotIn("PM_NADEO_SERVICE_PASSWORD", os.environ)

    def test_unexpected_exception_body_is_not_logged(self):
        out = io.StringIO()
        with (mock.patch("builtins.input", return_value="pmchakymi"),
              mock.patch.object(check_nadeo_discovery, "read_hidden", return_value="private-test-password"),
              mock.patch.object(check_nadeo_discovery, "fetch_official", side_effect=RuntimeError("private-test-password")),
              contextlib.redirect_stdout(out)):
            self.assertEqual(check_nadeo_discovery.main(), 1)
        self.assertIn("RuntimeError", out.getvalue())
        self.assertNotIn("private-test-password", out.getvalue())

    def test_known_validation_stage_is_logged_without_body(self):
        out = io.StringIO()
        with (mock.patch("builtins.input", return_value="pmchakymi"),
              mock.patch.object(check_nadeo_discovery, "read_hidden", return_value="private-test-password"),
              mock.patch.object(check_nadeo_discovery, "fetch_official", side_effect=ValueError("Nadeo listes officielles incompatibles (validation:totd-uid-horaire)")),
              contextlib.redirect_stdout(out)):
            self.assertEqual(check_nadeo_discovery.main(), 1)
        self.assertIn("(validation:totd-uid-horaire)", out.getvalue())
        self.assertNotIn("private-test-password", out.getvalue())

    def test_fictitious_paste_without_real_password(self):
        out = io.StringIO()
        with (mock.patch("sys.argv", ["check_nadeo_discovery.py", "--test-paste"]),
              mock.patch.object(check_nadeo_discovery, "read_hidden", return_value="PM-COLLER-123"),
              mock.patch.object(check_nadeo_discovery, "fetch_official", side_effect=AssertionError("must not call network")),
              contextlib.redirect_stdout(out)):
            self.assertEqual(check_nadeo_discovery.main(), 0)
        self.assertIn("Collage masqué OK", out.getvalue())

    def test_live_401_probes_core_without_leaking_secret(self):
        out = io.StringIO()
        with (mock.patch("builtins.input", return_value="pmchakymi"),
              mock.patch.object(check_nadeo_discovery, "read_hidden", return_value="private-test-password"),
              mock.patch.object(check_nadeo_discovery, "fetch_official", side_effect=ValueError("Nadeo HTTP 401 (authentification)")),
              mock.patch.object(check_nadeo_discovery, "request_token", return_value="private-test-token") as probe,
              contextlib.redirect_stdout(out)):
            self.assertEqual(check_nadeo_discovery.main(), 1)
        probe.assert_called_once_with("pmchakymi", "private-test-password", "NadeoServices")
        self.assertIn("audience Live refusée", out.getvalue())
        self.assertNotIn("private-test-password", out.getvalue())
        self.assertNotIn("private-test-token", out.getvalue())

    def test_windows_line_input_restores_console_echo(self):
        import ctypes
        from ctypes import wintypes
        console = mock.Mock()
        console.GetStdHandle.return_value = 123
        console.SetConsoleMode.return_value = True
        def get_mode(handle, value):
            self.assertEqual(handle, 123)
            value._obj.value = 0x17  # processed + line + echo + mouse input
            return True
        console.GetConsoleMode.side_effect = get_mode
        out = io.StringIO()
        with (mock.patch.object(check_nadeo_discovery.os, "name", "nt"),
              mock.patch.object(ctypes, "WinDLL", return_value=console, create=True),
              mock.patch("builtins.input", return_value="PM-COLLER-123"),
              contextlib.redirect_stdout(out)):
            self.assertEqual(check_nadeo_discovery.read_hidden("Prompt: "), "PM-COLLER-123")
        self.assertEqual(console.SetConsoleMode.call_count, 2)
        self.assertEqual(console.SetConsoleMode.call_args_list[0].args[1] & 0x04, 0)
        self.assertEqual(console.SetConsoleMode.call_args_list[1].args[1], 0x17)
