#!/usr/bin/env python3
"""Queue scoped certificate/telemetry setup after active enrollment; never stop an executor."""
import fcntl, hashlib, importlib.util, json, os, pathlib, re, stat, subprocess, sys, tempfile, time
P=pathlib.Path
NAMES={'native-active-support.py','proxy-certificate-manager.py','proxy-certificate-dns-hook.py',
       'install-proxy-certificate-renewal.py','proxy-runtime-status.py','install-proxy-runtime-status.py'}
BASE=P('/opt/inoc-active'); VAR=P('/var/lib/inoc-execution'); UNITS=P('/etc/systemd/system')
ETC=P('/etc/inoc-execution'); CERTBOT=P('/usr/bin/certbot')
def trusted(path):
    path=P(path)
    if not path.is_absolute():raise ValueError('absolute_path_required')
    for p in [path,*path.parents]:
        s=p.lstat()
        if s.st_uid!=0 or s.st_mode & 0o022 or stat.S_ISLNK(s.st_mode):raise ValueError('untrusted_path')
    if not path.is_file():raise ValueError('regular_file_required')
    return path
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,trusted(path));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
def call(args,timeout=90):
    return subprocess.run(args,capture_output=True,text=True,timeout=timeout,check=True)
def atomic(path,data,mode=0o600):
    fd,tmp=tempfile.mkstemp(prefix='.active-support-',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as f:f.write(data);f.flush();os.fsync(f.fileno())
        os.chmod(tmp,mode);os.replace(tmp,path)
        fd=os.open(path.parent,os.O_RDONLY);os.fsync(fd);os.close(fd)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)
def attest(instance,source):
    if os.geteuid()!=0 or not re.fullmatch('[a-f0-9]{20}',instance):raise ValueError('root_and_scope_required')
    source=P(source).resolve(strict=True)
    if source.parent!=BASE/instance/'releases' or not re.fullmatch('[A-Za-z0-9][A-Za-z0-9._-]{0,95}',source.name):
        raise ValueError('release_scope_required')
    raw=trusted(source/'manifest.json').read_bytes()
    if len(raw)>131072:raise ValueError('manifest_bound')
    manifest=json.loads(raw);files=manifest.get('support_files',{})
    if manifest.get('runtime_mode')!='active' or set(files)!=NAMES:raise ValueError('support_contract_invalid')
    for name,item in files.items():
        b=trusted(source/name).read_bytes()
        if len(b)!=item['bytes'] or len(b)>65536 or hashlib.sha256(b).hexdigest()!=item['sha256']:raise ValueError('support_hash_mismatch')
    return source,files

def unit_text(instance):
    return f'''[Unit]
Description=INOCMON native active certificate and telemetry {instance}
After=network-online.target inoc-node-active-{instance}.service
Wants=network-online.target

[Service]
Type=oneshot
User=root
UMask=0077
Restart=no
Nice=10
MemoryMax=512M
TasksMax=64
TimeoutStartSec=2400
ExecStart=/usr/bin/python3 /opt/inoc-active/{instance}/current/native-active-support.py run {instance}
'''

def install(instance,source):
    attest(instance,source)
    path=UNITS/('inoc-active-support-'+instance+'.service');text=unit_text(instance).encode()
    if path.exists() or path.is_symlink():
        if trusted(path).read_bytes()!=text:raise ValueError('existing_support_unit_differs')
    else:atomic(path,text,0o644)
    call(['systemctl','daemon-reload'])
    # One start of the auxiliary unit. It does not own or restart the active executor.
    call(['systemctl','start','--no-block',path.name])
    return {'state':'queued'}

def helpers(instance,source,files):
    destinations={
        'certificate-dns01-2026.10.25.2':('proxy-certificate-manager.py','proxy-certificate-dns-hook.py','install-proxy-certificate-renewal.py'),
        'runtime-status-2026.10.25.2':('proxy-runtime-status.py','install-proxy-runtime-status.py')}
    result={}
    for folder,names in destinations.items():
        directory=BASE/instance/folder
        if not directory.exists():directory.mkdir(mode=0o755)
        for part in [directory,*directory.parents]:
            st=part.lstat()
            if not stat.S_ISDIR(st.st_mode) or st.st_uid!=0 or st.st_mode & 0o022:raise ValueError('untrusted_support_directory')
        for name in names:
            path=directory/name;data=(source/name).read_bytes()
            if path.exists() or path.is_symlink():
                if trusted(path).read_bytes()!=data:raise ValueError('immutable_support_file_differs')
            else:atomic(path,data,0o644)
            result[name]=path
    return result

def run(instance,source):
    source,files=attest(instance,source)
    path=VAR/instance/'active-support.json';lock_path=VAR/instance/'active-support.lock'
    if lock_path.is_symlink():raise ValueError('support_lock_invalid')
    fd=os.open(lock_path,os.O_WRONLY|os.O_CREAT|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        def record(state,phase):
            atomic(path,json.dumps({'state':state,'phase':phase,'updated_at':int(time.time()),'automatic_retry_allowed':False}).encode())
        phase='materialize';record('running',phase)
        try:
            paths=helpers(instance,source,files)
            hook=module('native_dns_hook',paths['proxy-certificate-dns-hook.py'])
            cfg_path=ETC/instance/'certificate.json';cfg=hook.load_config(trusted(cfg_path))
            scope=json.dumps([cfg['control_plane'],cfg['client_id'],cfg['proxy_id']],sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()
            if hashlib.sha256(scope).hexdigest()[:20]!=instance:raise ValueError('configuration_scope_mismatch')
            phase='awaiting_registration';record('running',phase)
            deadline=time.monotonic()+180
            while True:
                try:hostname=hook.run(cfg,'identity');break
                except Exception:
                    if time.monotonic()>=deadline:raise ValueError('registration_unconfirmed') from None
                    time.sleep(5)
            phase='telemetry';record('running',phase)
            reporter=paths['proxy-runtime-status.py']
            installer=module('native_runtime_install',paths['install-proxy-runtime-status.py'])
            if installer.install(instance,str(reporter),files['proxy-runtime-status.py']['sha256']).get('status')!='completed':
                raise ValueError('telemetry_unconfirmed')
            phase='certificate_dependencies';record('running',phase)
            if not CERTBOT.is_file():raise ValueError('certbot_required')
            manager=module('native_certificate_manager',paths['proxy-certificate-manager.py'])
            for action,accepted in [('issue',('completed','already_issued')),('renew-proof',('completed',))]:
                phase=action;record('running',phase)
                result=manager.run(instance,action,str(cfg_path),str(paths['proxy-certificate-dns-hook.py']))
                if result.get('status') not in accepted:raise ValueError('certificate_step_unconfirmed')
            phase='renewal_timer';record('running',phase)
            renewal=module('native_renewal_install',paths['install-proxy-certificate-renewal.py'])
            if renewal.install(instance,str(paths['proxy-certificate-manager.py']),str(paths['proxy-certificate-dns-hook.py'])).get('status')!='completed':
                raise ValueError('renewal_timer_unconfirmed')
            phase='managed_tls_identity';record('running',phase)
            if manager.register_tls_identity(instance,hostname).get('status')!='configured':
                raise ValueError('managed_tls_identity_unconfirmed')
            phase='final_observation';record('running',phase)
            if module('native_runtime_report',reporter).run(instance).get('status')!='reported':raise ValueError('observation_unconfirmed')
            record('completed','verified');return {'state':'completed'}
        except Exception:
            record('pending_review',phase);return {'state':'pending_review','phase':phase}
if __name__=='__main__':
    os.umask(0o077)
    try:
        if len(sys.argv)!=3 or sys.argv[1] not in ('install','run'):raise ValueError('arguments')
        result=(install if sys.argv[1]=='install' else run)(sys.argv[2],P(__file__).resolve().parent)
        print(json.dumps(result));sys.exit(0 if result['state'] in ('queued','completed') else 1)
    except Exception:
        print('{"state":"pending_review","automatic_retry_allowed":false}');sys.exit(1)
