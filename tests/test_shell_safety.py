import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BASH = Path("/bin/bash")
SHELL_FILES = [
    ROOT / "install.sh",
    ROOT / "uninstall.sh",
    ROOT / "bin" / "xst",
    ROOT / "bin" / "claude-xst",
    ROOT / "bin" / "claude-xst-aware",
    ROOT / "lib" / "common.sh",
    ROOT / "scripts" / "capture-sub-url.sh",
    ROOT / "scripts" / "release.sh",
    ROOT / "tests" / "run.sh",
]


def run_bash(script, env=None, timeout=10):
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    return subprocess.run(
        [str(BASH), "-c", script],
        cwd=str(ROOT),
        env=merged_env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
    )


class ShellCompatibilityTests(unittest.TestCase):
    def test_all_shell_entrypoints_pass_bash_syntax_check(self):
        for path in SHELL_FILES:
            with self.subTest(path=path.relative_to(ROOT)):
                result = subprocess.run(
                    [str(BASH), "-n", str(path)],
                    cwd=str(ROOT),
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=10,
                )
                self.assertEqual(
                    result.returncode,
                    0,
                    "%s:\n%s" % (path.relative_to(ROOT), result.stderr),
                )

    def test_shell_code_avoids_known_bash_4_only_features(self):
        forbidden = ("declare -A", "mapfile", "readarray")
        for path in SHELL_FILES:
            source = path.read_text(encoding="utf-8")
            with self.subTest(path=path.relative_to(ROOT)):
                for token in forbidden:
                    self.assertNotIn(token, source)
                self.assertNotRegex(source, r"\$\{[^}\n]*,,[^}\n]*\}")
                self.assertNotRegex(source, r"\$\{[^}\n]*\^\^[^}\n]*\}")

    def test_launchagent_template_is_valid_plist(self):
        template = ROOT / "templates" / "launchagent.plist.template"
        parsed = plistlib.loads(template.read_bytes())

        self.assertEqual(parsed["Label"], "__LABEL__")
        self.assertEqual(parsed["ProgramArguments"][0], "__XRAY_BIN__")
        self.assertIn("__CONFIG__", parsed["ProgramArguments"])
        self.assertTrue(parsed["RunAtLoad"])
        self.assertTrue(parsed["KeepAlive"])

    @unittest.skipUnless(sys.platform == "darwin", "plutil is a macOS check")
    def test_launchagent_template_passes_macos_plutil(self):
        result = subprocess.run(
            ["plutil", "-lint", str(ROOT / "templates" / "launchagent.plist.template")],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )
        self.assertEqual(
            result.returncode,
            0,
            "stdout:\n%s\nstderr:\n%s" % (result.stdout, result.stderr),
        )


class CommonShellSafetyTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.home = self.tmp / "home"
        self.state = self.home / ".config" / "xray-split-tunnel"
        self.stub_bin = self.tmp / "bin"
        self.home.mkdir()
        self.state.mkdir(parents=True)
        self.state.chmod(0o700)
        self.stub_bin.mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    def shell_env(self):
        return {
            "HOME": str(self.home),
            "XST_HOME": str(self.state),
            "XST_ROOT": str(ROOT),
            "PATH": str(self.stub_bin) + os.pathsep + os.environ.get("PATH", ""),
        }

    def test_fetch_rejects_non_https_url_before_invoking_curl(self):
        marker = self.tmp / "curl-was-called"
        url_file = self.tmp / "invalid-url"
        url_file.write_text(
            "http://127.0.0.1:1/not-a-subscription\n", encoding="utf-8"
        )
        url_file.chmod(0o600)
        curl = self.stub_bin / "curl"
        curl.write_text(
            "#!/bin/sh\n"
            ': > "${XST_TEST_CURL_MARKER:?}"\n'
            "exit 0\n",
            encoding="utf-8",
        )
        curl.chmod(0o755)
        env = self.shell_env()
        env.update(
            {
                "XST_TEST_CURL_MARKER": str(marker),
                "XST_TEST_URL_FILE": str(url_file),
                "XST_TEST_DST": str(self.state / "subscription.json"),
            }
        )

        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            'xst_read_secret_url_file "$XST_TEST_URL_FILE" subscription_url\n'
            'xst_fetch_subscription "$subscription_url" "$XST_TEST_DST"',
            env,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists(), "curl must not see a rejected URL")

    def test_https_url_validator_rejects_userinfo_whitespace_and_control_data(self):
        env = self.shell_env()
        for value in (
            "https://user:password@example.invalid/path",
            "https://example.invalid/path with-space",
            "https://example.invalid/path\nnext",
            "http://example.invalid/path",
        ):
            with self.subTest(value=value):
                env["XST_TEST_URL"] = value
                result = run_bash(
                    'source "$XST_ROOT/lib/common.sh"\n'
                    'printf "%s" "$XST_TEST_URL" | xst_validate_https_url',
                    env,
                )
                self.assertNotEqual(result.returncode, 0)

        env["XST_TEST_URL"] = "https://example.invalid/path?token=fixture"
        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            'printf "%s" "$XST_TEST_URL" | xst_validate_https_url',
            env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_bypass_file_is_data_only_and_values_are_not_exported(self):
        bypass_file = self.tmp / "bypass.env"
        bypass_file.write_text(
            "BYPASS_DOMAINS=corp.example.invalid,.lab.example.invalid\n"
            "BYPASS_CIDRS=100.64.0.0/10,2001:db8:abcd::/48\n",
            encoding="utf-8",
        )
        bypass_file.chmod(0o600)
        env = self.shell_env()
        env["XST_TEST_BYPASS_FILE"] = str(bypass_file)
        result = run_bash(
            'export BYPASS_DOMAINS="inherited.secret.invalid"\n'
            'export BYPASS_CIDRS="203.0.113.0/24"\n'
            'source "$XST_ROOT/lib/common.sh"\n'
            'xst_read_bypass_file "$XST_TEST_BYPASS_FILE"\n'
            'xst_validate_settings 0\n'
            'test "$BYPASS_DOMAINS" = "corp.example.invalid,lab.example.invalid"\n'
            'test "$BYPASS_CIDRS" = "100.64.0.0/10,2001:db8:abcd::/48"\n'
            'if /usr/bin/env | grep -q "^BYPASS_"; then exit 90; fi',
            env,
        )

        self.assertEqual(result.returncode, 0, result.stderr)

        bypass_file.write_text(
            "BYPASS_DOMAINS=corp.example.invalid\nUNKNOWN=value\n",
            encoding="utf-8",
        )
        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            'xst_read_bypass_file "$XST_TEST_BYPASS_FILE"',
            env,
        )
        self.assertNotEqual(result.returncode, 0)

    def test_installer_rejects_secret_environment_before_child_process(self):
        marker = self.tmp / "dirname-was-called"
        dirname = self.stub_bin / "dirname"
        dirname.write_text(
            "#!/bin/sh\n"
            ': > "${XST_TEST_CHILD_MARKER:?}"\n'
            "exit 99\n",
            encoding="utf-8",
        )
        dirname.chmod(0o755)
        env = self.shell_env()
        env.update(
            {
                "XST_BYPASS_DOMAINS": "confidential.example.invalid",
                "XST_TEST_CHILD_MARKER": str(marker),
            }
        )

        result = subprocess.run(
            [str(BASH), str(ROOT / "install.sh"), "--dry-run"],
            cwd=str(ROOT),
            env={**os.environ, **env},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("XST_BYPASS_FILE", result.stderr)
        self.assertFalse(marker.exists())

    def test_installer_rejects_empty_claude_command_flags(self):
        for variable in ("XST_CLAUDE_COMMAND", "XST_CLAUDE_AWARE_COMMAND"):
            with self.subTest(variable=variable):
                env = self.shell_env()
                env.update({"XST_ZSHRC": "0", variable: ""})
                result = subprocess.run(
                    [
                        str(BASH),
                        str(ROOT / "install.sh"),
                        "--non-interactive",
                    ],
                    cwd=str(ROOT),
                    env={**os.environ, **env},
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=10,
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("%s должен быть 0 или 1" % variable, result.stderr)

    def test_agent_capture_sub_url_uses_gui_and_protects_secret(self):
        secret = "https://provider.example.invalid/fixture-subscription-token"
        osascript_called = self.tmp / "osascript-called"
        osascript_argv = self.tmp / "osascript-argv"
        uname = self.stub_bin / "uname"
        uname.write_text("#!/bin/sh\nprintf 'Darwin\\n'\n", encoding="utf-8")
        uname.chmod(0o755)
        osascript = self.stub_bin / "osascript"
        osascript.write_text(
            "#!/bin/sh\n"
            ': > "${XST_TEST_OSASCRIPT_CALLED:?}"\n'
            'printf "%s\\n" "$@" > "${XST_TEST_OSASCRIPT_ARGV:?}"\n'
            "printf '%s\\n' 'https://provider.example.invalid/fixture-subscription-token'\n",
            encoding="utf-8",
        )
        osascript.chmod(0o755)
        env = self.shell_env()
        env.update(
            {
                "XST_TEST_OSASCRIPT_CALLED": str(osascript_called),
                "XST_TEST_OSASCRIPT_ARGV": str(osascript_argv),
            }
        )

        result = subprocess.run(
            [str(BASH), str(ROOT / "scripts" / "capture-sub-url.sh")],
            cwd=str(ROOT),
            env={**os.environ, **env},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(osascript_called.exists())
        self.assertEqual(osascript_argv.read_text(encoding="utf-8"), "\n")
        self.assertNotIn(secret, result.stdout)
        self.assertNotIn(secret, result.stderr)
        sub_url = self.state / "sub-url"
        self.assertEqual(sub_url.read_text(encoding="utf-8"), secret + "\n")
        self.assertEqual(sub_url.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o700)
        self.assertFalse((self.state / ".xst-operation.lock").exists())

        osascript_called.unlink()
        second = subprocess.run(
            [str(BASH), str(ROOT / "scripts" / "capture-sub-url.sh")],
            cwd=str(ROOT),
            env={**os.environ, **env},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertFalse(
            osascript_called.exists(),
            "existing valid sub-url must not open or replace the secret",
        )
        self.assertEqual(sub_url.read_text(encoding="utf-8"), secret + "\n")

    def test_fetch_uses_stdin_config_and_keeps_url_out_of_argv_and_environment(self):
        argv_log = self.tmp / "curl-argv"
        env_log = self.tmp / "curl-env"
        stdin_log = self.tmp / "curl-stdin"
        curlrc_used = self.tmp / "curlrc-was-used"
        curl_home = self.tmp / "curl-home"
        curl_home.mkdir()
        (curl_home / ".curlrc").write_text(
            'url = "https://attacker.invalid/from-curlrc"\n', encoding="utf-8"
        )
        curl = self.stub_bin / "curl"
        curl.write_text(
            "#!/bin/sh\n"
            'if [ "${1:-}" != -q ]; then\n'
            '  : > "${XST_TEST_CURLRC_USED:?}"\n'
            "  exit 91\n"
            "fi\n"
            '/usr/bin/env > "${XST_TEST_CURL_ENV:?}"\n'
            'cat > "${XST_TEST_CURL_STDIN:?}"\n'
            ': > "${XST_TEST_CURL_ARGV:?}"\n'
            'output=""\n'
            'previous=""\n'
            'for argument in "$@"; do\n'
            '  printf "%s\\n" "$argument" >> "$XST_TEST_CURL_ARGV"\n'
            '  if [ "$previous" = -o ]; then output="$argument"; fi\n'
            '  previous="$argument"\n'
            "done\n"
            'printf "{}\\n" > "$output"\n',
            encoding="utf-8",
        )
        curl.chmod(0o755)
        destination = self.state / "download.json"
        secret_url = "https://subscription.example.invalid/connect/fixture-secret"
        url_file = self.tmp / "sub-url"
        url_file.write_text(secret_url + "\n", encoding="utf-8")
        url_file.chmod(0o600)
        env = self.shell_env()
        env.update(
            {
                "XST_TEST_CURL_ARGV": str(argv_log),
                "XST_TEST_CURL_ENV": str(env_log),
                "XST_TEST_CURL_STDIN": str(stdin_log),
                "XST_TEST_CURLRC_USED": str(curlrc_used),
                "XST_TEST_URL_FILE": str(url_file),
                "XST_TEST_DST": str(destination),
                "CURL_HOME": str(curl_home),
            }
        )

        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            'xst_read_secret_url_file "$XST_TEST_URL_FILE" subscription_url\n'
            'export subscription_url\n'
            'export xst_secret_url="$subscription_url"\n'
            'export escaped_url="$subscription_url"\n'
            'xst_read_secret_url_file "$XST_TEST_URL_FILE" subscription_url\n'
            'xst_fetch_subscription "$subscription_url" "$XST_TEST_DST"',
            env,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(destination.exists())
        argv = argv_log.read_text(encoding="utf-8").splitlines()
        child_env = env_log.read_text(encoding="utf-8")
        self.assertEqual(argv[0], "-q", "curl -q must be the first argument")
        config_index = argv.index("--config")
        self.assertEqual(argv[config_index + 1], "-")
        self.assertIn("--max-filesize", argv)
        self.assertIn("--max-time", argv)
        self.assertNotIn(secret_url, "\n".join(argv))
        self.assertNotIn("fixture-secret", "\n".join(argv))
        self.assertNotIn(secret_url, child_env)
        self.assertNotIn("fixture-secret", child_env)
        self.assertEqual(
            stdin_log.read_text(encoding="utf-8"),
            'url = "%s"\n' % secret_url,
        )
        self.assertFalse(
            curlrc_used.exists(), "-q must suppress the malicious CURL_HOME/.curlrc"
        )

    def test_failed_fetch_removes_download_and_cookie_temporaries(self):
        curl_tmp = self.tmp / "curl-tmp"
        curl_tmp.mkdir()
        curl = self.stub_bin / "curl"
        curl.write_text(
            "#!/bin/sh\n"
            "cat >/dev/null\n"
            'output=""\n'
            'previous=""\n'
            'for argument in "$@"; do\n'
            '  if [ "$previous" = -o ]; then output="$argument"; fi\n'
            '  previous="$argument"\n'
            "done\n"
            'printf "partial\\n" > "$output"\n'
            "exit 22\n",
            encoding="utf-8",
        )
        curl.chmod(0o755)
        destination = self.state / "must-not-exist.json"
        url_file = self.tmp / "sub-url-failure"
        url_file.write_text(
            "https://subscription.example.invalid/failure-fixture\n",
            encoding="utf-8",
        )
        url_file.chmod(0o600)
        env = self.shell_env()
        env.update(
            {
                "XST_TEST_URL_FILE": str(url_file),
                "XST_TEST_DST": str(destination),
                "TMPDIR": str(curl_tmp),
            }
        )

        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            'xst_read_secret_url_file "$XST_TEST_URL_FILE" subscription_url\n'
            'xst_fetch_subscription "$subscription_url" "$XST_TEST_DST"',
            env,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.state.glob(".subscription.*")), [])
        self.assertEqual(list(curl_tmp.glob("xst-cookie.*")), [])

    def test_env_parser_never_evaluates_shell_syntax(self):
        marker = self.tmp / "env-injection-ran"
        env_file = self.state / "env"
        env_file.write_text(
            "LABEL=com.xst.xray\n"
            "HTTP_PORT=18080\n"
            "SOCKS_PORT=18081\n"
            'BYPASS_DOMAINS=$(touch "$XST_TEST_MARKER")\n'
            "BYPASS_CIDRS=\n"
            "XRAY_BIN=/bin/echo\n"
            "XRAY_VERSION=fixture\n"
            "EXPORT_HTTPS_PROXY=0\n"
            "SUB_UA=Fixture/1\n"
            "SERVICE_SCOPE=user\n"
            "INSTALL_VERSION=fixture\n"
            "INSTALL_REVISION=fixture\n",
            encoding="utf-8",
        )
        env_file.chmod(0o600)
        env = self.shell_env()
        env["XST_TEST_MARKER"] = str(marker)

        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            "xst_read_env\n"
            'test "$BYPASS_DOMAINS" = \'$(touch "$XST_TEST_MARKER")\'',
            env,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())

    def test_shell_snippet_is_safe_against_command_injection(self):
        marker = self.tmp / "injected-command-ran"
        snippet = self.state / "shell.sh"
        original = '# known-good sentinel\nexport NO_PROXY="localhost"\n'
        snippet.write_text(original, encoding="utf-8")
        env = self.shell_env()
        env.update(
            {
                "XST_TEST_MARKER": str(marker),
                "XST_TEST_DOMAINS": (
                    'bad.example.invalid";touch${IFS}"$XST_TEST_MARKER";#'
                ),
            }
        )

        generated = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            'HTTP_PORT=18080\n'
            'SOCKS_PORT=18081\n'
            'BYPASS_DOMAINS="$XST_TEST_DOMAINS"\n'
            'BYPASS_CIDRS=""\n'
            "EXPORT_HTTPS_PROXY=0\n"
            "xst_write_shell_snippet",
            env,
        )

        self.assertFalse(marker.exists())
        if generated.returncode != 0:
            self.assertEqual(snippet.read_text(encoding="utf-8"), original)
            return

        syntax = subprocess.run(
            [str(BASH), "-n", str(snippet)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )
        self.assertEqual(syntax.returncode, 0, syntax.stderr)
        sourced = run_bash('source "$XST_HOME/shell.sh"', env)
        self.assertEqual(
            sourced.returncode,
            0,
            "generated snippet failed to source:\n%s" % sourced.stderr,
        )
        self.assertFalse(marker.exists(), "generated shell executed input as code")

    def test_shell_snippet_contains_deterministic_bypass_values(self):
        env = self.shell_env()
        generated = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            "HTTP_PORT=18080\n"
            "SOCKS_PORT=18081\n"
            'BYPASS_DOMAINS="corp.example.invalid,.lab.example.invalid"\n'
            'BYPASS_CIDRS="100.64.0.0/10,2001:db8:abcd::/48"\n'
            "EXPORT_HTTPS_PROXY=0\n"
            "xst_write_shell_snippet",
            env,
        )
        self.assertEqual(generated.returncode, 0, generated.stderr)

        env["NO_PROXY"] = "preexisting.example.invalid"
        env["no_proxy"] = "preexisting.example.invalid"
        checked = run_bash(
            'source "$XST_HOME/shell.sh"\n'
            'test "$XST_PROXY_URL" = "http://127.0.0.1:18080"\n'
            'test "$XST_SOCKS_URL" = "socks5://127.0.0.1:18081"\n'
            'test "$NO_PROXY" = '
            '"preexisting.example.invalid,localhost,127.0.0.1,::1,.corp.example.invalid,'
            '.lab.example.invalid,100.64.0.0/10,2001:db8:abcd::/48"',
            env,
        )
        self.assertEqual(checked.returncode, 0, checked.stderr)

    def test_no_proxy_merge_is_idempotent_and_does_not_execute_data(self):
        marker = self.tmp / "no-proxy-injection"
        env = self.shell_env()
        env["XST_TEST_MARKER"] = str(marker)
        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            'managed="localhost,127.0.0.1,.corp.example.invalid"\n'
            'existing=\'127.0.0.1, .legacy.example.invalid,'
            '$(touch "$XST_TEST_MARKER")\'\n'
            'merged="$(xst_merge_no_proxy_values "$managed" "$existing" "$managed")"\n'
            'test "$merged" = \'localhost,127.0.0.1,.corp.example.invalid,'
            '.legacy.example.invalid,$(touch "$XST_TEST_MARKER")\'',
            env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())


class StateSecurityPrimitiveTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.home = self.tmp / "home"
        self.home.mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    def shell_env(self, state):
        env = os.environ.copy()
        env.update(
            {
                "HOME": str(self.home),
                "XST_HOME": str(state),
                "XST_ROOT": str(ROOT),
            }
        )
        return env

    @staticmethod
    def mode(path):
        return path.stat().st_mode & 0o777

    def write_protected(self, path, content="fixture\n"):
        path.write_text(content, encoding="utf-8")
        path.chmod(0o600)

    def test_prepare_accepts_new_and_sub_url_only_state(self):
        fresh = self.home / ".config" / "fresh-xst"
        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            "xst_prepare_state_home\n"
            "xst_audit_state_home",
            self.shell_env(fresh),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.mode(fresh), 0o700)
        self.assertEqual(self.mode(fresh / ".xst-managed"), 0o600)

        provisioned = self.home / ".config" / "provisioned-xst"
        provisioned.mkdir()
        provisioned.chmod(0o700)
        self.write_protected(
            provisioned / "sub-url",
            "https://subscription.example.invalid/local-only-fixture\n",
        )
        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            "xst_prepare_state_home\n"
            "xst_audit_state_home",
            self.shell_env(provisioned),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((provisioned / ".xst-managed").exists())

    def test_prepare_rejects_arbitrary_nonempty_or_weakly_protected_state(self):
        arbitrary = self.home / "arbitrary-state"
        arbitrary.mkdir()
        arbitrary.chmod(0o700)
        self.write_protected(arbitrary / "unrelated")
        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            "xst_prepare_state_home",
            self.shell_env(arbitrary),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((arbitrary / "unrelated").exists())
        self.assertFalse((arbitrary / ".xst-managed").exists())

        weak = self.home / "weak-state"
        weak.mkdir()
        weak.chmod(0o700)
        (weak / "sub-url").write_text(
            "https://subscription.example.invalid/fixture\n", encoding="utf-8"
        )
        (weak / "sub-url").chmod(0o644)
        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            "xst_prepare_state_home",
            self.shell_env(weak),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.mode(weak / "sub-url"), 0o644)
        self.assertFalse((weak / ".xst-managed").exists())

    def test_complete_legacy_state_is_migrated_but_partial_lookalike_is_rejected(self):
        legacy = self.home / "legacy-state"
        legacy.mkdir()
        legacy.chmod(0o700)
        for name in (
            "env",
            "subscription.json",
            "config.json",
            "current-index",
            "active-config.sha256",
            "shell.sh",
        ):
            self.write_protected(legacy / name)
        unproven = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            "xst_prepare_state_home",
            self.shell_env(legacy),
        )
        self.assertNotEqual(unproven.returncode, 0)
        self.assertFalse((legacy / ".xst-managed").exists())
        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            "xst_prepare_state_home 1\n"
            "xst_audit_state_home",
            self.shell_env(legacy),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((legacy / ".xst-managed").exists())

        partial = self.home / "partial-state"
        partial.mkdir()
        partial.chmod(0o700)
        self.write_protected(partial / "env")
        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            "xst_prepare_state_home",
            self.shell_env(partial),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((partial / ".xst-managed").exists())

    def test_managed_audit_includes_applied_env_and_rejects_unknown_entries(self):
        state = self.home / "managed-state"
        state.mkdir()
        state.chmod(0o700)
        self.write_protected(state / ".xst-managed", "xray-split-tunnel:v1\n")
        for name in (
            "env",
            "applied.env",
            "sub-url",
            "subscription.json",
            "config.json",
            "current-index",
            "active-config.sha256",
            "shell.sh",
        ):
            self.write_protected(state / name)
        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            "xst_audit_state_home",
            self.shell_env(state),
        )
        self.assertEqual(result.returncode, 0, result.stderr)

        (state / "applied.env").chmod(0o644)
        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            "xst_audit_state_home",
            self.shell_env(state),
        )
        self.assertNotEqual(result.returncode, 0)
        (state / "applied.env").chmod(0o600)
        self.write_protected(state / "unknown-state")
        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            "xst_audit_state_home",
            self.shell_env(state),
        )
        self.assertNotEqual(result.returncode, 0)

    def test_operation_lock_is_atomic_owned_and_never_auto_removes_unknown_lock(self):
        state = self.home / "locked-state"
        script = (
            'source "$XST_ROOT/lib/common.sh"\n'
            "xst_prepare_state_home\n"
            "xst_acquire_operation_lock\n"
            'first_token="$XST_OPERATION_LOCK_TOKEN"\n'
            'xst_check_operation_lock "$first_token"\n'
            'if xst_acquire_operation_lock; then exit 90; fi\n'
            'test -d "$OPERATION_LOCK_DIR"\n'
            'XST_OPERATION_LOCK_TOKEN="0:0:0:0"\n'
            'if xst_release_operation_lock; then exit 91; fi\n'
            'test -d "$OPERATION_LOCK_DIR"\n'
            'XST_OPERATION_LOCK_TOKEN="$first_token"\n'
            "xst_release_operation_lock\n"
            'test ! -e "$OPERATION_LOCK_DIR"'
        )
        result = run_bash(script, self.shell_env(state))
        self.assertEqual(result.returncode, 0, result.stderr)

        stale = self.home / "stale-lock-state"
        prepared = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            "xst_prepare_state_home",
            self.shell_env(stale),
        )
        self.assertEqual(prepared.returncode, 0, prepared.stderr)
        lock = stale / ".xst-operation.lock"
        lock.mkdir()
        lock.chmod(0o700)
        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            "xst_acquire_operation_lock",
            self.shell_env(stale),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(lock.is_dir(), "unknown/stale lock must remain for manual audit")

    def test_operation_lock_release_masks_signal_between_owner_and_directory(self):
        state = self.home / "release-signal-state"
        script = (
            'source "$XST_ROOT/lib/common.sh"\n'
            "xst_prepare_state_home\n"
            "xst_acquire_operation_lock\n"
            "trap 'exit 77' TERM\n"
            "rm() {\n"
            "  local argument\n"
            '  command rm "$@"\n'
            '  for argument in "$@"; do\n'
            '    if [[ "$argument" == "$OPERATION_LOCK_OWNER_FILE" ]]; then\n'
            '      kill -TERM "$$"\n'
            "    fi\n"
            "  done\n"
            "}\n"
            "xst_release_operation_lock\n"
            "trap -p TERM | grep -q 'exit 77'\n"
            'test -z "$XST_OPERATION_LOCK_TOKEN"\n'
            'test ! -e "$OPERATION_LOCK_DIR"'
        )

        result = run_bash(script, self.shell_env(state))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((state / ".xst-operation.lock").exists())

    def test_prepare_and_lock_claims_fresh_state_before_exposing_marker(self):
        state = self.home / "combined-lock-state"
        script = (
            'source "$XST_ROOT/lib/common.sh"\n'
            "trap 'exit 77' TERM\n"
            "xst_prepare_and_acquire_operation_lock\n"
            'test "$XST_PREPARED_STATE_CREATED" = 1\n'
            'test "$XST_PREPARED_MARKER_CREATED" = 1\n'
            "trap -p TERM | grep -q 'exit 77'\n"
            'test -f "$MANAGED_MARKER"\n'
            'xst_check_operation_lock "$XST_OPERATION_LOCK_TOKEN"\n'
            "xst_state_home_is_initial_layout\n"
            "xst_release_operation_lock\n"
            "xst_audit_state_home"
        )

        result = run_bash(script, self.shell_env(state))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.mode(state), 0o700)
        self.assertEqual(self.mode(state / ".xst-managed"), 0o600)
        self.assertFalse((state / ".xst-operation.lock").exists())


class RuntimeSecurityPrimitiveTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.home = self.tmp / "home"
        self.state = self.home / ".config" / "xray-split-tunnel"
        self.stub_bin = self.tmp / "bin"
        self.home.mkdir()
        self.state.mkdir(parents=True)
        self.stub_bin.mkdir()
        self.xray = self.tmp / "xray"
        self.xray.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.xray.chmod(0o755)
        self.config = self.state / "config.json"
        self.config.write_text("{}\n", encoding="utf-8")

    def tearDown(self):
        self._tmp.cleanup()

    def shell_env(self):
        env = os.environ.copy()
        env.update(
            {
                "HOME": str(self.home),
                "XST_HOME": str(self.state),
                "XST_ROOT": str(ROOT),
                "PATH": str(self.stub_bin)
                + os.pathsep
                + os.environ.get("PATH", ""),
            }
        )
        return env

    def install_process_stubs(self):
        ps = self.stub_bin / "ps"
        ps.write_text(
            "#!/bin/sh\n"
            'case "$*" in\n'
            '  *" uid="*) printf "%s\\n" "${XST_TEST_PROCESS_UID:?}" ;;\n'
            '  *" command="*) printf "%s\\n" "${XST_TEST_PROCESS_COMMAND:?}" ;;\n'
            "  *) exit 2 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        ps.chmod(0o755)
        lsof = self.stub_bin / "lsof"
        lsof.write_text(
            "#!/bin/sh\n"
            'case " $* " in\n'
            '  *" -d txt "*)\n'
            '    printf "p4242\\nn%s\\n" "${XST_TEST_PROCESS_EXE:?}" ;;\n'
            "  *)\n"
            '    printf "p4242\\nn%s\\n" "${XST_TEST_LISTENER:?}" ;;\n'
            "esac\n",
            encoding="utf-8",
        )
        lsof.chmod(0o755)

    def test_process_identity_requires_uid_real_executable_and_exact_full_argv(self):
        self.install_process_stubs()
        expected_command = "%s run -config %s" % (self.xray, self.config)
        env = self.shell_env()
        env.update(
            {
                "XST_TEST_PROCESS_UID": str(os.getuid()),
                "XST_TEST_PROCESS_EXE": str(self.xray),
                "XST_TEST_PROCESS_COMMAND": expected_command,
                "XST_TEST_LISTENER": "127.0.0.1:18080",
                "XST_TEST_XRAY": str(self.xray),
                "XST_TEST_CONFIG": str(self.config),
            }
        )
        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            'XRAY_BIN="$XST_TEST_XRAY"\n'
            'CONFIG_JSON="$XST_TEST_CONFIG"\n'
            "xst_process_matches_runtime 4242\n"
            'XST_TEST_PROCESS_COMMAND="$XST_TEST_PROCESS_COMMAND --extra"\n'
            "export XST_TEST_PROCESS_COMMAND\n"
            "if xst_process_matches_runtime 4242; then exit 90; fi\n"
            'XST_TEST_PROCESS_COMMAND="$XRAY_BIN run -config $CONFIG_JSON"\n'
            "XST_TEST_PROCESS_UID=99999\n"
            "export XST_TEST_PROCESS_COMMAND XST_TEST_PROCESS_UID\n"
            "if xst_process_matches_runtime 4242; then exit 91; fi",
            env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

        other = self.tmp / "not-xray"
        other.write_text("#!/bin/sh\n", encoding="utf-8")
        other.chmod(0o755)
        env["XST_TEST_PROCESS_EXE"] = str(other)
        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            'XRAY_BIN="$XST_TEST_XRAY"\n'
            'CONFIG_JSON="$XST_TEST_CONFIG"\n'
            "xst_process_matches_runtime 4242",
            env,
        )
        self.assertNotEqual(result.returncode, 0)

    def test_listener_requires_one_exact_ipv4_loopback_binding(self):
        self.install_process_stubs()
        env = self.shell_env()
        env["XST_TEST_PROCESS_UID"] = str(os.getuid())
        env["XST_TEST_PROCESS_EXE"] = str(self.xray)
        env["XST_TEST_PROCESS_COMMAND"] = "%s run -config %s" % (
            self.xray,
            self.config,
        )
        env["XST_TEST_LISTENER"] = "127.0.0.1:18080"
        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            "xst_is_loopback_listener_by_pid 18080 4242\n"
            'XST_TEST_LISTENER="*:18080"\n'
            "export XST_TEST_LISTENER\n"
            "if xst_is_loopback_listener_by_pid 18080 4242; then exit 90; fi\n"
            'XST_TEST_LISTENER="127.0.0.1:18080\nn[::1]:18080"\n'
            "export XST_TEST_LISTENER\n"
            "if xst_is_loopback_listener_by_pid 18080 4242; then exit 91; fi",
            env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_launchctl_bootout_is_verified_and_failed_stop_is_not_hidden(self):
        launch_state = self.tmp / "launch-loaded"
        launch_state.write_text("loaded\n", encoding="utf-8")
        launchctl = self.stub_bin / "launchctl"
        launchctl.write_text(
            "#!/bin/sh\n"
            'case "${1:-}" in\n'
            '  print) test -f "${XST_TEST_LAUNCH_STATE:?}" ;;\n'
            "  bootout)\n"
            '    if [ "${XST_TEST_BOOTOUT_FAIL:-0}" = 1 ]; then exit 5; fi\n'
            '    rm -f "${XST_TEST_LAUNCH_STATE:?}" ;;\n'
            "  *) exit 2 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        launchctl.chmod(0o755)
        env = self.shell_env()
        env["XST_TEST_LAUNCH_STATE"] = str(launch_state)
        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            "SERVICE_SCOPE=user\n"
            'SERVICE_TARGET="gui/501/com.xst.fixture"\n'
            "xst_launchctl_target_exists\n"
            "xst_launchctl_bootout_verified\n"
            "if xst_launchctl_target_exists; then exit 90; fi",
            env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

        launch_state.write_text("loaded\n", encoding="utf-8")
        env["XST_TEST_BOOTOUT_FAIL"] = "1"
        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            "SERVICE_SCOPE=user\n"
            'SERVICE_TARGET="gui/501/com.xst.fixture"\n'
            "xst_launchctl_bootout_verified",
            env,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(launch_state.exists())

    def test_stop_uses_applied_env_without_pending_env_pid_or_healthy_config(self):
        self.state.chmod(0o700)
        marker = self.state / ".xst-managed"
        marker.write_text("xray-split-tunnel:v1\n", encoding="utf-8")
        marker.chmod(0o600)
        applied = self.state / "applied.env"
        applied.write_text(
            "LABEL=com.xst.fixture\n"
            "HTTP_PORT=18080\n"
            "SOCKS_PORT=18081\n"
            "XRAY_BIN=%s\n"
            "SERVICE_SCOPE=user\n" % self.xray,
            encoding="utf-8",
        )
        applied.chmod(0o600)
        self.config.chmod(0o644)

        launch_agents = self.home / "Library" / "LaunchAgents"
        launch_agents.mkdir(parents=True)
        plist = launch_agents / "com.xst.fixture.plist"
        with plist.open("wb") as handle:
            plistlib.dump(
                {
                    "Label": "com.xst.fixture",
                    "ProgramArguments": [
                        str(self.xray),
                        "run",
                        "-config",
                        str(self.config),
                    ],
                    "WorkingDirectory": str(self.home),
                    "RunAtLoad": True,
                    "KeepAlive": True,
                    "ProcessType": "Background",
                    "ThrottleInterval": 10,
                    "Umask": 0o77,
                    "StandardOutPath": str(
                        self.home / "Library" / "Logs" / "com.xst.fixture.out.log"
                    ),
                    "StandardErrorPath": str(
                        self.home / "Library" / "Logs" / "com.xst.fixture.err.log"
                    ),
                },
                handle,
            )
        plist.chmod(0o600)

        launch_state = self.tmp / "stop-loaded"
        launch_state.write_text("loaded\n", encoding="utf-8")
        self.xray.unlink()
        launchctl = self.stub_bin / "launchctl"
        launchctl.write_text(
            "#!/bin/sh\n"
            'case "${1:-}" in\n'
            '  print) test -f "${XST_TEST_LAUNCH_STATE:?}" ;;\n'
            '  bootout) rm -f "${XST_TEST_LAUNCH_STATE:?}" ;;\n'
            "  *) exit 2 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        launchctl.chmod(0o755)
        env = self.shell_env()
        env["XST_TEST_LAUNCH_STATE"] = str(launch_state)

        result = subprocess.run(
            [str(BASH), str(ROOT / "bin" / "xst"), "stop"],
            cwd=str(ROOT),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )

        self.assertEqual(
            result.returncode,
            0,
            "stdout:\n%s\nstderr:\n%s" % (result.stdout, result.stderr),
        )
        self.assertFalse(launch_state.exists())
        self.assertFalse((self.state / ".xst-operation.lock").exists())

    def test_logs_refuses_symlink_without_reading_target(self):
        self.state.chmod(0o700)
        marker = self.state / ".xst-managed"
        marker.write_text("xray-split-tunnel:v1\n", encoding="utf-8")
        marker.chmod(0o600)
        applied = self.state / "applied.env"
        applied.write_text(
            "LABEL=com.xst.fixture\n"
            "HTTP_PORT=18080\n"
            "SOCKS_PORT=18081\n"
            "XRAY_BIN=%s\n"
            "SERVICE_SCOPE=user\n" % self.xray,
            encoding="utf-8",
        )
        applied.chmod(0o600)
        self.config.chmod(0o600)
        logs = self.home / "Library" / "Logs"
        logs.mkdir(parents=True)
        secret = self.tmp / "must-not-be-printed"
        secret.write_text("UNREDACTED_PRIVATE_MATERIAL\n", encoding="utf-8")
        out_log = logs / "com.xst.fixture.out.log"
        out_log.symlink_to(secret)
        err_log = logs / "com.xst.fixture.err.log"
        err_log.write_text("safe fixture\n", encoding="utf-8")
        err_log.chmod(0o600)

        result = subprocess.run(
            [str(BASH), str(ROOT / "bin" / "xst"), "logs"],
            cwd=str(ROOT),
            env=self.shell_env(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("UNREDACTED_PRIVATE_MATERIAL", result.stdout)
        self.assertNotIn("UNREDACTED_PRIVATE_MATERIAL", result.stderr)

    def test_claude_xst_commands_have_distinct_context_behavior(self):
        self.state.chmod(0o700)
        marker = self.state / ".xst-managed"
        marker.write_text("xray-split-tunnel:v1\n", encoding="utf-8")
        marker.chmod(0o600)
        applied = self.state / "applied.env"
        applied.write_text(
            "LABEL=com.xst.fixture\n"
            "HTTP_PORT=18080\n"
            "SOCKS_PORT=18081\n"
            "BYPASS_DOMAINS=corp.example.invalid\n"
            "XRAY_BIN=%s\n"
            "SERVICE_SCOPE=user\n" % self.xray,
            encoding="utf-8",
        )
        applied.chmod(0o600)
        self.config.chmod(0o600)
        capture = self.tmp / "claude-capture"
        capture.mkdir()
        claude = self.stub_bin / "claude"
        claude.write_text(
            "#!/bin/sh\n"
            'printf "%s\\n" "${HTTPS_PROXY:-}" > "${XST_TEST_HTTPS_PROXY:?}"\n'
            'printf "%s\\n" "${http_proxy:-}" > "${XST_TEST_HTTP_PROXY:?}"\n'
            'printf "%s\\n" "${NO_PROXY:-}" > "${XST_TEST_NO_PROXY:?}"\n'
            'printf "%s\\n" "${CLAUDE_CODE_PROXY_RESOLVES_HOSTS:-}" > "${XST_TEST_RESOLVE:?}"\n'
            'printf "%s\\n" "$@" > "${XST_TEST_CLAUDE_ARGV:?}"\n',
            encoding="utf-8",
        )
        claude.chmod(0o755)
        env = self.shell_env()
        env.update(
            {
                "XST_TEST_HTTPS_PROXY": str(capture / "https"),
                "XST_TEST_HTTP_PROXY": str(capture / "http"),
                "XST_TEST_NO_PROXY": str(capture / "no-proxy"),
                "XST_TEST_RESOLVE": str(capture / "resolve"),
                "XST_TEST_CLAUDE_ARGV": str(capture / "argv"),
            }
        )

        result = subprocess.run(
            [str(BASH), str(ROOT / "bin" / "claude-xst"), "--version"],
            cwd=str(ROOT),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            (capture / "https").read_text(encoding="utf-8").strip(),
            "http://127.0.0.1:18080",
        )
        self.assertEqual(
            (capture / "http").read_text(encoding="utf-8").strip(),
            "http://127.0.0.1:18080",
        )
        self.assertIn(
            ".corp.example.invalid",
            (capture / "no-proxy").read_text(encoding="utf-8"),
        )
        self.assertEqual(
            (capture / "resolve").read_text(encoding="utf-8").strip(), "1"
        )
        argv = (capture / "argv").read_text(encoding="utf-8").splitlines()
        self.assertEqual(argv, ["--version"])

        aware_result = subprocess.run(
            [str(BASH), str(ROOT / "bin" / "claude-xst-aware"), "--version"],
            cwd=str(ROOT),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )

        self.assertEqual(aware_result.returncode, 0, aware_result.stderr)
        aware_argv = (capture / "argv").read_text(encoding="utf-8").splitlines()
        self.assertEqual(aware_argv[0], "--append-system-prompt-file")
        self.assertEqual(
            aware_argv[1], str(ROOT / "templates" / "claude-xst-instructions.md")
        )
        self.assertEqual(aware_argv[2:], ["--version"])

    def test_user_plist_permission_check_is_exact_and_rejects_symlink(self):
        plist = self.home / "fixture.plist"
        plist.write_text("fixture\n", encoding="utf-8")
        plist.chmod(0o600)
        env = self.shell_env()
        env["XST_TEST_PLIST"] = str(plist)
        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            'xst_check_plist_permissions "$XST_TEST_PLIST" user',
            env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

        plist.chmod(0o644)
        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            'xst_check_plist_permissions "$XST_TEST_PLIST" user',
            env,
        )
        self.assertNotEqual(result.returncode, 0)
        plist.unlink()
        plist.symlink_to(self.config)
        result = run_bash(
            'source "$XST_ROOT/lib/common.sh"\n'
            'xst_check_plist_permissions "$XST_TEST_PLIST" user',
            env,
        )
        self.assertNotEqual(result.returncode, 0)


@unittest.skipUnless(sys.platform == "darwin", "installer targets macOS")
class InstallerDryRunTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.state = self.home / ".config" / "xray-split-tunnel"
        self.subscription = self.tmp / "subscription.json"
        self.subscription.write_bytes(
            (ROOT / "tests" / "fixtures" / "dry-run-config.json").read_bytes()
        )
        self.subscription.chmod(0o600)
        self.bypass = self.tmp / "bypass.env"
        self.bypass.write_text(
            "BYPASS_DOMAINS=corp.example.invalid\n"
            "BYPASS_CIDRS=100.64.0.0/10\n",
            encoding="utf-8",
        )
        self.bypass.chmod(0o600)
        self.stub_bin = self.tmp / "bin"
        self.stub_bin.mkdir()
        xray = self.stub_bin / "xray"
        xray.write_text(
            "#!/bin/sh\n"
            'if [ "${1:-}" = version ]; then\n'
            '  echo "Xray 26.3.27 (fixture)"\n'
            "  exit 0\n"
            "fi\n"
            "exit 0\n",
            encoding="utf-8",
        )
        xray.chmod(0o755)
        claude = self.stub_bin / "claude"
        claude.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        claude.chmod(0o755)

    def tearDown(self):
        self._tmp.cleanup()

    def test_dry_run_validates_without_persistent_writes(self):
        if Path("/Library/LaunchDaemons/com.nqs.xray.plist").exists():
            self.skipTest("host has the legacy production daemon; dry-run refuses overlap")
        env = os.environ.copy()
        env.update(
            {
                "HOME": str(self.home),
                "XST_HOME": str(self.state),
                "XST_SUB_FILE": str(self.subscription),
                "XST_BYPASS_FILE": str(self.bypass),
                "XST_ZSHRC": "0",
                "XST_CLAUDE_COMMAND": "1",
                "XST_CLAUDE_AWARE_COMMAND": "1",
                "XST_SERVER": "0",
                "LABEL": "invalid inherited label",
                "HTTP_PORT": "not-a-port",
                "SOCKS_PORT": "also-not-a-port",
                "SERVICE_SCOPE": "invalid-inherited-scope",
                "BYPASS_DOMAINS": "inherited.secret.invalid",
                "BYPASS_CIDRS": "203.0.113.0/24",
                "PATH": str(self.stub_bin)
                + os.pathsep
                + os.environ.get("PATH", ""),
            }
        )
        result = subprocess.run(
            [
                str(BASH),
                str(ROOT / "install.sh"),
                "--non-interactive",
                "--dry-run",
            ],
            cwd=str(ROOT),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
        )
        self.assertEqual(
            result.returncode,
            0,
            "stdout:\n%s\nstderr:\n%s" % (result.stdout, result.stderr),
        )
        self.assertIn("DRY RUN", result.stdout)
        self.assertFalse(self.state.exists(), "dry-run created persistent state")
        self.assertFalse(
            (self.home / ".local" / "bin" / "claude-xst").exists(),
            "dry-run created optional command",
        )
        self.assertFalse(
            (self.home / ".local" / "bin" / "claude-xst-aware").exists(),
            "dry-run created optional aware command",
        )


class UninstallPurgeGuardTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.home = self.tmp / "isolated-home"
        self.stub_bin = self.tmp / "bin"
        self.home.mkdir()
        self.stub_bin.mkdir()
        self.launchctl_log = self.tmp / "launchctl.log"
        self.prelock_violation = self.tmp / "launchctl-before-lock"
        launchctl = self.stub_bin / "launchctl"
        launchctl.write_text(
            "#!/bin/sh\n"
            'if [ ! -f "${XST_HOME:?}/.xst-operation.lock/owner" ]; then\n'
            '  : > "${XST_TEST_PRELOCK_VIOLATION:?}"\n'
            "fi\n"
            'printf "%s\\n" "$*" >> "${XST_TEST_LAUNCHCTL_LOG:?}"\n'
            "exit 1\n",
            encoding="utf-8",
        )
        launchctl.chmod(0o755)

    def tearDown(self):
        self._tmp.cleanup()

    def uninstall_env(self, xst_home):
        self.assertTrue(
            str(self.home).startswith(str(self.tmp) + os.sep),
            "test HOME must remain inside its temporary directory",
        )
        env = os.environ.copy()
        env.update(
            {
                "HOME": str(self.home),
                "XST_HOME": str(xst_home),
                "XST_TEST_LAUNCHCTL_LOG": str(self.launchctl_log),
                "XST_TEST_PRELOCK_VIOLATION": str(self.prelock_violation),
                "PATH": str(self.stub_bin)
                + os.pathsep
                + os.environ.get("PATH", ""),
            }
        )
        return env

    def run_uninstall(self, xst_home, *args):
        return subprocess.run(
            [str(BASH), str(ROOT / "uninstall.sh")] + list(args),
            cwd=str(ROOT),
            env=self.uninstall_env(xst_home),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )

    def create_managed_state(self, include_pending_env=True):
        state = self.home / "state"
        state.mkdir()
        state.chmod(0o700)
        (state / ".xst-managed").write_text(
            "xray-split-tunnel:v1\n", encoding="utf-8"
        )
        (state / ".xst-managed").chmod(0o600)
        (state / "config.json").write_text("fixture\n", encoding="utf-8")
        (state / "config.json").chmod(0o600)
        env_contents = (
            "LABEL=com.xst.fixture\n"
            "HTTP_PORT=18080\n"
            "SOCKS_PORT=18081\n"
            "XRAY_BIN=/usr/bin/true\n"
            "SERVICE_SCOPE=user\n"
        )
        (state / "applied.env").write_text(env_contents, encoding="utf-8")
        (state / "applied.env").chmod(0o600)
        if include_pending_env:
            (state / "env").write_text(env_contents, encoding="utf-8")
            (state / "env").chmod(0o600)
        return state

    def test_purge_removes_only_an_isolated_state_directory(self):
        state = self.create_managed_state()
        keep = self.home / "keep-me"
        keep.write_text("safe\n", encoding="utf-8")
        local_bin = self.home / ".local" / "bin"
        local_bin.mkdir(parents=True)
        xst_link = local_bin / "xst"
        claude_link = local_bin / "claude-xst"
        claude_aware_link = local_bin / "claude-xst-aware"
        xst_link.symlink_to(ROOT / "bin" / "xst")
        claude_link.symlink_to(ROOT / "bin" / "claude-xst")
        claude_aware_link.symlink_to(ROOT / "bin" / "claude-xst-aware")

        result = self.run_uninstall(state, "--purge")

        self.assertEqual(
            result.returncode,
            0,
            "stdout:\n%s\nstderr:\n%s" % (result.stdout, result.stderr),
        )
        self.assertFalse(state.exists())
        self.assertFalse(xst_link.exists())
        self.assertFalse(claude_link.exists())
        self.assertFalse(claude_aware_link.exists())
        self.assertEqual(keep.read_text(encoding="utf-8"), "safe\n")
        self.assertTrue(self.launchctl_log.exists(), "launchctl should be the stub")
        self.assertFalse(
            self.prelock_violation.exists(),
            "uninstall called launchctl before acquiring its state lock",
        )

    def test_regular_uninstall_uses_applied_env_when_pending_env_is_missing(self):
        state = self.create_managed_state(include_pending_env=False)

        result = self.run_uninstall(state)

        self.assertEqual(
            result.returncode,
            0,
            "stdout:\n%s\nstderr:\n%s" % (result.stdout, result.stderr),
        )
        self.assertTrue(state.is_dir())
        self.assertFalse((state / ".xst-operation.lock").exists())
        self.assertTrue((state / "applied.env").is_file())
        self.assertFalse(self.prelock_violation.exists())

    def test_purge_move_masks_term_and_completes(self):
        state = self.create_managed_state()
        mv = self.stub_bin / "mv"
        mv.write_text(
            "#!/bin/sh\n"
            '/bin/mv "$@" || exit\n'
            'kill -TERM "$PPID"\n',
            encoding="utf-8",
        )
        mv.chmod(0o755)

        result = self.run_uninstall(state, "--purge")

        self.assertEqual(
            result.returncode,
            0,
            "stdout:\n%s\nstderr:\n%s" % (result.stdout, result.stderr),
        )
        self.assertFalse(state.exists())
        self.assertEqual(list(self.home.glob(".xst-purge.*")), [])

    def test_purge_exit_cleanup_finishes_proven_partial_tombstone(self):
        state = self.create_managed_state()
        injected = self.tmp / "purge-signal-injected"
        rm = self.stub_bin / "rm"
        rm.write_text(
            "#!/bin/sh\n"
            'case "$*" in\n'
            '  *".xst-purge."*)\n'
            '    if [ ! -e "${XST_TEST_PURGE_SIGNAL:?}" ]; then\n'
            '      : > "${XST_TEST_PURGE_SIGNAL:?}"\n'
            '      kill -TERM "$PPID"\n'
            "      exit 130\n"
            "    fi\n"
            "    ;;\n"
            "esac\n"
            'exec /bin/rm "$@"\n',
            encoding="utf-8",
        )
        rm.chmod(0o755)
        env = self.uninstall_env(state)
        env["XST_TEST_PURGE_SIGNAL"] = str(injected)

        result = subprocess.run(
            [str(BASH), str(ROOT / "uninstall.sh"), "--purge"],
            cwd=str(ROOT),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(injected.exists())
        self.assertFalse(state.exists())
        self.assertEqual(list(self.home.glob(".xst-purge.*")), [])

    def test_purge_refuses_xst_home_equal_to_home(self):
        keep = self.home / "must-survive"
        keep.write_text("safe\n", encoding="utf-8")

        result = self.run_uninstall(self.home, "--purge")

        self.assertNotEqual(
            result.returncode,
            0,
            "purge unexpectedly accepted XST_HOME equal to HOME",
        )
        self.assertEqual(keep.read_text(encoding="utf-8"), "safe\n")

    def test_unknown_argument_is_rejected_before_any_mutation(self):
        state = self.home / "state"
        state.mkdir()
        keep = state / "must-survive"
        keep.write_text("safe\n", encoding="utf-8")

        result = self.run_uninstall(state, "--definitely-invalid")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(keep.read_text(encoding="utf-8"), "safe\n")
        self.assertFalse(
            self.launchctl_log.exists(),
            "argument validation must happen before launchctl",
        )


if __name__ == "__main__":
    unittest.main()
