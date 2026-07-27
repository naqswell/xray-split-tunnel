import json
import re
import unittest
from pathlib import Path
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests" / "fixtures"
SENSITIVE_KEYS = {
    "id",
    "password",
    "privatekey",
    "publickey",
    "secret",
    "shortid",
    "shortids",
    "token",
    "subscriptionurl",
    "suburl",
    "uuid",
}
HOST_KEYS = {"address", "server", "servername", "sni"}
OPAQUE_VALUE = re.compile(r"^[A-Za-z0-9_+/=-]{40,}$")
UUID = re.compile(
    r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-"
    r"[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\b"
)
URL = re.compile(r"https?://[^\s\"']+")


def walk_json(value, path="$"):
    if isinstance(value, dict):
        for key, child in value.items():
            yield path + "." + str(key), str(key), child
            yield from walk_json(child, path + "." + str(key))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield "%s[%d]" % (path, index), None, child
            yield from walk_json(child, "%s[%d]" % (path, index))


def scalar_strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for child in value:
            yield from scalar_strings(child)


class SanitizedFixtureTests(unittest.TestCase):
    def test_fixture_directory_contains_json_only(self):
        files = sorted(path for path in FIXTURES.rglob("*") if path.is_file())
        self.assertTrue(files)
        self.assertTrue(
            all(path.suffix == ".json" for path in files),
            "fixtures must stay inspectable text JSON: %r" % files,
        )

    def test_json_fixtures_are_explicitly_sanitized_and_contain_no_secrets(self):
        for fixture in sorted(FIXTURES.glob("*.json")):
            with self.subTest(fixture=fixture.name):
                raw = fixture.read_text(encoding="utf-8")
                data = json.loads(raw)
                self.assertNotRegex(raw, UUID)
                self.assertNotIn("-----BEGIN ", raw)

                for match in URL.findall(raw):
                    parsed = urlsplit(match)
                    self.assertTrue(
                        (parsed.hostname or "").endswith(".invalid"),
                        "fixture URL must use a reserved .invalid host: %s" % match,
                    )
                    self.assertFalse(parsed.username)
                    self.assertFalse(parsed.password)
                    self.assertFalse(parsed.query)
                    self.assertFalse(parsed.fragment)

                configs = data.get("configs", []) if isinstance(data, dict) else []
                if isinstance(data, dict) and data.get("outbounds"):
                    configs = [data]
                for config in configs:
                    if isinstance(config, dict) and config.get("outbounds"):
                        self.assertEqual(config.get("_fixture"), "sanitized")

                for path, key, value in walk_json(data):
                    normalized_key = (key or "").lower()
                    if normalized_key in SENSITIVE_KEYS and value not in (None, ""):
                        values = list(scalar_strings(value))
                        self.assertTrue(values, path)
                        for secret_value in values:
                            self.assertTrue(
                                secret_value.startswith("fixture-"),
                                "%s must contain an obvious fixture sentinel" % path,
                            )
                    if normalized_key in HOST_KEYS and isinstance(value, str):
                        self.assertTrue(
                            value.endswith(".invalid"),
                            "%s must use a reserved .invalid host" % path,
                        )
                    if isinstance(value, str):
                        self.assertFalse(
                            OPAQUE_VALUE.fullmatch(value),
                            "%s looks like an opaque token/key" % path,
                        )


if __name__ == "__main__":
    unittest.main()
