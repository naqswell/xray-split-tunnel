#!/usr/bin/env python3
"""Safe, dependency-free helpers for xray-split-tunnel.

The subscription is treated as untrusted input.  Only outbound definitions and
provider block rules are carried into the generated config.  Inbounds, DNS,
logging, API/metrics and routing policy are owned by this project.
"""

import argparse
import copy
import hashlib
import ipaddress
import json
import os
import plistlib
import re
import sys
import tempfile
import unicodedata


PRIVATE_IPS = [
    "geoip:private",
    "127.0.0.0/8",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "169.254.0.0/16",
    "::1/128",
    "fc00::/7",
    "fe80::/10",
]

PRIVATE_NETS = [
    ipaddress.ip_network(value)
    for value in PRIVATE_IPS
    if not value.startswith("geoip:")
]

ALLOWED_PROXY_PROTOCOLS = {
    "hysteria",
    "http",
    "shadowsocks",
    "socks",
    "trojan",
    "vless",
    "vmess",
    "wireguard",
}
MAX_CONFIGS = 512
NAME_KEYS = ("remarks", "remark", "name", "ps", "tag")
TAG_RE = re.compile(r"^[A-Za-z0-9._-]{1,96}$")
LABEL_RE = re.compile(r"^[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?$")
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f-\x9f]")
UUID_RE = re.compile(
    r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"
)
SENSITIVE_VALUE_RE = re.compile(
    r"""(?ix)
    (?P<prefix>
        (?:"?
            (?:address|endpoint|host|id|password|privatekey|publickey|
               secret|server|servername|shortid|sni|token|uuid)
        "?)
        \s*[:=]\s*
    )
    (?P<value>
        "(?:\\.|[^"\\])*"
        |
        [^\s,}\]]+
    )
    """
)
BRACKETED_IPV6_RE = re.compile(
    r"(?<![A-Za-z0-9])\[(?P<address>[0-9A-Fa-f:.]+"
    r"(?:%[A-Za-z0-9_.-]+)?)\](?::\d{1,5})?"
)
UNBRACKETED_IPV6_RE = re.compile(
    r"(?<![A-Za-z0-9_.-])"
    r"(?P<address>(?:[0-9A-Fa-f]{0,4}:){2,}"
    r"[0-9A-Fa-f:.]{0,15}(?:%[A-Za-z0-9_.-]+)?)"
    r"(?![A-Za-z0-9_.-])"
)
IPV4_ENDPOINT_RE = re.compile(
    r"(?<![A-Za-z0-9_.-])(?:\d{1,3}\.){3}\d{1,3}"
    r"(?::\d{1,5})?(?![A-Za-z0-9_.:-])"
)
FQDN_ENDPOINT_RE = re.compile(
    r"(?ix)"
    r"(?<![A-Za-z0-9_.-])"
    r"(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+"
    r"(?:[A-Za-z]{2,63}|xn--[A-Za-z0-9-]{1,59})"
    r"\.?"
    r"(?::\d{1,5})?"
    r"(?![A-Za-z0-9_.-])"
)
PROTOCOL_ENDPOINT_RE = re.compile(
    r"(?i)\b(?P<scheme>tcp|udp|tls|quic|http|https):"
    r"(?P<host>[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)"
    r"(?::\d{1,5})?"
)
SINGLE_LABEL_PORT_RE = re.compile(
    r"(?i)(?<![A-Za-z0-9_.-])"
    r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
    r":\d{1,5}(?![A-Za-z0-9_.:-])"
)
MAX_BYPASS_INPUT_BYTES = 1024 * 1024
MAX_LOG_TAIL_BYTES = 1024 * 1024


def die(message):
    print("xstlib: " + str(message), file=sys.stderr)
    raise SystemExit(1)


def load_json(path):
    try:
        if os.path.getsize(path) > 10 * 1024 * 1024:
            die("JSON-файл превышает лимит 10 MiB: " + str(path))
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        die("файл не найден: " + str(path))
    except (OSError, ValueError) as exc:
        die("не валидный JSON (%s): %s" % (path, exc))


def save_json(path, data):
    """Serialize next to *path*, fsync, chmod 0600 and atomically replace it."""
    path = os.path.abspath(path)
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, mode=0o700, exist_ok=True)
    descriptor = None
    temporary = None
    try:
        descriptor, temporary = tempfile.mkstemp(
            prefix=".%s." % os.path.basename(path),
            suffix=".tmp",
            dir=directory,
        )
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            descriptor = None
            json.dump(data, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        temporary = None
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def save_plist(path, data):
    """Write an XML plist atomically with mode 0600."""
    path = os.path.abspath(path)
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, mode=0o700, exist_ok=True)
    descriptor = None
    temporary = None
    try:
        descriptor, temporary = tempfile.mkstemp(
            prefix=".%s." % os.path.basename(path),
            suffix=".tmp",
            dir=directory,
        )
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = None
            plistlib.dump(data, handle, fmt=plistlib.FMT_XML, sort_keys=False)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        temporary = None
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def normalize_name_scalar(value):
    if value is None:
        return None
    text = unicodedata.normalize("NFKC", str(value))
    text = "".join(
        " " if unicodedata.category(character).startswith("C") else character
        for character in text
    )
    text = " ".join(text.split())
    return text or None


def explicit_name_of(item):
    for key in NAME_KEYS:
        text = normalize_name_scalar(item.get(key))
        if text is not None:
            return text
    return None


def explicit_remarks_of(item):
    """Backward-compatible alias for the full, untruncated explicit identity."""
    return explicit_name_of(item)


def remarks_of(item, index):
    explicit = explicit_name_of(item)
    if explicit is not None:
        return explicit[:120]
    return "server %d" % index


def identity_digest_of(item):
    explicit = explicit_name_of(item)
    if explicit is None:
        return None
    return hashlib.sha256(explicit.casefold().encode("utf-8")).hexdigest()


def validate_config_item(item, index):
    if not isinstance(item, dict):
        die("элемент подписки #%d должен быть JSON-объектом" % index)
    outbounds = item.get("outbounds")
    if not isinstance(outbounds, list) or not outbounds:
        die("элемент подписки #%d содержит некорректный 'outbounds'" % index)
    for outbound_index, outbound in enumerate(outbounds):
        if not isinstance(outbound, dict):
            die(
                "outbound #%d в конфиге #%d должен быть JSON-объектом"
                % (outbound_index, index)
            )
        protocol = outbound.get("protocol")
        if not isinstance(protocol, str) or not protocol:
            die(
                "outbound #%d в конфиге #%d не содержит protocol"
                % (outbound_index, index)
            )


def enforce_config_limit(candidates):
    if len(candidates) > MAX_CONFIGS:
        die(
            "подписка содержит слишком много элементов: %d; лимит — %d"
            % (len(candidates), MAX_CONFIGS)
        )


def load_subscription(path):
    subscription = load_json(path)
    if not isinstance(subscription, list) or not subscription:
        die("нормализованная подписка должна быть непустым JSON-массивом")
    enforce_config_limit(subscription)
    for index, item in enumerate(subscription):
        validate_config_item(item, index)
    return subscription


def extract_subscription_items(raw):
    if isinstance(raw, list):
        candidates = raw
    elif isinstance(raw, dict):
        if "outbounds" in raw:
            candidates = [raw]
        else:
            candidates = None
            for key in ("configs", "servers", "items", "data", "subscription"):
                value = raw.get(key)
                if isinstance(value, list):
                    candidates = value
                    break
            if candidates is None:
                die(
                    "неизвестная структура подписки: нет outbounds и списка "
                    "configs/servers/items/data/subscription"
                )
    else:
        die(
            "подписка должна быть JSON-массивом или объектом, получено: %s"
            % type(raw).__name__
        )

    enforce_config_limit(candidates)
    configs = []
    for index, item in enumerate(candidates):
        if not isinstance(item, dict) or "outbounds" not in item:
            continue
        validate_config_item(item, index)
        configs.append(item)
    if not configs:
        die(
            "в подписке нет XRay-конфигов с непустым списком outbounds; "
            "см. docs/subscription-format.md"
        )
    return configs


def split_csv(value):
    if not value:
        return []
    return [part.strip() for part in value.split(",") if part.strip()]


def normalize_domain(value):
    candidate = value.strip().lower().lstrip(".").rstrip(".")
    if (
        not candidate
        or len(candidate) > 253
        or "://" in candidate
        or "*" in candidate
        or "/" in candidate
        or ":" in candidate
        or CONTROL_RE.search(candidate)
        or any(character.isspace() for character in candidate)
    ):
        die("некорректный домен в обход: %r" % value)
    try:
        ipaddress.ip_address(candidate)
    except ValueError:
        pass
    else:
        die("IP-адрес нужно указывать в BYPASS_CIDRS, не в BYPASS_DOMAINS")

    labels = candidate.split(".")
    normalized = []
    for label in labels:
        try:
            ascii_label = label.encode("idna").decode("ascii")
        except UnicodeError:
            die("некорректный IDN-домен: %r" % value)
        if not LABEL_RE.match(ascii_label):
            die("некорректная метка домена %r в %r" % (label, value))
        normalized.append(ascii_label.lower())
    return ".".join(normalized)


def normalize_domains(value):
    result = []
    seen = set()
    for domain in split_csv(value):
        normalized = normalize_domain(domain)
        if normalized not in seen:
            seen.add(normalized)
            result.append(normalized)
    return result


def normalize_cidrs(value):
    result = []
    seen = set()
    for cidr in split_csv(value):
        try:
            network = ipaddress.ip_network(cidr, strict=False)
        except ValueError:
            die("некорректная подсеть в обход: %r" % cidr)
        if network.prefixlen == 0:
            die("маршрут по умолчанию %s запрещён в BYPASS_CIDRS" % network)
        normalized = str(network)
        if normalized not in seen and normalized not in PRIVATE_IPS:
            seen.add(normalized)
            result.append(normalized)
    return result


def validate_ports(http_port, socks_port):
    values = []
    for name, raw in (("HTTP", http_port), ("SOCKS", socks_port)):
        try:
            port = int(raw)
        except (TypeError, ValueError):
            die("%s-порт должен быть числом" % name)
        if not 1 <= port <= 65535:
            die("%s-порт вне диапазона 1..65535: %s" % (name, raw))
        values.append(port)
    if values[0] == values[1]:
        die("HTTP- и SOCKS-порты должны различаться")
    return values


def controlled_inbounds(http_port, socks_port):
    sniffing = {
        "enabled": True,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": True,
    }
    return [
        {
            "tag": "xst-http-in",
            "protocol": "http",
            "listen": "127.0.0.1",
            "port": http_port,
            "sniffing": copy.deepcopy(sniffing),
        },
        {
            "tag": "xst-socks-in",
            "protocol": "socks",
            "listen": "127.0.0.1",
            "port": socks_port,
            "settings": {"auth": "noauth", "udp": True},
            "sniffing": copy.deepcopy(sniffing),
        },
    ]


def controlled_outbounds(source):
    raw = source.get("outbounds")
    validate_config_item(source, 0)

    primary = raw[0]
    primary_protocol = str(primary.get("protocol", "")).lower()
    if primary.get("tag") in ("direct", "block"):
        die(
            "первый proxy outbound не может использовать зарезервированный "
            "tag %r" % primary.get("tag")
        )
    if primary_protocol not in ALLOWED_PROXY_PROTOCOLS:
        die(
            "первый outbound должен быть прокси (%s), получено: %s"
            % (", ".join(sorted(ALLOWED_PROXY_PROTOCOLS)), primary_protocol or "пусто")
        )

    result = []
    tags = set()
    for index, outbound in enumerate(raw):
        protocol = str(outbound.get("protocol", "")).lower()
        original_tag = outbound.get("tag")
        if original_tag in ("direct", "block"):
            continue
        if protocol not in ALLOWED_PROXY_PROTOCOLS:
            # Provider direct/DNS/control outbounds are not part of the
            # managed policy. Dropping them also makes xray -test reject any
            # proxySettings/dialer reference that tried to bypass the proxy
            # through such an outbound.
            continue
        item = copy.deepcopy(outbound)
        tag = original_tag or ("xst-proxy" if index == 0 else "xst-outbound-%d" % index)
        if not isinstance(tag, str) or not TAG_RE.match(tag):
            die("некорректный outbound tag: %r" % tag)
        if tag in tags:
            die("повторяющийся outbound tag: %s" % tag)
        tags.add(tag)
        item["tag"] = tag
        item["protocol"] = protocol
        result.append(item)

    if not result:
        die("после нормализации не осталось proxy outbound")
    if (
        result[0].get("protocol") not in ALLOWED_PROXY_PROTOCOLS
        or result[0].get("tag") in ("direct", "block")
    ):
        die("первый outbound после нормализации не является proxy outbound")
    result.append({"tag": "direct", "protocol": "freedom"})
    result.append({"tag": "block", "protocol": "blackhole"})
    return result


def preserved_block_rules(source):
    result = []
    routing = source.get("routing")
    if not isinstance(routing, dict):
        return result
    rules = routing.get("rules")
    if not isinstance(rules, list):
        return result
    for rule in rules:
        if (
            isinstance(rule, dict)
            and rule.get("type", "field") == "field"
            and rule.get("outboundTag") == "block"
        ):
            result.append(copy.deepcopy(rule))
    return result


def controlled_routing(source, domains, cidrs):
    rules = []
    if domains:
        rules.append(
            {
                "type": "field",
                "outboundTag": "direct",
                "domain": ["domain:" + domain for domain in domains],
            }
        )
    rules.append(
        {
            "type": "field",
            "outboundTag": "direct",
            "ip": PRIVATE_IPS + cidrs,
        }
    )
    rules.extend(preserved_block_rules(source))
    return {
        # Domain rules are evaluated before resolution.  If no domain rule
        # matches, system DNS may resolve the target for custom CIDR matching.
        "domainStrategy": "IPIfNonMatch",
        "rules": rules,
    }


def build_config(source, http_port, socks_port, domains, cidrs):
    return {
        "log": {"loglevel": "warning"},
        "inbounds": controlled_inbounds(http_port, socks_port),
        "outbounds": controlled_outbounds(source),
        "routing": controlled_routing(source, domains, cidrs),
    }


def validate_host(value):
    host = value.strip().lower().rstrip(".")
    if (
        not host
        or CONTROL_RE.search(host)
        or any(character.isspace() for character in host)
        or "://" in host
        or "/" in host
    ):
        die("ожидается домен или одиночный IP-адрес, получено: %r" % value)
    try:
        return str(ipaddress.ip_address(host)), True
    except ValueError:
        return normalize_domain(host), False


def domain_matches(pattern, host):
    pattern = str(pattern)
    if pattern.startswith("domain:"):
        suffix = pattern[len("domain:") :].lower().rstrip(".")
        return host == suffix or host.endswith("." + suffix)
    if pattern.startswith("full:"):
        return host == pattern[len("full:") :].lower().rstrip(".")
    if pattern.startswith("keyword:"):
        return pattern[len("keyword:") :].lower() in host
    if pattern.startswith(("geosite:", "regexp:", "ext:")):
        return None
    return pattern.lower() in host


def ip_matches(pattern, address):
    pattern = str(pattern)
    if pattern == "geoip:private":
        return any(address in network for network in PRIVATE_NETS)
    if pattern.startswith("geoip:"):
        return None
    try:
        return address in ipaddress.ip_network(pattern, strict=False)
    except ValueError:
        return None


def rule_matches_offline(rule, host, address):
    supported = {"type", "outboundTag", "domain", "ip", "ruleTag"}
    if any(key not in supported for key in rule):
        return None, "unsupported-condition"

    domains = rule.get("domain") or []
    ips = rule.get("ip") or []
    if domains and ips:
        return None, "combined-domain-ip"
    if address is None and domains:
        unknown = False
        for pattern in domains:
            result = domain_matches(pattern, host)
            if result:
                return True, "domain %s" % pattern
            if result is None:
                unknown = True
        return (None, "unknown-domain-pattern") if unknown else (False, "")
    if address is not None and ips:
        unknown = False
        for pattern in ips:
            result = ip_matches(pattern, address)
            if result:
                return True, "ip %s" % pattern
            if result is None:
                unknown = True
        return (None, "unknown-ip-pattern") if unknown else (False, "")
    return False, ""


def cmd_normalize(args):
    configs = extract_subscription_items(load_json(args.src))
    save_json(args.dst, configs)
    print(len(configs))


def cmd_list(args):
    subscription = load_subscription(args.sub)
    for index, item in enumerate(subscription):
        marker = "  <- активен" if str(index) == str(args.current) else ""
        print("  [%2d] %s%s" % (index, remarks_of(item, index), marker))


def cmd_resolve(args):
    subscription = load_subscription(args.sub)
    target = args.target.strip()
    if not target:
        die("сервер не задан")
    if target.isdigit():
        index = int(target)
        if not 0 <= index < len(subscription):
            die("индекс %d вне диапазона 0..%d" % (index, len(subscription) - 1))
        print(index)
        return

    lowered = target.lower()
    exact_matches = [
        index
        for index, item in enumerate(subscription)
        if lowered == remarks_of(item, index).lower()
    ]
    if len(exact_matches) == 1:
        print(exact_matches[0])
        return
    if len(exact_matches) > 1:
        die("неоднозначный выбор: несколько серверов имеют имя %r" % target)
    matches = [
        index
        for index, item in enumerate(subscription)
        if lowered in remarks_of(item, index).lower()
    ]
    if len(matches) == 1:
        print(matches[0])
    elif not matches:
        die("сервер не найден по %r" % target)
    else:
        names = ", ".join(
            "[%d] %s" % (index, remarks_of(subscription[index], index))
            for index in matches
        )
        die("неоднозначный выбор, подходят: %s" % names)


def cmd_resolve_exact(args):
    subscription = load_subscription(args.sub)
    target = args.target.strip()
    if not target:
        die("имя сервера не задано")

    folded = target.casefold()
    matches = []
    for index, item in enumerate(subscription):
        explicit_name = explicit_name_of(item)
        if explicit_name is not None and folded == explicit_name.casefold():
            matches.append(index)
    if len(matches) == 1:
        print(matches[0])
    elif not matches:
        die("сервер с точным именем %r не найден" % target)
    else:
        die("неоднозначное точное имя: несколько серверов имеют имя %r" % target)


def cmd_resolve_identity(args):
    subscription = load_subscription(args.sub)
    if not re.fullmatch(r"[0-9a-f]{64}", args.identity):
        die("identity должен быть SHA-256 в lowercase hex")
    matches = [
        index
        for index, item in enumerate(subscription)
        if identity_digest_of(item) == args.identity
    ]
    if len(matches) == 1:
        print(matches[0])
    elif not matches:
        die("сервер с сохранённой identity не найден")
    else:
        die("неоднозначная identity: несколько серверов имеют одно exact имя")


def cmd_name(args):
    subscription = load_subscription(args.sub)
    try:
        index = int(args.index)
    except (TypeError, ValueError):
        die("индекс сервера должен быть числом")
    if not 0 <= index < len(subscription):
        die("индекс %d вне диапазона 0..%d" % (index, len(subscription) - 1))
    explicit = explicit_name_of(subscription[index])
    if args.require_explicit and explicit is None:
        die("у активного сервера нет стабильного имени; update требует ручной switch")
    if args.require_explicit:
        print(explicit)
    else:
        print(remarks_of(subscription[index], index))


def cmd_identity(args):
    subscription = load_subscription(args.sub)
    try:
        index = int(args.index)
    except (TypeError, ValueError):
        die("индекс сервера должен быть числом")
    if not 0 <= index < len(subscription):
        die("индекс %d вне диапазона 0..%d" % (index, len(subscription) - 1))
    identity = identity_digest_of(subscription[index])
    if identity is None:
        die("у активного сервера нет стабильного имени; update требует ручной switch")
    print(identity)


def read_bypass_inputs(args):
    if not args.bypass_stdin:
        return args.bypass_domains, args.bypass_cidrs
    if args.bypass_domains or args.bypass_cidrs:
        die("--bypass-stdin нельзя смешивать с bypass-аргументами")
    payload = sys.stdin.buffer.read(MAX_BYPASS_INPUT_BYTES + 1)
    if len(payload) > MAX_BYPASS_INPUT_BYTES:
        die("routing inputs превышают лимит 1 MiB")
    parts = payload.split(b"\0")
    if len(parts) != 3 or parts[-1] != b"":
        die("--bypass-stdin ожидает два NUL-terminated UTF-8 значения")
    try:
        return parts[0].decode("utf-8"), parts[1].decode("utf-8")
    except UnicodeDecodeError:
        die("routing inputs должны быть UTF-8")


def cmd_apply(args):
    subscription = load_subscription(args.sub)
    try:
        index = int(args.index)
    except (TypeError, ValueError):
        die("индекс сервера должен быть числом")
    if not 0 <= index < len(subscription):
        die("индекс %d вне диапазона 0..%d" % (index, len(subscription) - 1))

    http_port, socks_port = validate_ports(args.http_port, args.socks_port)
    bypass_domains, bypass_cidrs = read_bypass_inputs(args)
    domains = normalize_domains(bypass_domains)
    cidrs = normalize_cidrs(bypass_cidrs)
    config = build_config(
        subscription[index], http_port, socks_port, domains, cidrs
    )
    save_json(args.dst, config)
    print(remarks_of(subscription[index], index))


def cmd_validate_inputs(args):
    http_port, socks_port = validate_ports(args.http_port, args.socks_port)
    bypass_domains, bypass_cidrs = read_bypass_inputs(args)
    result = {
        "http_port": http_port,
        "socks_port": socks_port,
        "bypass_domains": ",".join(normalize_domains(bypass_domains)),
        "bypass_cidrs": ",".join(normalize_cidrs(bypass_cidrs)),
    }
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))


def cmd_render_plist(args):
    if not TAG_RE.match(args.label):
        die("некорректный launchd label: %r" % args.label)
    for name, path in (
        ("xray", args.xray_bin),
        ("config", args.config),
        ("working directory", args.home),
        ("stdout log", args.log_out),
        ("stderr log", args.log_err),
    ):
        if not os.path.isabs(path) or CONTROL_RE.search(path):
            die("%s path должен быть абсолютным и без control-символов" % name)
    try:
        with open(args.template, "rb") as handle:
            data = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as exc:
        die("не удалось прочитать plist template: %s" % exc)
    replacements = {
        "__LABEL__": args.label,
        "__XRAY_BIN__": args.xray_bin,
        "__CONFIG__": args.config,
        "__HOME__": args.home,
        "__LOG_OUT__": args.log_out,
        "__LOG_ERR__": args.log_err,
    }

    def replace(value):
        if isinstance(value, str):
            for placeholder, replacement in replacements.items():
                value = value.replace(placeholder, replacement)
            return value
        if isinstance(value, list):
            return [replace(item) for item in value]
        if isinstance(value, dict):
            return {key: replace(item) for key, item in value.items()}
        return value

    data = replace(data)
    if args.user_name:
        if CONTROL_RE.search(args.user_name) or not args.user_name.strip():
            die("некорректный UserName")
        data["UserName"] = args.user_name
    save_plist(args.dst, data)


def cmd_check_plist(args):
    try:
        with open(args.path, "rb") as handle:
            data = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as exc:
        die("не удалось прочитать plist: %s" % exc)
    expected_arguments = [args.xray_bin, "run", "-config", args.config]
    if data.get("Label") != args.label:
        die("plist label не совпадает")
    if data.get("ProgramArguments") != expected_arguments:
        die("plist ProgramArguments не совпадают")
    if data.get("WorkingDirectory") != args.home:
        die("plist WorkingDirectory не совпадает")
    if data.get("RunAtLoad") is not True or data.get("KeepAlive") is not True:
        die("plist не содержит обязательные RunAtLoad/KeepAlive")
    actual_user = data.get("UserName", "")
    if actual_user != args.user_name:
        die("plist UserName не совпадает с service scope")
    if getattr(args, "strict_hardening", False):
        if not args.log_out or not args.log_err:
            die("--strict-hardening требует --log-out и --log-err")
        expected_hardening = {
            "Umask": 0o77,
            "ProcessType": "Background",
            "ThrottleInterval": 10,
            "StandardOutPath": args.log_out,
            "StandardErrorPath": args.log_err,
        }
        for key, expected in expected_hardening.items():
            if data.get(key) != expected:
                die("plist hardening %s не совпадает" % key)
        expected_keys = {
            "Label",
            "ProgramArguments",
            "WorkingDirectory",
            "RunAtLoad",
            "KeepAlive",
            "Umask",
            "ProcessType",
            "ThrottleInterval",
            "StandardOutPath",
            "StandardErrorPath",
        }
        if args.user_name:
            expected_keys.add("UserName")
        if set(data) != expected_keys:
            die("strict plist содержит неожиданные или отсутствующие keys")


def cmd_config_ports(args):
    config = load_json(args.config)
    if not isinstance(config, dict):
        die("XRay config должен быть JSON-объектом")
    inbounds = config.get("inbounds")
    if not isinstance(inbounds, list) or len(inbounds) != 2:
        die("config должен содержать ровно два managed inbound")

    expected = {
        "xst-http-in": "http",
        "xst-socks-in": "socks",
    }
    ports = {}
    for inbound in inbounds:
        if not isinstance(inbound, dict):
            die("managed inbound должен быть JSON-объектом")
        tag = inbound.get("tag")
        protocol = expected.get(tag)
        if protocol is None or tag in ports:
            die("config содержит неожиданный или повторяющийся managed inbound")
        if inbound.get("protocol") != protocol:
            die("protocol managed inbound %s не совпадает" % tag)
        if inbound.get("listen") != "127.0.0.1":
            die("managed inbound %s слушает не loopback" % tag)
        port = inbound.get("port")
        if isinstance(port, bool) or not isinstance(port, int):
            die("port managed inbound %s должен быть целым числом" % tag)
        if not 1 <= port <= 65535:
            die("port managed inbound %s вне диапазона 1..65535" % tag)
        ports[tag] = port

    if set(ports) != set(expected):
        die("config не содержит оба обязательных managed inbound")
    if ports["xst-http-in"] == ports["xst-socks-in"]:
        die("HTTP- и SOCKS-порты в config должны различаться")
    print("%d\t%d" % (ports["xst-http-in"], ports["xst-socks-in"]))


def cmd_route_check(args):
    config = load_json(args.config)
    if args.host_stdin:
        if args.host is not None:
            die("--host-stdin нельзя смешивать с positional host")
        candidate = sys.stdin.read(4097)
        if len(candidate) > 4096:
            die("route-check input превышает лимит 4096 байт")
    else:
        if args.host is None:
            die("route-check требует host или --host-stdin")
        candidate = args.host
    host, is_ip = validate_host(candidate)
    address = ipaddress.ip_address(host) if is_ip else None
    unknown = False
    rules = ((config.get("routing") or {}).get("rules") or [])

    for position, rule in enumerate(rules):
        if not isinstance(rule, dict):
            continue
        matched, reason = rule_matches_offline(rule, host, address)
        if matched:
            tag = str(rule.get("outboundTag", "?"))
            print("%s\trule#%d\t%s" % (tag, position, reason))
            return
        if matched is None:
            unknown = True

    outbounds = config.get("outbounds") or []
    default = "proxy"
    if outbounds and isinstance(outbounds[0], dict):
        default = (
            outbounds[0].get("tag")
            or outbounds[0].get("protocol")
            or "proxy"
        )
    note = "default-outbound"
    if unknown:
        note += " (часть provider rules нельзя доказать офлайн)"
    print("%s\t-\t%s" % (default, note))


def redact_sensitive_value(match):
    value = match.group("value")
    replacement = '"<redacted>"' if value.startswith('"') else "<redacted>"
    return match.group("prefix") + replacement


def redact_ipv6_candidate(match):
    candidate = match.group("address")
    address = candidate.rsplit("%", 1)[0]
    try:
        parsed = ipaddress.ip_address(address)
    except ValueError:
        return match.group(0)
    if parsed.version != 6:
        return match.group(0)
    return "<redacted-endpoint>"


def redact_log_line(line):
    line = SENSITIVE_VALUE_RE.sub(redact_sensitive_value, line)
    line = UUID_RE.sub("<redacted-uuid>", line)
    line = BRACKETED_IPV6_RE.sub(redact_ipv6_candidate, line)
    line = UNBRACKETED_IPV6_RE.sub(redact_ipv6_candidate, line)
    line = IPV4_ENDPOINT_RE.sub("<redacted-endpoint>", line)
    line = FQDN_ENDPOINT_RE.sub("<redacted-endpoint>", line)
    line = PROTOCOL_ENDPOINT_RE.sub(
        lambda match: match.group("scheme") + ":<redacted-endpoint>", line
    )
    line = SINGLE_LABEL_PORT_RE.sub("<redacted-endpoint>", line)
    return line


def bounded_tail_lines(path, line_count):
    with open(path, "rb") as handle:
        handle.seek(0, os.SEEK_END)
        position = handle.tell()
        chunks = []
        bytes_read = 0
        newline_count = 0
        while (
            position > 0
            and bytes_read < MAX_LOG_TAIL_BYTES
            and newline_count <= line_count
        ):
            chunk_size = min(65536, position, MAX_LOG_TAIL_BYTES - bytes_read)
            position -= chunk_size
            handle.seek(position)
            chunk = handle.read(chunk_size)
            if not chunk:
                break
            chunks.append(chunk)
            bytes_read += len(chunk)
            newline_count += chunk.count(b"\n")
    payload = b"".join(reversed(chunks))
    return [
        line.decode("utf-8", errors="replace")
        for line in payload.splitlines()[-line_count:]
    ]


def cmd_redact_log(args):
    if not 1 <= args.lines <= 1000:
        die("--lines должен быть в диапазоне 1..1000")
    for path in args.paths:
        try:
            lines = bounded_tail_lines(path, args.lines)
        except FileNotFoundError:
            continue
        except OSError as exc:
            die("не удалось прочитать лог %s: %s" % (path, exc))
        for line in lines:
            print(redact_log_line(line))


def add_apply_arguments(parser):
    parser.add_argument("--http-port", required=True)
    parser.add_argument("--socks-port", required=True)
    parser.add_argument("--bypass-domains", default="")
    parser.add_argument("--bypass-cidrs", default="")
    parser.add_argument("--bypass-stdin", action="store_true")


def main():
    parser = argparse.ArgumentParser(prog="xstlib")
    commands = parser.add_subparsers(dest="command")

    normalize = commands.add_parser("normalize")
    normalize.add_argument("src")
    normalize.add_argument("dst")
    normalize.set_defaults(func=cmd_normalize)

    list_parser = commands.add_parser("list")
    list_parser.add_argument("sub")
    list_parser.add_argument("--current", default="")
    list_parser.set_defaults(func=cmd_list)

    resolve = commands.add_parser("resolve")
    resolve.add_argument("sub")
    resolve.add_argument("target")
    resolve.set_defaults(func=cmd_resolve)

    resolve_exact = commands.add_parser("resolve-exact")
    resolve_exact.add_argument("sub")
    resolve_exact.add_argument("target")
    resolve_exact.set_defaults(func=cmd_resolve_exact)

    resolve_identity = commands.add_parser("resolve-identity")
    resolve_identity.add_argument("sub")
    resolve_identity.add_argument("identity")
    resolve_identity.set_defaults(func=cmd_resolve_identity)

    name_parser = commands.add_parser("name")
    name_parser.add_argument("sub")
    name_parser.add_argument("index")
    name_parser.add_argument("--require-explicit", action="store_true")
    name_parser.set_defaults(func=cmd_name)

    identity_parser = commands.add_parser("identity")
    identity_parser.add_argument("sub")
    identity_parser.add_argument("index")
    identity_parser.set_defaults(func=cmd_identity)

    apply_parser = commands.add_parser("apply")
    apply_parser.add_argument("sub")
    apply_parser.add_argument("index")
    apply_parser.add_argument("dst")
    add_apply_arguments(apply_parser)
    apply_parser.set_defaults(func=cmd_apply)

    validate = commands.add_parser("validate-inputs")
    add_apply_arguments(validate)
    validate.set_defaults(func=cmd_validate_inputs)

    render_plist = commands.add_parser("render-plist")
    render_plist.add_argument("--template", required=True)
    render_plist.add_argument("dst")
    render_plist.add_argument("--label", required=True)
    render_plist.add_argument("--xray-bin", required=True)
    render_plist.add_argument("--config", required=True)
    render_plist.add_argument("--home", required=True)
    render_plist.add_argument("--log-out", required=True)
    render_plist.add_argument("--log-err", required=True)
    render_plist.add_argument("--user-name", default="")
    render_plist.set_defaults(func=cmd_render_plist)

    check_plist = commands.add_parser("check-plist")
    check_plist.add_argument("path")
    check_plist.add_argument("--label", required=True)
    check_plist.add_argument("--xray-bin", required=True)
    check_plist.add_argument("--config", required=True)
    check_plist.add_argument("--home", required=True)
    check_plist.add_argument("--user-name", default="")
    check_plist.add_argument("--strict-hardening", action="store_true")
    check_plist.add_argument("--log-out", default="")
    check_plist.add_argument("--log-err", default="")
    check_plist.set_defaults(func=cmd_check_plist)

    config_ports = commands.add_parser("config-ports")
    config_ports.add_argument("config")
    config_ports.set_defaults(func=cmd_config_ports)

    route_check = commands.add_parser("route-check")
    route_check.add_argument("config")
    route_check.add_argument("host", nargs="?")
    route_check.add_argument("--host-stdin", action="store_true")
    route_check.set_defaults(func=cmd_route_check)

    redact_log = commands.add_parser("redact-log")
    redact_log.add_argument("paths", nargs="+")
    redact_log.add_argument("--lines", type=int, default=20)
    redact_log.set_defaults(func=cmd_redact_log)

    args = parser.parse_args()
    if not getattr(args, "func", None):
        parser.print_help()
        raise SystemExit(1)
    args.func(args)


if __name__ == "__main__":
    main()
