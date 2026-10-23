#!/usr/bin/env python3
"""Certbot DNS-01 hook. DNS credentials stay on Laravel; never disable TLS."""
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import ssl
import stat
import sys
import time
import urllib.request
from urllib.parse import urlsplit

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

def load_config(path):
    path = Path(path)
    st = path.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or stat.S_IMODE(st.st_mode) != 0o600 or st.st_size > 16384:
        raise ValueError("private_config_required")
    data = json.loads(path.read_text())
    plane = urlsplit(data["control_plane"])
    if plane.scheme != "https" or not plane.hostname or plane.username or plane.password or plane.query or plane.fragment or plane.path not in ("", "/"):
        raise ValueError("invalid_control_plane")
    if len(data.get("key", "")) < 32:
        raise ValueError("invalid_binding_key")
    data["control_plane"] = data["control_plane"].rstrip("/")
    return data

def request(config, action, certificate=None):
    body = dict(action=action, client_id=config["client_id"], proxy_id=config["proxy_id"],
                control_plane=config["control_plane"], timestamp=int(time.time()), nonce=secrets.token_hex(16))
    if certificate is not None:
        body["certificate"] = certificate
    raw = json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    signature = hmac.new(config["key"].encode(), b"inoc-active-v1\n" + raw, hashlib.sha256).hexdigest()
    context = ssl.create_default_context(cafile=config.get("central_ca") or None)
    opener = urllib.request.build_opener(NoRedirect(), urllib.request.HTTPSHandler(context=context))
    req = urllib.request.Request(config["control_plane"] + "/api/remote-execution/active", data=raw,
                                 headers={"Content-Type": "application/json", "X-Inoc-Signature": signature})
    with opener.open(req, timeout=25) as response:
        if response.status != 200:
            raise ValueError("central_rejected")
        data = response.read(65537)
        if len(data) > 65536:
            raise ValueError("response_limit")
        return json.loads(data)

def run(config, action, env=os.environ, send=request, sleep=time.sleep):
    identity = send(config, "certificate-identity")
    hostname = identity.get("hostname", "")
    if not re.fullmatch(r"p-[a-f0-9]{32}\.(?:[a-z0-9-]+\.)+[a-z]{2,63}", hostname):
        raise ValueError("invalid_certificate_identity")
    if action == "identity":
        return hostname
    if action not in ("present", "cleanup") or env.get("CERTBOT_DOMAIN") != hostname:
        raise ValueError("certificate_scope_mismatch")
    value = env.get("CERTBOT_VALIDATION", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]{43}", value):
        raise ValueError("invalid_dns_validation")
    result = send(config, "certificate-dns-" + action, {"validation": value})
    if result.get("ok") is not True:
        raise ValueError("challenge_not_confirmed")
    if action == "present":
        delay = result.get("propagation_seconds")
        if not isinstance(delay, int) or delay < 30 or delay > 300:
            raise ValueError("invalid_propagation_delay")
        sleep(delay)
    return ""

if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError("arguments")
        result = run(load_config(sys.argv[1]), sys.argv[2])
        if result:
            print(result)
    except Exception:
        print("Proxy certificate authorization or DNS validation failed; existing certificate preserved.", file=sys.stderr)
        sys.exit(1)
