import io
import importlib.util
import json
import plistlib
import subprocess
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stdout
from unittest import mock
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
XSTLIB_PATH = ROOT / "lib" / "xstlib.py"
FIXTURES = ROOT / "tests" / "fixtures"


def load_xstlib():
    spec = importlib.util.spec_from_file_location("xstlib_under_test", str(XSTLIB_PATH))
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot import %s" % XSTLIB_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CliTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def run_cli(self, *args):
        return subprocess.run(
            [sys.executable, str(XSTLIB_PATH)] + [str(arg) for arg in args],
            cwd=str(ROOT),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )

    def assert_ok(self, result):
        self.assertEqual(
            result.returncode,
            0,
            "command failed\nstdout:\n%s\nstderr:\n%s" % (result.stdout, result.stderr),
        )
        self.assertNotIn("Traceback", result.stderr)

    def assert_clean_failure(self, result):
        self.assertNotEqual(
            result.returncode,
            0,
            "command unexpectedly succeeded\nstdout:\n%s" % result.stdout,
        )
        self.assertNotIn("Traceback", result.stderr)

    def normalized_subscription(self):
        dst = self.tmp / "subscription.json"
        result = self.run_cli(
            "normalize", FIXTURES / "subscription-wrapper.json", dst
        )
        self.assert_ok(result)
        return dst

    def apply_config(
        self,
        domains="corp.example.invalid",
        cidrs="100.64.0.0/10",
        http_port="18080",
        socks_port="18081",
        dst=None,
    ):
        subscription = self.normalized_subscription()
        if dst is None:
            dst = self.tmp / "config.json"
        result = self.run_cli(
            "apply",
            subscription,
            "0",
            dst,
            "--http-port",
            http_port,
            "--socks-port",
            socks_port,
            "--bypass-domains",
            domains,
            "--bypass-cidrs",
            cidrs,
        )
        return result, dst


class NormalizeTests(CliTestCase):
    def test_normalize_wrapped_subscription_filters_non_configs(self):
        src = FIXTURES / "subscription-wrapper.json"
        before = src.read_bytes()
        dst = self.tmp / "normalized.json"

        result = self.run_cli("normalize", src, dst)

        self.assert_ok(result)
        self.assertEqual(result.stdout.strip(), "2")
        normalized = json.loads(dst.read_text(encoding="utf-8"))
        self.assertEqual(
            [item.get("remarks") or item.get("name") for item in normalized],
            ["Oslo Primary", "Oslo Backup"],
        )
        self.assertEqual(src.read_bytes(), before)

    def test_normalize_single_config_object(self):
        dst = self.tmp / "normalized.json"
        result = self.run_cli("normalize", FIXTURES / "single-config.json", dst)

        self.assert_ok(result)
        self.assertEqual(result.stdout.strip(), "1")
        self.assertEqual(
            json.loads(dst.read_text(encoding="utf-8"))[0]["remarks"],
            "Helsinki Fixture",
        )

    def test_normalize_rejects_malformed_json_without_replacing_output(self):
        src = self.tmp / "bad.json"
        src.write_text('{"configs": [', encoding="utf-8")
        dst = self.tmp / "normalized.json"
        dst.write_text("sentinel\n", encoding="utf-8")

        result = self.run_cli("normalize", src, dst)

        self.assert_clean_failure(result)
        self.assertEqual(dst.read_text(encoding="utf-8"), "sentinel\n")

    def test_normalize_rejects_config_with_non_list_outbounds(self):
        src = self.tmp / "bad-shape.json"
        src.write_text(
            json.dumps(
                {
                    "configs": [
                        {
                            "remarks": "malformed",
                            "outbounds": "this is not an outbound list",
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )
        dst = self.tmp / "normalized.json"
        dst.write_text("sentinel\n", encoding="utf-8")

        result = self.run_cli("normalize", src, dst)

        self.assert_clean_failure(result)
        self.assertEqual(dst.read_text(encoding="utf-8"), "sentinel\n")

    def test_save_json_is_atomic_when_encoding_fails(self):
        xstlib = load_xstlib()
        dst = self.tmp / "config.json"
        dst.write_text("known-good\n", encoding="utf-8")
        circular = {}
        circular["self"] = circular

        with self.assertRaises((TypeError, ValueError, OSError, SystemExit)):
            xstlib.save_json(str(dst), circular)

        self.assertEqual(dst.read_text(encoding="utf-8"), "known-good\n")
        self.assertEqual(set(self.tmp.iterdir()), {dst}, "temporary file leaked")

    def make_subscription(self, count):
        return [
            {
                "remarks": "server-%d" % index,
                "outbounds": [{"tag": "proxy", "protocol": "socks"}],
            }
            for index in range(count)
        ]

    def test_normalize_accepts_exact_config_limit(self):
        src = self.tmp / "raw.json"
        dst = self.tmp / "normalized.json"
        src.write_text(
            json.dumps(self.make_subscription(512)),
            encoding="utf-8",
        )

        result = self.run_cli("normalize", src, dst)

        self.assert_ok(result)
        self.assertEqual(result.stdout.strip(), "512")
        self.assertEqual(len(json.loads(dst.read_text(encoding="utf-8"))), 512)

    def test_normalize_rejects_more_than_config_limit_atomically(self):
        src = self.tmp / "raw.json"
        dst = self.tmp / "normalized.json"
        src.write_text(
            json.dumps({"configs": self.make_subscription(513)}),
            encoding="utf-8",
        )
        dst.write_text("sentinel\n", encoding="utf-8")

        result = self.run_cli("normalize", src, dst)

        self.assert_clean_failure(result)
        self.assertIn("512", result.stderr)
        self.assertEqual(dst.read_text(encoding="utf-8"), "sentinel\n")

    def test_load_rejects_more_than_config_limit_before_validation_loop(self):
        subscription = self.tmp / "subscription.json"
        data = self.make_subscription(513)
        data[-1]["outbounds"] = "would fail shape validation later"
        subscription.write_text(json.dumps(data), encoding="utf-8")

        result = self.run_cli("list", subscription)

        self.assert_clean_failure(result)
        self.assertIn("512", result.stderr)
        self.assertNotIn("outbounds", result.stderr)


class ListAndResolveTests(CliTestCase):
    def test_list_marks_current_server(self):
        subscription = self.normalized_subscription()
        result = self.run_cli("list", subscription, "--current", "1")

        self.assert_ok(result)
        self.assertIn("[ 0] Oslo Primary", result.stdout)
        self.assertIn("[ 1] Oslo Backup  <- активен", result.stdout)

    def test_resolve_supports_index_and_case_insensitive_unique_substring(self):
        subscription = self.normalized_subscription()

        by_index = self.run_cli("resolve", subscription, "1")
        by_name = self.run_cli("resolve", subscription, "PRIMARY")

        self.assert_ok(by_index)
        self.assert_ok(by_name)
        self.assertEqual(by_index.stdout.strip(), "1")
        self.assertEqual(by_name.stdout.strip(), "0")

    def test_resolve_rejects_ambiguous_missing_and_out_of_range_targets(self):
        subscription = self.normalized_subscription()

        for target in ("Oslo", "missing", "99", "-1", ""):
            with self.subTest(target=target):
                self.assert_clean_failure(
                    self.run_cli("resolve", subscription, target)
                )

    def test_resolve_exact_treats_numeric_target_as_name(self):
        subscription = self.tmp / "subscription.json"
        subscription.write_text(
            json.dumps(
                [
                    {
                        "remarks": "1",
                        "outbounds": [{"tag": "proxy", "protocol": "socks"}],
                    },
                    {
                        "remarks": "second",
                        "outbounds": [{"tag": "proxy", "protocol": "socks"}],
                    },
                ]
            ),
            encoding="utf-8",
        )

        exact = self.run_cli("resolve-exact", subscription, "1")
        human = self.run_cli("resolve", subscription, "1")

        self.assert_ok(exact)
        self.assert_ok(human)
        self.assertEqual(exact.stdout.strip(), "0")
        self.assertEqual(human.stdout.strip(), "1")

    def test_resolve_exact_rejects_substring_missing_duplicate_and_fallback(self):
        subscription = self.tmp / "subscription.json"
        subscription.write_text(
            json.dumps(
                [
                    {
                        "remarks": "Oslo Primary",
                        "outbounds": [{"tag": "proxy", "protocol": "socks"}],
                    },
                    {
                        "remarks": "Duplicate",
                        "outbounds": [{"tag": "proxy", "protocol": "socks"}],
                    },
                    {
                        "name": "duplicate",
                        "outbounds": [{"tag": "proxy", "protocol": "socks"}],
                    },
                    {
                        "outbounds": [{"tag": "proxy", "protocol": "socks"}],
                    },
                ]
            ),
            encoding="utf-8",
        )

        for target in ("Primary", "missing", "Duplicate", "server 3", ""):
            with self.subTest(target=target):
                self.assert_clean_failure(
                    self.run_cli("resolve-exact", subscription, target)
                )

    def test_identity_preserves_numeric_zero_and_distinguishes_long_names(self):
        shared_prefix = "x" * 120
        subscription = self.tmp / "subscription.json"
        subscription.write_text(
            json.dumps(
                [
                    {
                        "remarks": 0,
                        "outbounds": [{"tag": "proxy", "protocol": "socks"}],
                    },
                    {
                        "remarks": shared_prefix + "-one",
                        "outbounds": [{"tag": "proxy", "protocol": "socks"}],
                    },
                    {
                        "remarks": shared_prefix + "-two",
                        "outbounds": [{"tag": "proxy", "protocol": "socks"}],
                    },
                ]
            ),
            encoding="utf-8",
        )

        zero_identity = self.run_cli("identity", subscription, "0")
        first_identity = self.run_cli("identity", subscription, "1")
        second_identity = self.run_cli("identity", subscription, "2")
        for result in (zero_identity, first_identity, second_identity):
            self.assert_ok(result)
            self.assertRegex(result.stdout.strip(), r"^[0-9a-f]{64}$")
        self.assertNotEqual(first_identity.stdout, second_identity.stdout)

        resolved_zero = self.run_cli(
            "resolve-identity", subscription, zero_identity.stdout.strip()
        )
        resolved_second = self.run_cli(
            "resolve-identity", subscription, second_identity.stdout.strip()
        )
        self.assert_ok(resolved_zero)
        self.assert_ok(resolved_second)
        self.assertEqual(resolved_zero.stdout.strip(), "0")
        self.assertEqual(resolved_second.stdout.strip(), "2")

    def test_list_sanitizes_terminal_control_characters_and_newlines(self):
        subscription = self.tmp / "subscription.json"
        subscription.write_text(
            json.dumps(
                [
                    {
                        "remarks": "safe\x1b[31m\nforged\u202eevil\u2066tail",
                        "outbounds": [{"tag": "proxy", "protocol": "freedom"}],
                    }
                ]
            ),
            encoding="utf-8",
        )

        result = self.run_cli("list", subscription)

        self.assert_ok(result)
        self.assertNotIn("\x1b", result.stdout)
        self.assertNotIn("\u202e", result.stdout)
        self.assertNotIn("\u2066", result.stdout)
        self.assertEqual(len(result.stdout.splitlines()), 1)

    def test_identity_normalizes_unicode_and_removes_format_controls(self):
        module = load_xstlib()
        unsafe = {"remarks": "Ｆｉｘｔｕｒｅ\u202e \u2066Name"}
        canonical = {"remarks": "Fixture Name"}

        self.assertEqual(module.explicit_name_of(unsafe), "Fixture Name")
        self.assertEqual(
            module.identity_digest_of(unsafe),
            module.identity_digest_of(canonical),
        )

    def test_list_rejects_non_list_subscription_cleanly(self):
        subscription = self.tmp / "subscription.json"
        subscription.write_text('{"outbounds": []}\n', encoding="utf-8")

        for command in (("list", subscription), ("resolve", subscription, "0")):
            with self.subTest(command=command[0]):
                self.assert_clean_failure(self.run_cli(*command))


class ApplyTests(CliTestCase):
    def test_apply_accepts_protected_bypass_stream(self):
        subscription = self.normalized_subscription()
        dst = self.tmp / "stdin-config.json"
        result = subprocess.run(
            [
                sys.executable,
                str(XSTLIB_PATH),
                "apply",
                str(subscription),
                "0",
                str(dst),
                "--http-port",
                "18080",
                "--socks-port",
                "18081",
                "--bypass-stdin",
            ],
            cwd=str(ROOT),
            input="corp.example.invalid\0" "100.64.0.0/10\0",
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )

        self.assert_ok(result)
        config = json.loads(dst.read_text(encoding="utf-8"))
        self.assertIn(
            "domain:corp.example.invalid",
            config["routing"]["rules"][0]["domain"],
        )
        self.assertIn("100.64.0.0/10", config["routing"]["rules"][1]["ip"])

    def test_apply_forces_loopback_inbounds_and_requested_ports(self):
        result, dst = self.apply_config()
        self.assert_ok(result)
        config = json.loads(dst.read_text(encoding="utf-8"))

        inbounds = config["inbounds"]
        self.assertTrue(inbounds)
        self.assertTrue(all(item["listen"] == "127.0.0.1" for item in inbounds))
        http = [item for item in inbounds if item.get("protocol") == "http"]
        socks = [item for item in inbounds if item.get("protocol") == "socks"]
        self.assertEqual(len(http), 1)
        self.assertEqual(len(socks), 1)
        self.assertEqual(http[0]["port"], 18080)
        self.assertEqual(socks[0]["port"], 18081)
        self.assertTrue(http[0]["sniffing"]["enabled"])
        self.assertTrue(socks[0]["sniffing"]["enabled"])

    def test_apply_creates_one_safe_direct_outbound_and_domain_rule_first(self):
        result, dst = self.apply_config()
        self.assert_ok(result)
        config = json.loads(dst.read_text(encoding="utf-8"))

        tags = [item.get("tag") for item in config["outbounds"] if item.get("tag")]
        self.assertEqual(len(tags), len(set(tags)), "outbound tags must be unique")
        direct = [
            item for item in config["outbounds"] if item.get("tag") == "direct"
        ]
        self.assertEqual(len(direct), 1)
        self.assertEqual(direct[0].get("protocol"), "freedom")

        rules = config["routing"]["rules"]
        domain_pos = next(
            idx
            for idx, rule in enumerate(rules)
            if "domain:corp.example.invalid" in (rule.get("domain") or [])
        )
        private_ip_pos = next(
            idx
            for idx, rule in enumerate(rules)
            if "geoip:private" in (rule.get("ip") or [])
        )
        self.assertLess(
            domain_pos,
            private_ip_pos,
            "domain bypass must precede IP rules under IPOnDemand/IPIfNonMatch",
        )
        self.assertEqual(rules[domain_pos]["outboundTag"], "direct")
        self.assertEqual(rules[private_ip_pos]["outboundTag"], "direct")

    def test_apply_normalizes_and_deduplicates_domains_and_cidrs(self):
        result, dst = self.apply_config(
            domains=" .Corp.Example.Invalid.,corp.example.invalid ",
            cidrs="100.64.0.1/10, 100.64.0.0/10",
        )
        self.assert_ok(result)
        config = json.loads(dst.read_text(encoding="utf-8"))
        rules = config["routing"]["rules"]

        generated_domains = [
            pattern
            for rule in rules
            if rule.get("outboundTag") == "direct"
            for pattern in (rule.get("domain") or [])
        ]
        generated_ips = [
            pattern
            for rule in rules
            if rule.get("outboundTag") == "direct"
            for pattern in (rule.get("ip") or [])
        ]
        self.assertEqual(
            generated_domains.count("domain:corp.example.invalid"), 1
        )
        self.assertEqual(generated_ips.count("100.64.0.0/10"), 1)

    def test_apply_is_deterministic_and_does_not_mutate_subscription(self):
        subscription = self.normalized_subscription()
        before = subscription.read_bytes()
        first = self.tmp / "first.json"
        second = self.tmp / "second.json"
        common_args = [
            "apply",
            subscription,
            "0",
            None,
            "--http-port",
            "18080",
            "--socks-port",
            "18081",
            "--bypass-domains",
            "corp.example.invalid",
            "--bypass-cidrs",
            "100.64.0.0/10",
        ]

        common_args[3] = first
        first_result = self.run_cli(*common_args)
        common_args[3] = second
        second_result = self.run_cli(*common_args)

        self.assert_ok(first_result)
        self.assert_ok(second_result)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        self.assertEqual(subscription.read_bytes(), before)

    def test_apply_rejects_invalid_parameters_without_replacing_output(self):
        invalid_cases = [
            ("zero port", "0", "18081", "", ""),
            ("port above range", "65536", "18081", "", ""),
            ("non-numeric port", "not-a-port", "18081", "", ""),
            ("same ports", "18080", "18080", "", ""),
            ("URL as domain", "18080", "18081", "https://corp.example.invalid", ""),
            ("wildcard domain", "18080", "18081", "*.corp.example.invalid", ""),
            (
                "control character in domain",
                "18080",
                "18081",
                "corp.example.invalid\nregexp:.*",
                "",
            ),
            ("invalid CIDR", "18080", "18081", "", "not-a-cidr"),
            ("IPv4 default route", "18080", "18081", "", "0.0.0.0/0"),
            ("IPv6 default route", "18080", "18081", "", "::/0"),
        ]

        for name, http_port, socks_port, domains, cidrs in invalid_cases:
            with self.subTest(name=name):
                dst = self.tmp / ("invalid-%s.json" % name.replace(" ", "-"))
                dst.write_text("sentinel\n", encoding="utf-8")
                result, _ = self.apply_config(
                    domains=domains,
                    cidrs=cidrs,
                    http_port=http_port,
                    socks_port=socks_port,
                    dst=dst,
                )
                self.assert_clean_failure(result)
                self.assertEqual(dst.read_text(encoding="utf-8"), "sentinel\n")

    def test_apply_rejects_non_numeric_index_cleanly(self):
        subscription = self.normalized_subscription()
        dst = self.tmp / "config.json"
        dst.write_text("sentinel\n", encoding="utf-8")

        result = self.run_cli(
            "apply",
            subscription,
            "first",
            dst,
            "--http-port",
            "18080",
            "--socks-port",
            "18081",
        )

        self.assert_clean_failure(result)
        self.assertEqual(dst.read_text(encoding="utf-8"), "sentinel\n")

    def test_apply_owns_security_sensitive_top_level_sections(self):
        subscription = self.normalized_subscription()
        data = json.loads(subscription.read_text(encoding="utf-8"))
        data[0].update(
            {
                "dns": {"servers": ["exfil.example.invalid"]},
                "api": {"tag": "danger"},
                "stats": {},
                "metrics": {"tag": "metrics", "listen": "0.0.0.0:9999"},
                "reverse": {"bridges": []},
            }
        )
        data[0]["routing"]["rules"].append(
            {
                "type": "field",
                "outboundTag": "direct",
                "domain": ["domain:unexpected.example.invalid"],
            }
        )
        subscription.write_text(json.dumps(data), encoding="utf-8")

        dst = self.tmp / "config.json"
        result = self.run_cli(
            "apply",
            subscription,
            "0",
            dst,
            "--http-port",
            "18080",
            "--socks-port",
            "18081",
        )

        self.assert_ok(result)
        config = json.loads(dst.read_text(encoding="utf-8"))
        self.assertEqual(
            set(config), {"log", "inbounds", "outbounds", "routing"}
        )
        all_domains = [
            value
            for rule in config["routing"]["rules"]
            for value in (rule.get("domain") or [])
        ]
        self.assertNotIn("domain:unexpected.example.invalid", all_domains)

    def test_apply_drops_provider_non_proxy_detours(self):
        subscription = self.normalized_subscription()
        data = json.loads(subscription.read_text(encoding="utf-8"))
        data[0]["outbounds"].extend(
            [
                {"tag": "escape", "protocol": "freedom"},
                {"tag": "provider-dns", "protocol": "dns"},
                {"tag": "provider-block", "protocol": "blackhole"},
            ]
        )
        subscription.write_text(json.dumps(data), encoding="utf-8")
        dst = self.tmp / "config.json"

        result = self.run_cli(
            "apply",
            subscription,
            "0",
            dst,
            "--http-port",
            "18080",
            "--socks-port",
            "18081",
        )

        self.assert_ok(result)
        generated = json.loads(dst.read_text(encoding="utf-8"))
        tags = {outbound["tag"] for outbound in generated["outbounds"]}
        self.assertNotIn("escape", tags)
        self.assertNotIn("provider-dns", tags)
        self.assertNotIn("provider-block", tags)
        self.assertEqual(
            [item["protocol"] for item in generated["outbounds"][-2:]],
            ["freedom", "blackhole"],
        )

    def test_apply_rejects_non_proxy_primary_outbound(self):
        subscription = self.tmp / "subscription.json"
        subscription.write_text(
            json.dumps(
                [
                    {
                        "remarks": "unsafe",
                        "outbounds": [
                            {"tag": "primary", "protocol": "blackhole"}
                        ],
                    }
                ]
            ),
            encoding="utf-8",
        )
        dst = self.tmp / "config.json"
        dst.write_text("sentinel\n", encoding="utf-8")

        result = self.run_cli(
            "apply",
            subscription,
            "0",
            dst,
            "--http-port",
            "18080",
            "--socks-port",
            "18081",
        )

        self.assert_clean_failure(result)
        self.assertEqual(dst.read_text(encoding="utf-8"), "sentinel\n")

    def test_apply_rejects_reserved_tag_on_primary_proxy_outbound(self):
        for reserved_tag in ("direct", "block"):
            with self.subTest(tag=reserved_tag):
                subscription = self.tmp / ("%s-subscription.json" % reserved_tag)
                subscription.write_text(
                    json.dumps(
                        [
                            {
                                "remarks": "unsafe",
                                "outbounds": [
                                    {
                                        "tag": reserved_tag,
                                        "protocol": "vless",
                                        "settings": {},
                                    },
                                    {
                                        "tag": "backup-proxy",
                                        "protocol": "vless",
                                        "settings": {},
                                    },
                                ],
                            }
                        ]
                    ),
                    encoding="utf-8",
                )
                dst = self.tmp / ("%s-config.json" % reserved_tag)
                dst.write_text("sentinel\n", encoding="utf-8")

                result = self.run_cli(
                    "apply",
                    subscription,
                    "0",
                    dst,
                    "--http-port",
                    "18080",
                    "--socks-port",
                    "18081",
                )

                self.assert_clean_failure(result)
                self.assertEqual(dst.read_text(encoding="utf-8"), "sentinel\n")

    def test_apply_accepts_hysteria_primary_outbound(self):
        subscription = self.tmp / "subscription.json"
        subscription.write_text(
            json.dumps(
                [
                    {
                        "remarks": "Hysteria 2",
                        "outbounds": [
                            {
                                "tag": "proxy",
                                "protocol": "hysteria",
                                "settings": {
                                    "version": 2,
                                    "address": "example.invalid",
                                    "port": 443,
                                },
                            }
                        ],
                    }
                ]
            ),
            encoding="utf-8",
        )
        dst = self.tmp / "config.json"

        result = self.run_cli(
            "apply",
            subscription,
            "0",
            dst,
            "--http-port",
            "18080",
            "--socks-port",
            "18081",
        )

        self.assert_ok(result)
        generated = json.loads(dst.read_text(encoding="utf-8"))
        self.assertEqual(generated["outbounds"][0]["protocol"], "hysteria")
        self.assertNotIn(generated["outbounds"][0]["tag"], ("direct", "block"))


class ConfigPortsTests(CliTestCase):
    def test_config_ports_extracts_strict_managed_loopback_ports(self):
        result, config = self.apply_config()
        self.assert_ok(result)

        extracted = self.run_cli("config-ports", config)

        self.assert_ok(extracted)
        self.assertEqual(extracted.stdout.strip(), "18080\t18081")

    def test_config_ports_rejects_non_managed_shapes(self):
        result, valid_path = self.apply_config()
        self.assert_ok(result)
        valid = json.loads(valid_path.read_text(encoding="utf-8"))

        cases = {}
        non_loopback = json.loads(json.dumps(valid))
        non_loopback["inbounds"][0]["listen"] = "0.0.0.0"
        cases["non-loopback"] = non_loopback

        extra = json.loads(json.dumps(valid))
        extra["inbounds"].append(
            {
                "tag": "unexpected",
                "protocol": "http",
                "listen": "127.0.0.1",
                "port": 18082,
            }
        )
        cases["extra-inbound"] = extra

        wrong_protocol = json.loads(json.dumps(valid))
        wrong_protocol["inbounds"][1]["protocol"] = "http"
        cases["wrong-protocol"] = wrong_protocol

        string_port = json.loads(json.dumps(valid))
        string_port["inbounds"][0]["port"] = "18080"
        cases["string-port"] = string_port

        same_ports = json.loads(json.dumps(valid))
        same_ports["inbounds"][1]["port"] = 18080
        cases["same-ports"] = same_ports

        for name, data in cases.items():
            with self.subTest(name=name):
                path = self.tmp / ("%s.json" % name)
                path.write_text(json.dumps(data), encoding="utf-8")
                self.assert_clean_failure(
                    self.run_cli("config-ports", path)
                )


class PlistAndRedactionTests(CliTestCase):
    def test_rendered_plist_escapes_paths_and_check_detects_mismatch(self):
        destination = self.tmp / "service.plist"
        home = str(self.tmp / "home & workspace")
        config = str(self.tmp / "config & active.json")
        log_out = str(self.tmp / "out & log")
        log_err = str(self.tmp / "err & log")
        result = self.run_cli(
            "render-plist",
            destination,
            "--template",
            ROOT / "templates" / "launchagent.plist.template",
            "--label",
            "com.xst.fixture",
            "--xray-bin",
            "/opt/example/xray",
            "--config",
            config,
            "--home",
            home,
            "--log-out",
            log_out,
            "--log-err",
            log_err,
            "--user-name",
            "fixture-user",
        )
        self.assert_ok(result)
        parsed = plistlib.loads(destination.read_bytes())
        self.assertEqual(parsed["WorkingDirectory"], home)
        self.assertIn(config, parsed["ProgramArguments"])

        checked = self.run_cli(
            "check-plist",
            destination,
            "--label",
            "com.xst.fixture",
            "--xray-bin",
            "/opt/example/xray",
            "--config",
            config,
            "--home",
            home,
            "--user-name",
            "fixture-user",
        )
        self.assert_ok(checked)
        self.assert_clean_failure(
            self.run_cli(
                "check-plist",
                destination,
                "--label",
                "com.xst.wrong",
                "--xray-bin",
                "/opt/example/xray",
                "--config",
                config,
                "--home",
                home,
                "--user-name",
                "fixture-user",
            )
        )

        strict = self.run_cli(
            "check-plist",
            destination,
            "--label",
            "com.xst.fixture",
            "--xray-bin",
            "/opt/example/xray",
            "--config",
            config,
            "--home",
            home,
            "--user-name",
            "fixture-user",
            "--strict-hardening",
            "--log-out",
            log_out,
            "--log-err",
            log_err,
        )
        self.assert_ok(strict)

        legacy = dict(parsed)
        for key in (
            "Umask",
            "ProcessType",
            "ThrottleInterval",
            "StandardOutPath",
            "StandardErrorPath",
        ):
            legacy.pop(key)
        legacy_path = self.tmp / "legacy.plist"
        with legacy_path.open("wb") as handle:
            plistlib.dump(legacy, handle)
        legacy_core_check = self.run_cli(
            "check-plist",
            legacy_path,
            "--label",
            "com.xst.fixture",
            "--xray-bin",
            "/opt/example/xray",
            "--config",
            config,
            "--home",
            home,
            "--user-name",
            "fixture-user",
        )
        strict_legacy_check = self.run_cli(
            "check-plist",
            legacy_path,
            "--label",
            "com.xst.fixture",
            "--xray-bin",
            "/opt/example/xray",
            "--config",
            config,
            "--home",
            home,
            "--user-name",
            "fixture-user",
            "--strict-hardening",
            "--log-out",
            log_out,
            "--log-err",
            log_err,
        )
        strict_wrong_log_path = self.run_cli(
            "check-plist",
            destination,
            "--label",
            "com.xst.fixture",
            "--xray-bin",
            "/opt/example/xray",
            "--config",
            config,
            "--home",
            home,
            "--user-name",
            "fixture-user",
            "--strict-hardening",
            "--log-out",
            str(self.tmp / "wrong.log"),
            "--log-err",
            log_err,
        )
        self.assert_ok(legacy_core_check)
        self.assert_clean_failure(strict_legacy_check)
        self.assert_clean_failure(strict_wrong_log_path)

        unexpected = dict(parsed)
        unexpected["EnvironmentVariables"] = {"DYLD_INSERT_LIBRARIES": "/tmp/evil"}
        unexpected_path = self.tmp / "unexpected-key.plist"
        with unexpected_path.open("wb") as handle:
            plistlib.dump(unexpected, handle)
        strict_unexpected = self.run_cli(
            "check-plist",
            unexpected_path,
            "--label",
            "com.xst.fixture",
            "--xray-bin",
            "/opt/example/xray",
            "--config",
            config,
            "--home",
            home,
            "--user-name",
            "fixture-user",
            "--strict-hardening",
            "--log-out",
            log_out,
            "--log-err",
            log_err,
        )
        self.assert_clean_failure(strict_unexpected)

    def test_log_redaction_hides_keys_uuid_and_ip(self):
        log = self.tmp / "xray.log"
        log.write_text(
            'id=123e4567-e89b-12d3-a456-426614174000 '
            'publicKey="fixture-key" address=203.0.113.42\n',
            encoding="utf-8",
        )
        result = self.run_cli("redact-log", log)
        self.assert_ok(result)
        self.assertNotIn("123e4567", result.stdout)
        self.assertNotIn("fixture-key", result.stdout)
        self.assertNotIn("203.0.113.42", result.stdout)

    def test_log_redaction_hides_all_endpoint_forms_and_json_secrets(self):
        log = self.tmp / "xray.log"
        sensitive_values = (
            "198.51.100.22:8443",
            "[2001:db8::1]:443",
            "2001:db8:1::5",
            "edge.secret.example.com:443",
            "vpn.hidden.invalid:9443",
            "topsecret",
            "sni.hidden.invalid",
            "123e4567-e89b-12d3-a456-426614174000",
            "intranet",
            "gateway",
        )
        log.write_text(
            "connection failed retrying remote=%s ipv6=%s raw=%s host=%s\n"
            '{"address":"%s","password":"%s",'
            '"serverName":"%s","uuid":"%s"} useful diagnostic '
            "tcp:%s:443 dial %s:8443\n"
            % sensitive_values,
            encoding="utf-8",
        )

        result = self.run_cli("redact-log", log, "--lines", "20")

        self.assert_ok(result)
        for value in sensitive_values:
            self.assertNotIn(value, result.stdout)
        self.assertIn("connection failed retrying", result.stdout)
        self.assertIn("useful diagnostic", result.stdout)
        self.assertIn("<redacted", result.stdout)

        xstlib = load_xstlib()
        punctuated = xstlib.redact_log_line(
            "remote:203.0.113.8:443 connected api.secret.invalid. failed"
        )
        self.assertNotIn("203.0.113.8", punctuated)
        self.assertNotIn("api.secret.invalid", punctuated)

    def test_redact_log_reads_only_a_bounded_tail_from_end(self):
        xstlib = load_xstlib()

        class TrackingLog(io.BytesIO):
            def __init__(self, payload):
                super().__init__(payload)
                self.bytes_read = 0

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc_value, traceback):
                return False

            def read(self, size=-1):
                result = super().read(size)
                self.bytes_read += len(result)
                return result

            def close(self):
                pass

        payload = b"".join(
            ("diagnostic line %d\n" % index).encode("utf-8")
            for index in range(200000)
        )
        stream = TrackingLog(payload)
        output = io.StringIO()
        args = types.SimpleNamespace(paths=["mock.log"], lines=3)
        with mock.patch("builtins.open", return_value=stream):
            with redirect_stdout(output):
                xstlib.cmd_redact_log(args)

        self.assertEqual(
            output.getvalue().splitlines(),
            [
                "diagnostic line 199997",
                "diagnostic line 199998",
                "diagnostic line 199999",
            ],
        )
        self.assertLessEqual(stream.bytes_read, xstlib.MAX_LOG_TAIL_BYTES)

    def test_redact_log_validates_tail_line_bounds(self):
        missing = self.tmp / "missing.log"
        for value in ("0", "-1", "1001"):
            with self.subTest(lines=value):
                self.assert_clean_failure(
                    self.run_cli("redact-log", missing, "--lines", value)
                )

        accepted = self.run_cli("redact-log", missing, "--lines", "1000")
        self.assert_ok(accepted)


class RouteCheckTests(CliTestCase):
    def setUp(self):
        super().setUp()
        result, self.config = self.apply_config(
            domains="corp.example.invalid",
            cidrs="100.64.0.0/10",
        )
        self.assert_ok(result)

    def route(self, host):
        result = self.run_cli("route-check", self.config, host)
        self.assert_ok(result)
        return result.stdout.split("\t", 1)[0]

    def test_route_check_accepts_confidential_host_on_stdin(self):
        result = subprocess.run(
            [
                sys.executable,
                str(XSTLIB_PATH),
                "route-check",
                str(self.config),
                "--host-stdin",
            ],
            cwd=str(ROOT),
            input="service.corp.example.invalid",
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )

        self.assert_ok(result)
        self.assertEqual(result.stdout.split("\t", 1)[0], "direct")

    def test_generated_domain_rule_matches_exact_name_and_subdomains_only(self):
        self.assertEqual(self.route("corp.example.invalid"), "direct")
        self.assertEqual(self.route("api.corp.example.invalid"), "direct")
        self.assertEqual(self.route("CORP.EXAMPLE.INVALID."), "direct")
        self.assertEqual(self.route("notcorp.example.invalid"), "proxy")
        self.assertEqual(
            self.route("corp.example.invalid.attacker.invalid"), "proxy"
        )

    def test_generated_ip_rules_match_private_link_local_and_custom_networks(self):
        expected = {
            "127.0.0.1": "direct",
            "10.23.4.5": "direct",
            "169.254.4.5": "direct",
            "192.168.10.20": "direct",
            "fd00::1": "direct",
            "fe80::1": "direct",
            "100.64.12.34": "direct",
            "203.0.113.10": "proxy",
            "2001:db8::10": "proxy",
        }
        for host, tag in expected.items():
            with self.subTest(host=host):
                self.assertEqual(self.route(host), tag)

    def test_unrelated_provider_rules_remain_effective(self):
        self.assertEqual(self.route("ads.example.invalid"), "block")
        self.assertEqual(self.route("www.example.invalid"), "proxy")

    def test_route_check_rejects_non_host_input(self):
        for host in (
            "",
            "https://corp.example.invalid/path",
            "10.0.0.0/8",
            "bad host",
            "a\nb",
        ):
            with self.subTest(host=host):
                self.assert_clean_failure(
                    self.run_cli("route-check", self.config, host)
                )


if __name__ == "__main__":
    unittest.main()
