#!/usr/bin/env python3
"""Read local runtime and send a scoped signed observation; never dispatch equipment commands."""
import datetime, hashlib, importlib.util, json, os, pathlib, re, socket, ssl, subprocess, sys, time

def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    obj = importlib.util.module_from_spec(spec); spec.loader.exec_module(obj)
    return obj

def properties(unit):
    p = subprocess.run(["systemctl", "show", unit, "--property=ActiveState,MainPID,UnitFileState"],
                       capture_output=True, text=True, timeout=10, check=True)
    return dict(line.split("=", 1) for line in p.stdout.splitlines() if "=" in line)

def epoch(value):
    return int(datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())


def api_listener(hostname, expected_sha256):
    """Verify only the local API, never infer public DNS/NAT or other service migration."""
    result = {"port": 3001, "verified": False, "certificate_sha256": None}
    try:
        context = ssl.create_default_context()
        with socket.create_connection(("127.0.0.1", 3001), timeout=2) as raw:
            with context.wrap_socket(raw, server_hostname=hostname) as secured:
                digest = hashlib.sha256(secured.getpeercert(binary_form=True)).hexdigest()
                if digest == expected_sha256:
                    result.update(verified=True, certificate_sha256=digest)
    except (OSError, ssl.SSLError):
        pass
    return result

def observe(instance, manager, config, root):
    unit = properties("inoc-node-active-" + instance + ".service")
    state = unit.get("ActiveState", "unknown")
    state = state if state in ("active", "inactive", "failed") else "unknown"
    digest = None
    if state == "active":
        pid = int(unit.get("MainPID", "0"))
        if pid > 0:
            binary = pathlib.Path("/proc") / str(pid) / "exe"
            resolved = binary.resolve(strict=True)
            base = pathlib.Path("/opt/inoc-active") / instance
            if not resolved.is_relative_to(base): raise ValueError("unexpected_running_binary")
            manager.trusted_file(resolved)
            # Read the running inode, not a potentially replaced path.
            with binary.open("rb") as f:
                hasher = hashlib.sha256()
                for chunk in iter(lambda: f.read(1048576), b""): hasher.update(chunk)
                digest = hasher.hexdigest()
            if properties("inoc-node-active-" + instance + ".service").get("MainPID") != str(pid):
                raise ValueError("process_changed")
    result = dict(observed_at=int(time.time()), node_sha256=digest, active_service=state, certificate=None)
    cert_path = root / "config/live/proxy/cert.pem"
    if cert_path.exists():
        # Scope is derived locally with the same canonical contract as Laravel.
        scope = json.dumps([config["control_plane"], config["client_id"], config["proxy_id"]],
                           sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        hostname = "p-" + hashlib.sha256(scope).hexdigest()[:32] + ".proxy.inocmon.com.br"
        resolved = cert_path.resolve(strict=True)
        if not resolved.is_relative_to(root / "config/archive/proxy"): raise ValueError("certificate_path_escape")
        manager.trusted_file(resolved)
        der = manager.command(["openssl", "x509", "-in", str(cert_path), "-outform", "DER"])
        dates = manager.command(["openssl", "x509", "-in", str(cert_path), "-noout", "-dates"]).decode().splitlines()
        parsed = dict(line.split("=", 1) for line in dates)
        matched = manager.command(["openssl", "x509", "-in", str(cert_path), "-noout", "-checkhost", hostname]).decode()
        if "does match certificate" not in matched: raise ValueError("certificate_hostname_mismatch")
        cert = dict(hostname=hostname, sha256=hashlib.sha256(der).hexdigest(),
                    not_before=int(ssl.cert_time_to_seconds(parsed["notBefore"])),
                    not_after=int(ssl.cert_time_to_seconds(parsed["notAfter"])),
                    renewal_test_at=None, timer_enabled=False, timer_active=False, listener_migrated=False)
        proof = root / "renew-proof.json"
        if proof.exists():
            manager.trusted_file(proof)
            saved = json.loads(proof.read_text())
            if saved.get("status") == "completed" and saved.get("hostname") == hostname:
                cert["renewal_test_at"] = epoch(saved["finished_at"])
        timer = properties("inoc-certificate-" + instance + ".timer")
        cert["timer_enabled"] = timer.get("UnitFileState") == "enabled"
        cert["timer_active"] = timer.get("ActiveState") == "active"
        cert["api_listener"] = api_listener(hostname, cert["sha256"])
        result["certificate"] = cert
    return result

def helper_paths(root):
    old_manager = "bfae14c28dceebb9e8a84dbeac482604af55a82d5b1e80d60c44f45c6bd26159"
    new_manager = "ffad6e2031bb45c6e51c80574dc482f384b82968bf5f936ac4e3c8894dae35d9"
    hook = "ca146e72af7b5c5be91f0abc970fb94b0a64353a17fbc493994358f3264e9fc3"
    managed_tls_manager = "333f6842a0926bc44e56902aeb8affd9e3d598c65f8c7cb69bce095b50eda80a"
    layouts = [
        ((root / "certificate-dns01-2026.10.25.2/proxy-certificate-manager.py", root / "certificate-dns01-2026.10.25.2/proxy-certificate-dns-hook.py"), (managed_tls_manager, hook)),
        ((root / "certificate-dns01-2026.10.25.1/proxy-certificate-manager.py", root / "certificate-dns01-2026.10.25.1/proxy-certificate-dns-hook.py"), (new_manager, hook)),
        ((root / "certificate-dns01-2026.10.23.1/proxy-certificate-manager.py", root / "certificate-dns01-2026.10.23.1/proxy-certificate-dns-hook.py"), (old_manager, hook)),
        ((root / "certificate-manager-v1.py", root / "active-execution-2026.10.23.1/proxy-certificate-dns-hook.py"), (old_manager, hook)),
    ]
    for paths, expected in layouts:
        # A partial or changed preferred layout must not silently select old code.
        if any(p.exists() or p.is_symlink() for p in paths):
            if any(not p.is_file() or p.is_symlink() or p.stat().st_size > 131072 or hashlib.sha256(p.read_bytes()).hexdigest() != digest for p, digest in zip(paths, expected)):
                raise ValueError("helper_hash_mismatch")
            return paths
    raise ValueError("certificate_helpers_missing")

def run(instance):
    if os.geteuid() != 0 or not re.fullmatch("[a-f0-9]{20}", instance): raise ValueError("root_and_instance_required")
    manager_path, hook_path = helper_paths(pathlib.Path("/opt/inoc-active") / instance)
    # Only load root-owned, non-writable existing release helpers.
    import stat
    for path in [manager_path, hook_path]:
        for part in [path, *path.parents]:
            s = part.lstat()
            if s.st_uid != 0 or s.st_mode & 0o022 or stat.S_ISLNK(s.st_mode): raise ValueError("untrusted_helper")
    manager = module("manager", manager_path)
    hook = module("hook", hook_path)
    config = hook.load_config(manager.trusted_file(pathlib.Path("/etc/inoc-execution") / instance / "certificate.json"))
    scope = json.dumps([config["control_plane"], config["client_id"], config["proxy_id"]],
                       sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    if hashlib.sha256(scope).hexdigest()[:20] != instance: raise ValueError("instance_mismatch")
    runtime = observe(instance, manager, config, pathlib.Path("/var/lib/inoc-certificates") / instance)
    # Reuse the pinned transport with a separate runtime envelope.
    import hmac, secrets, urllib.request
    body = dict(action="runtime-status", client_id=config["client_id"], proxy_id=config["proxy_id"],
                control_plane=config["control_plane"], timestamp=int(time.time()), nonce=secrets.token_hex(16), runtime=runtime)
    raw = json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    signature = hmac.new(config["key"].encode(), b"inoc-active-v1\n" + raw, hashlib.sha256).hexdigest()
    context = ssl.create_default_context(cafile=config.get("central_ca") or None)
    opener = urllib.request.build_opener(hook.NoRedirect(), urllib.request.HTTPSHandler(context=context))
    req = urllib.request.Request(config["control_plane"] + "/api/remote-execution/active", data=raw,
        headers={"Content-Type": "application/json", "X-Inoc-Signature": signature})
    with opener.open(req, timeout=25) as response:
        data = response.read(4097)
        if response.status != 200 or len(data) > 4096 or json.loads(data).get("ack") is not True:
            raise ValueError("observation_not_acknowledged")
    return {"status": "reported", "instance": instance, "observed_at": runtime["observed_at"]}

if __name__ == "__main__":
    try:
        if len(sys.argv) != 2: raise ValueError("arguments")
        print(json.dumps(run(sys.argv[1])))
    except Exception:
        print('{"status":"failed","reason":"runtime_observation_failed"}')
        sys.exit(1)
