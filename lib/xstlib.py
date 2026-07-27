#!/usr/bin/env python3
"""xstlib — разбор subscription провайдера и сборка xray-конфига со split-tunnel правилами.

Вызывается из install.sh и bin/xst. Зависимостей нет, работает на системном
python3 macOS (3.9+).

Подкоманды:
  normalize <in.json> <out.json>          привести ответ провайдера к списку конфигов
  list <sub.json>                         показать серверы
  resolve <sub.json> <index|подстрока>    вернуть индекс сервера
  apply <sub.json> <index> <out.json> ... собрать активный конфиг
  route-check <config.json> <host>        куда уйдёт хост: direct / proxy / block
"""

import argparse
import copy
import ipaddress
import json
import sys

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
    ipaddress.ip_network(c) for c in PRIVATE_IPS if not c.startswith("geoip:")
]


def die(msg):
    print("xstlib: " + msg, file=sys.stderr)
    sys.exit(1)


def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        die("файл не найден: " + path)
    except ValueError as exc:
        die("не валидный JSON (%s): %s" % (path, exc))


def save_json(path, data):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write("\n")


def remarks_of(item, idx):
    for key in ("remarks", "remark", "name", "ps", "tag"):
        val = item.get(key)
        if val:
            return str(val)
    return "server %d" % idx


# ── normalize ──────────────────────────────────────────────────────────────
def cmd_normalize(args):
    raw = load_json(args.src)

    if isinstance(raw, list):
        items = raw
    elif isinstance(raw, dict):
        if "outbounds" in raw:
            items = [raw]
        else:
            items = None
            for key in ("configs", "servers", "items", "data", "subscription"):
                val = raw.get(key)
                if isinstance(val, list):
                    items = val
                    break
            if items is None:
                die(
                    "неизвестная структура подписки: объект без 'outbounds' и без "
                    "списка configs/servers/items/data. См. docs/subscription-format.md"
                )
    else:
        die("подписка должна быть JSON-массивом или объектом, получено: %s" % type(raw).__name__)

    good = [it for it in items if isinstance(it, dict) and it.get("outbounds")]
    if not good:
        die(
            "в подписке нет ни одного XRay-конфига (элемента с ключом 'outbounds'). "
            "Возможно, провайдер отдаёт base64/vless:// или sing-box — см. docs/subscription-format.md"
        )

    save_json(args.dst, good)
    print("%d" % len(good))


# ── list / resolve ─────────────────────────────────────────────────────────
def cmd_list(args):
    sub = load_json(args.sub)
    current = args.current
    for idx, item in enumerate(sub):
        mark = "  <- активен" if str(idx) == str(current) else ""
        print("  [%2d] %s%s" % (idx, remarks_of(item, idx), mark))


def cmd_resolve(args):
    sub = load_json(args.sub)
    target = args.target.strip()

    if target.isdigit():
        idx = int(target)
        if not (0 <= idx < len(sub)):
            die("индекс %d вне диапазона 0..%d" % (idx, len(sub) - 1))
        print(idx)
        return

    low = target.lower()
    matches = [i for i, it in enumerate(sub) if low in remarks_of(it, i).lower()]
    if len(matches) == 1:
        print(matches[0])
    elif not matches:
        die("сервер не найден по '%s'" % target)
    else:
        names = ", ".join("[%d] %s" % (i, remarks_of(sub[i], i)) for i in matches)
        die("неоднозначно, подходит несколько: %s" % names)


# ── apply ──────────────────────────────────────────────────────────────────
def split_csv(value):
    if not value:
        return []
    return [p.strip() for p in value.split(",") if p.strip()]


def force_local_inbounds(cfg, http_port, socks_port):
    inbounds = cfg.setdefault("inbounds", [])
    for inb in inbounds:
        inb["listen"] = "127.0.0.1"

    sniffing = {"enabled": True, "destOverride": ["http", "tls"]}

    http_in = next((i for i in inbounds if i.get("protocol") == "http"), None)
    if http_in is None:
        inbounds.append(
            {
                "tag": "http-in",
                "protocol": "http",
                "listen": "127.0.0.1",
                "port": http_port,
                "sniffing": sniffing,
            }
        )
    else:
        http_in["port"] = http_port
        http_in.setdefault("sniffing", sniffing)

    socks_in = next((i for i in inbounds if i.get("protocol") == "socks"), None)
    if socks_in is None:
        inbounds.append(
            {
                "tag": "socks-in",
                "protocol": "socks",
                "listen": "127.0.0.1",
                "port": socks_port,
                "settings": {"udp": True},
                "sniffing": sniffing,
            }
        )
    else:
        socks_in["port"] = socks_port
        socks_in.setdefault("sniffing", sniffing)


def ensure_outbounds(cfg):
    """Правила ссылаются на теги direct/block — если провайдер их не объявил, добавляем."""
    outbounds = cfg.setdefault("outbounds", [])
    tags = set(o.get("tag") for o in outbounds)
    if "direct" not in tags:
        outbounds.append({"protocol": "freedom", "tag": "direct"})
    if "block" not in tags:
        outbounds.append({"protocol": "blackhole", "tag": "block"})


def is_ours(rule):
    if not isinstance(rule, dict):
        return False
    if rule.get("outboundTag") != "direct":
        return False
    ips = rule.get("ip") or []
    doms = rule.get("domain") or []
    return "geoip:private" in ips or any(str(d).startswith("xst:") for d in doms)


def inject_rules(cfg, domains, cidrs):
    routing = cfg.setdefault("routing", {})
    routing.setdefault("domainStrategy", "AsIs")
    rules = [r for r in routing.get("rules", []) if not is_ours(r)]

    ip_rule = {
        "type": "field",
        "outboundTag": "direct",
        "ip": PRIVATE_IPS + [c for c in cidrs if c not in PRIVATE_IPS],
    }
    safety = [ip_rule]

    if domains:
        safety.append(
            {
                "type": "field",
                "outboundTag": "direct",
                "domain": ["domain:" + d.lstrip(".") for d in domains],
            }
        )

    routing["rules"] = safety + rules


def cmd_apply(args):
    sub = load_json(args.sub)
    idx = int(args.index)
    if not (0 <= idx < len(sub)):
        die("индекс %d вне диапазона 0..%d" % (idx, len(sub) - 1))

    cfg = copy.deepcopy(sub[idx])
    force_local_inbounds(cfg, int(args.http_port), int(args.socks_port))
    ensure_outbounds(cfg)
    inject_rules(cfg, split_csv(args.bypass_domains), split_csv(args.bypass_cidrs))
    save_json(args.dst, cfg)
    print(remarks_of(sub[idx], idx))


# ── route-check ────────────────────────────────────────────────────────────
def domain_matches(pattern, host):
    pattern = str(pattern)
    if pattern.startswith("domain:"):
        suffix = pattern[len("domain:"):]
        return host == suffix or host.endswith("." + suffix)
    if pattern.startswith("full:"):
        return host == pattern[len("full:"):]
    if pattern.startswith(("geosite:", "regexp:", "ext:")):
        return None
    if pattern.startswith("keyword:"):
        return pattern[len("keyword:"):] in host
    return pattern in host


def ip_matches(pattern, addr):
    pattern = str(pattern)
    if pattern == "geoip:private":
        return any(addr in net for net in PRIVATE_NETS)
    if pattern.startswith("geoip:"):
        return None
    try:
        return addr in ipaddress.ip_network(pattern, strict=False)
    except ValueError:
        return None


def cmd_route_check(args):
    cfg = load_json(args.config)
    host = args.host.strip().lower()

    try:
        addr = ipaddress.ip_address(host)
    except ValueError:
        addr = None

    rules = cfg.get("routing", {}).get("rules", []) or []
    unknown_hit = False

    for pos, rule in enumerate(rules):
        if not isinstance(rule, dict):
            continue
        tag = rule.get("outboundTag", "?")

        if addr is None:
            for pattern in rule.get("domain", []) or []:
                res = domain_matches(pattern, host)
                if res is None:
                    unknown_hit = True
                elif res:
                    print("%s\trule#%d\tdomain %s" % (tag, pos, pattern))
                    return 0
        else:
            for pattern in rule.get("ip", []) or []:
                res = ip_matches(pattern, addr)
                if res is None:
                    unknown_hit = True
                elif res:
                    print("%s\trule#%d\tip %s" % (tag, pos, pattern))
                    return 0

    default = "proxy"
    for outb in cfg.get("outbounds", []) or []:
        default = outb.get("tag") or outb.get("protocol") or "proxy"
        break

    note = "default-outbound"
    if unknown_hit:
        note += " (были geosite/geoip-правила — оффлайн-проверка их не разбирает)"
    print("%s\t-\t%s" % (default, note))
    return 0


def main():
    parser = argparse.ArgumentParser(prog="xstlib", add_help=True)
    sub = parser.add_subparsers(dest="cmd")

    p = sub.add_parser("normalize")
    p.add_argument("src")
    p.add_argument("dst")
    p.set_defaults(func=cmd_normalize)

    p = sub.add_parser("list")
    p.add_argument("sub")
    p.add_argument("--current", default="")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("resolve")
    p.add_argument("sub")
    p.add_argument("target")
    p.set_defaults(func=cmd_resolve)

    p = sub.add_parser("apply")
    p.add_argument("sub")
    p.add_argument("index")
    p.add_argument("dst")
    p.add_argument("--http-port", required=True)
    p.add_argument("--socks-port", required=True)
    p.add_argument("--bypass-domains", default="")
    p.add_argument("--bypass-cidrs", default="")
    p.set_defaults(func=cmd_apply)

    p = sub.add_parser("route-check")
    p.add_argument("config")
    p.add_argument("host")
    p.set_defaults(func=cmd_route_check)

    args = parser.parse_args()
    if not getattr(args, "func", None):
        parser.print_help()
        sys.exit(1)
    rc = args.func(args)
    sys.exit(rc or 0)


if __name__ == "__main__":
    main()
