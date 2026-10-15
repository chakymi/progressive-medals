import contextlib
import io
from unittest import TestCase, mock

import configure_nadeo_github as setup


class GitHubCredentialsTests(TestCase):
    def test_secrets_go_through_stdin_only(self):
        output = io.StringIO()
        result = mock.Mock(returncode=0)
        with (mock.patch.object(setup, "read_hidden", side_effect=["pm-test", "private-test-password"]),
              mock.patch.object(setup.subprocess, "run", return_value=result) as run,
              contextlib.redirect_stdout(output)):
            self.assertEqual(setup.main(), 0)
        self.assertEqual(len(run.call_args_list), 2)
        self.assertEqual(run.call_args_list[1].kwargs["input"], "private-test-password")
        for call in run.call_args_list:
            self.assertNotIn("private-test-password", str(call.args))
        self.assertNotIn("private-test-password", output.getvalue())
        self.assertIn("heure UTC encore absente", output.getvalue())
