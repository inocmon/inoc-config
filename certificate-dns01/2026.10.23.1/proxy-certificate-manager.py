#!/usr/bin/env python3
"""Isolated DNS-01 certificate lifecycle; never changes an existing listener."""
import datetime, fcntl, hashlib, importlib.util, json, os, pathlib, re, shlex
import signal, stat, subprocess, sys, tempfile, time

def private_directory(path):
    path = pathlib.Path(path)
    if not path.is_absolute(): raise ValueError("absolute_path_required")
    for part in reversed([path, *path.parents]):
        if part == pathlib.Path("/"): continue
        if not part.exists(): part.mkdir(mode=0o700)
        s = part.lstat()
        if not stat.S_ISDIR(s.st_mode) or s.st_uid != 0 or s.st_mode & 0o022:
            raise ValueError("unsafe_directory")
    os.chmod(path, 0o700)
    return path

def trusted_file(path):
    p = pathlib.Path(path)
    if not p.is_absolute(): raise ValueError("absolute_file_required")
    for parent in p.parents:
        s = parent.lstat()
        if not stat.S_ISDIR(s.st_mode) or s.st_uid != 0 or s.st_mode & 0o022:
            raise ValueError("unsafe_file_parent")
    s = p.lstat()
    if not stat.S_ISREG(s.st_mode) or s.st_uid != 0 or s.st_mode & 0o022:
        raise ValueError("unsafe_file")
    return p

def timestamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def atomic_json(path, value):
    fd, name = tempfile.mkstemp(prefix=".receipt-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(value, f, sort_keys=True); f.flush(); os.fsync(f.fileno())
        os.replace(name, path)
        d = os.open(path.parent, os.O_RDONLY)
        try: os.fsync(d)
        finally: os.close(d)
    finally:
        if os.path.exists(name): os.unlink(name)

def command(args, timeout=15, input=None):
    p = subprocess.run(args, input=input, capture_output=True, timeout=timeout, check=True)
    return p.stdout

def validate_certificate(root, hostname):
    live = root / "config/live/proxy"
    cert, chain, key = [live / n for n in ("cert.pem", "chain.pem", "privkey.pem")]
    # Certbot's live links must stay inside this isolated archive.
    for p in (cert, chain, key):
        resolved = p.resolve(strict=True)
        if not resolved.is_relative_to(root / "config/archive/proxy"):
            raise ValueError("certificate_path_escape")
        s = resolved.stat()
        if not stat.S_ISREG(s.st_mode) or s.st_uid != 0 or s.st_mode & 0o022:
            raise ValueError("certificate_file_unsafe")
    if key.resolve().stat().st_mode & 0o077: raise ValueError("private_key_exposed")
    command(["openssl", "verify", "-CApath", "/etc/ssl/certs", "-untrusted", str(chain),
             "-verify_hostname", hostname, str(cert)])
    command(["openssl", "x509", "-in", str(cert), "-noout", "-checkend", "86400"])
    public = command(["openssl", "x509", "-in", str(cert), "-pubkey", "-noout"])
    derived = command(["openssl", "pkey", "-in", str(key), "-pubout"])
    if public != derived: raise ValueError("key_mismatch")
    # Exercise a real TLS server context without exposing a new network listener.
    import ssl
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(str(live / "fullchain.pem"), str(key))
    der = command(["openssl", "x509", "-in", str(cert), "-outform", "DER"])
    dates = command(["openssl", "x509", "-in", str(cert), "-noout", "-dates"]).decode().splitlines()
    return {"hostname": hostname, "sha256": hashlib.sha256(der).hexdigest(),
            "dates": dates, "chain_key_hostname_valid": True,
            "listener_migrated": False}

def certbot_arguments(action, root, hook, config, hostname):
    args = ["/usr/bin/certbot", "--config", "/dev/null", "--non-interactive",
            "--config-dir", str(root / "config"), "--work-dir", str(root / "work"),
            "--logs-dir", str(root / "logs"), "--no-directory-hooks"]
    if action in ("issue", "staging"):
        args += ["certonly", "--manual", "--preferred-challenges", "dns",
                 "--manual-auth-hook", shlex.join(["/usr/bin/python3", str(hook), str(config), "present"]),
                 "--manual-cleanup-hook", shlex.join(["/usr/bin/python3", str(hook), str(config), "cleanup"]),
                 "--cert-name", "proxy", "--key-type", "ecdsa",
                 "--agree-tos", "--register-unsafely-without-email", "-d", hostname]
        if action == "staging": args += ["--dry-run"]
    elif action in ("renew", "renew-proof"):
        args += ["renew", "--cert-name", "proxy"]
        if action == "renew-proof": args += ["--dry-run"]
    else: raise ValueError("invalid_action")
    return args

def run(instance, action, config_path, hook_path):
    if os.geteuid() != 0 or not re.fullmatch(r"[a-f0-9]{20}", instance):
        raise ValueError("root_and_instance_required")
    config_path = trusted_file(config_path); hook_path = trusted_file(hook_path)
    if config_path != pathlib.Path("/etc/inoc-execution") / instance / "certificate.json":
        raise ValueError("configuration_scope")
    spec = importlib.util.spec_from_file_location("dns_hook", hook_path)
    hook = importlib.util.module_from_spec(spec); spec.loader.exec_module(hook)
    config = hook.load_config(config_path)
    root = private_directory(pathlib.Path("/var/lib/inoc-certificates") / instance)
    with (root / "lock").open("a") as lock:
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: return {"status": "busy"}
        hostname = hook.run(config, "identity")
        receipt = {"action": action, "hostname": hostname, "started_at": timestamp(),
                   "status": "running", "pid": os.getpid(), "listener_migrated": False}
        path = root / (action + ".json")
        if action == "issue" and (root / "config/live/proxy/fullchain.pem").exists():
            return {"status": "already_issued", "certificate": validate_certificate(root, hostname)}
        atomic_json(path, receipt)
        process = None
        try:
            args = certbot_arguments(action, root, hook_path, config_path, hostname)
            # Certbot already rotates its own debug log. Keep bounded CLI output private.
            with tempfile.TemporaryFile() as output:
                process = subprocess.Popen(args, stdout=output, stderr=subprocess.STDOUT,
                                           stdin=subprocess.DEVNULL, start_new_session=True)
                try: code = process.wait(timeout=900)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGTERM)
                    try: process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL); process.wait()
                    raise ValueError("certbot_timeout")
                output.seek(0)
                raw = output.read(65536)
                receipt["certbot_exit"] = code
                receipt["output_sha256"] = hashlib.sha256(raw).hexdigest()
                # Store diagnostics privately; never serialize CLI output through the remote API.
                diagnostic = root / (action + ".log")
                fd = os.open(diagnostic, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, "wb") as f: f.write(raw)
                if code != 0: raise ValueError("certbot_failed")
            if action != "staging": receipt["certificate"] = validate_certificate(root, hostname)
            receipt["status"] = "completed"
        except Exception as error:
            receipt["status"] = "failed"
            receipt["reason"] = str(error) if isinstance(error, ValueError) else type(error).__name__
            if len(receipt["reason"]) > 100: receipt["reason"] = type(error).__name__
        receipt["finished_at"] = timestamp()
        atomic_json(path, receipt)
        return receipt

if __name__ == "__main__":
    os.umask(0o077)
    try:
        if len(sys.argv) != 5: raise ValueError("arguments")
        result = run(*sys.argv[1:])
        print(json.dumps(result))
        sys.exit(0 if result["status"] in ("completed", "already_issued") else 1)
    except Exception as error:
        print(json.dumps({"status": "failed", "reason": type(error).__name__}))
        sys.exit(1)
