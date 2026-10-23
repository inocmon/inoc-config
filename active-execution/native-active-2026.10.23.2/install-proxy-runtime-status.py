#!/usr/bin/env python3
"""Install the scoped runtime observation timer without restarting any executor."""
import hashlib, importlib.util, json, os, pathlib, re, stat, subprocess, sys
def units(instance, reporter):
    if not re.fullmatch("[a-f0-9]{20}",instance) or not re.fullmatch(r"/[A-Za-z0-9_./-]+",str(reporter)):
        raise ValueError("unsafe_unit_identity")
    return f"""[Unit]
Description=INOCMON runtime observation {instance}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
UMask=0077
Nice=15
IOSchedulingClass=idle
MemoryMax=128M
TasksMax=16
TimeoutStartSec=70
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ExecStart=/usr/bin/python3 {reporter} {instance}
""",f"""[Unit]
Description=INOCMON runtime observation timer {instance}

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
RandomizedDelaySec=60
AccuracySec=15
Unit=inoc-runtime-status-{instance}.service

[Install]
WantedBy=timers.target
"""
def install(instance, reporter, expected):
    if os.geteuid()!=0 or not re.fullmatch("[a-f0-9]{20}",instance) or not re.fullmatch("[a-f0-9]{64}",expected):
        raise ValueError("root_and_scope_required")
    reporter=pathlib.Path(reporter)
    if reporter!=pathlib.Path("/opt/inoc-active")/instance/"runtime-status-2026.10.23.2/proxy-runtime-status.py":
        raise ValueError("reporter_scope")
    for p in [reporter,*reporter.parents]:
        s=p.lstat()
        if s.st_uid!=0 or s.st_mode & 0o022 or stat.S_ISLNK(s.st_mode):raise ValueError("untrusted_reporter")
    if hashlib.sha256(reporter.read_bytes()).hexdigest()!=expected:raise ValueError("reporter_hash")
    service,timer=units(instance,reporter)
    for ext,content in [("service",service),("timer",timer)]:
        p=pathlib.Path("/etc/systemd/system")/("inoc-runtime-status-"+instance+"."+ext)
        if p.is_symlink():raise ValueError("unit_symlink")
        if p.exists():
            if p.read_text()!=content:
                previous=units(instance,str(reporter).replace("runtime-status-2026.10.23.2/","runtime-status-2026.10.23.1/"))[0]
                if ext!="service" or p.read_text()!=previous:raise ValueError("existing_unit_differs")
                state=subprocess.run(["systemctl","is-active",p.name],capture_output=True,text=True,timeout=10).stdout.strip()
                if state not in ("inactive","failed"):raise ValueError("observation_busy")
                import tempfile
                fd,name=tempfile.mkstemp(prefix=".runtime-unit-",dir=p.parent)
                try:
                    with os.fdopen(fd,"w") as f:f.write(content);f.flush();os.fsync(f.fileno())
                    os.chmod(name,0o644);os.replace(name,p)
                finally:
                    if os.path.exists(name):os.unlink(name)
        else:
            fd=os.open(p,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o644)
            with os.fdopen(fd,"w") as f:f.write(content);f.flush();os.fsync(f.fileno())
    def cmd(args):return subprocess.run(args,capture_output=True,text=True,check=True,timeout=70).stdout.strip()
    cmd(["systemctl","daemon-reload"])
    # This only reads local state and POSTs telemetry; it cannot dispatch jobs.
    cmd(["systemctl","start","inoc-runtime-status-"+instance+".service"])
    timer="inoc-runtime-status-"+instance+".timer"
    cmd(["systemctl","--no-reload","enable",timer]);cmd(["systemctl","start",timer])
    if cmd(["systemctl","is-enabled",timer])!="enabled" or cmd(["systemctl","is-active",timer])!="active":
        raise ValueError("timer_not_ready")
    return {"status":"completed","instance":instance,"reporter_sha256":expected,"timer_enabled":True,"timer_active":True}
if __name__=="__main__":
    try:
        if len(sys.argv)!=4:raise ValueError("arguments")
        print(json.dumps(install(*sys.argv[1:])))
    except Exception:
        print('{"status":"unknown","reason":"inspect_runtime_timer_before_retry"}');sys.exit(1)
