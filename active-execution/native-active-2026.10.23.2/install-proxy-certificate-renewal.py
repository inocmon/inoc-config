#!/usr/bin/env python3
"""Install only the scoped renewal timer after a verified certificate exists."""
import importlib.util,json,os,pathlib,re,subprocess,sys
def units(instance,manager,hook):
    config="/etc/inoc-execution/"+instance+"/certificate.json"
    for path in (manager,hook,config):
        if not re.fullmatch(r"/[A-Za-z0-9_./-]+",str(path)):raise ValueError("unsafe_unit_path")
    service=f"""[Unit]
Description=INOCMON scoped DNS certificate renewal {instance}
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=root
UMask=0077
Nice=10
MemoryMax=512M
TasksMax=64
TimeoutStartSec=960
ExecStart=/usr/bin/python3 {manager} {instance} renew {config} {hook}
"""
    timer=f"""[Unit]
Description=INOCMON scoped DNS certificate renewal timer {instance}

[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=3600
Persistent=true
Unit=inoc-certificate-{instance}.service

[Install]
WantedBy=timers.target
"""
    return service,timer
def install(instance,manager_path,hook_path):
    if os.geteuid()!=0 or not re.fullmatch("[a-f0-9]{20}",instance):raise ValueError("root_and_instance_required")
    # All runtime code and parents are trusted before import.
    for path in [pathlib.Path(manager_path),pathlib.Path(hook_path)]:
        if not path.is_absolute():raise ValueError("absolute_path_required")
        import stat
        for parent in path.parents:
            s=parent.lstat()
            if not stat.S_ISDIR(s.st_mode) or s.st_uid!=0 or s.st_mode & 0o022:raise ValueError("unsafe_parent")
        s=path.lstat()
        if not stat.S_ISREG(s.st_mode) or s.st_uid!=0 or s.st_mode & 0o022:raise ValueError("unsafe_file")
    spec=importlib.util.spec_from_file_location("manager",manager_path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
    spec=importlib.util.spec_from_file_location("hook",hook_path);h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
    cfg=h.load_config("/etc/inoc-execution/"+instance+"/certificate.json")
    hostname=h.run(cfg,"identity")
    root=m.private_directory("/var/lib/inoc-certificates/"+instance)
    proof=json.loads((root/"renew-proof.json").read_text())
    if proof.get("status")!="completed" or proof.get("hostname")!=hostname:raise ValueError("renewal_proof_required")
    cert=m.validate_certificate(root,hostname)
    for suffix,content in zip(["service","timer"],units(instance,manager_path,hook_path)):
        path=pathlib.Path("/etc/systemd/system")/("inoc-certificate-"+instance+"."+suffix)
        if path.is_symlink():raise ValueError("unit_symlink")
        if path.exists():
            if path.read_text()!=content:raise ValueError("existing_unit_differs")
        else:
            fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o644)
            with os.fdopen(fd,"w") as f:f.write(content);f.flush();os.fsync(f.fileno())
    result={"status":"activating","hostname":hostname,"certificate":cert}
    m.atomic_json(root/"timer-install.json",result)
    try:
        timer="inoc-certificate-"+instance+".timer"
        for args in [["systemctl","daemon-reload"],["systemctl","--no-reload","enable",timer],["systemctl","start","--no-block",timer]]:
            subprocess.run(args,capture_output=True,timeout=90,check=True)
        active=subprocess.check_output(["systemctl","is-active",timer],timeout=10,text=True).strip()
        enabled=subprocess.check_output(["systemctl","is-enabled",timer],timeout=10,text=True).strip()
        if active!="active" or enabled!="enabled":raise ValueError("timer_not_ready")
        result.update(status="completed",active=active,enabled=enabled,finished_at=m.timestamp())
    except Exception as error:result.update(status="unknown",reason=type(error).__name__,finished_at=m.timestamp())
    m.atomic_json(root/"timer-install.json",result)
    return result
if __name__=="__main__":
    os.umask(0o077)
    try:
        if len(sys.argv)!=4:raise ValueError("arguments")
        result=install(*sys.argv[1:]);print(json.dumps(result));sys.exit(0 if result["status"]=="completed" else 1)
    except Exception as error:print(json.dumps({"status":"failed","reason":type(error).__name__}));sys.exit(1)
