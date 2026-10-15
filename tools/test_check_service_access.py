import contextlib
import io
from pathlib import Path
from unittest import TestCase, mock

import check_world_service_access as checker


class ServiceAccessTests(TestCase):
    def test_private_env_parser_only_accepts_expected_keys(self):
        fake = mock.Mock(spec=Path)
        fake.read_text.return_value = ('GEMINI_API_KEY=private-other\nSUPABASE_URL="https://example.supabase.co"\n'
                                       'SUPABASE_SECRET_KEY="sb_secret_private-test"\n')
        self.assertEqual(checker.private_config(fake), {
            "SUPABASE_URL": "https://example.supabase.co", "SUPABASE_SECRET_KEY": "sb_secret_private-test"})

    def test_check_never_posts_or_logs_server_key(self):
        store = mock.Mock()
        store.request.side_effect = [[], {"schema": 3, "version": 5, "maps": {}}]
        output = io.StringIO()
        with (mock.patch("sys.argv", ["check_world_service_access.py"]),
              mock.patch.dict("os.environ", {"SUPABASE_URL": "https://example.supabase.co",
                                         "SUPABASE_SECRET_KEY": "sb_secret_private-test"}),
              mock.patch.object(checker, "Store", return_value=store),
              contextlib.redirect_stdout(output)):
            checker.main()
        self.assertEqual([c.args[0] for c in store.request.call_args_list],
                         ["map_medals?select=map_uid,status&limit=1", "rpc/pm_public_catalog"])
        self.assertNotIn("sb_secret_private-test", output.getvalue())

    def test_github_secret_transfer_uses_stdin_not_command_line(self):
        store = mock.Mock()
        store.request.side_effect = [[], {"schema": 3, "version": 5, "maps": {}}]
        result = mock.Mock(returncode=0)
        output = io.StringIO()
        with (mock.patch("sys.argv", ["check_world_service_access.py", "--configure-github"]),
              mock.patch.dict("os.environ", {"SUPABASE_URL": "https://mfopepdzllvyefwnxvqh.supabase.co",
                                         "SUPABASE_SECRET_KEY": "sb_secret_private-test"}),
              mock.patch.object(checker, "Store", return_value=store),
              mock.patch.object(checker.subprocess, "run", return_value=result) as upload,
              contextlib.redirect_stdout(output)):
            checker.main()
        calls = upload.call_args_list
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[1].kwargs["input"], "sb_secret_private-test")
        self.assertNotIn("sb_secret_private-test", str(calls[1].args))
        self.assertNotIn("sb_secret_private-test", output.getvalue())
