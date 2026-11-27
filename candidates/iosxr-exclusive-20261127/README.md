# IOS XR exclusive-session refusal — candidate

Status: validated in DEV on 2026-11-27. No production executor was updated.

Both administrative beta13 and Config5 now stop a strict command batch when
IOS XR refuses `configure exclusive` with `Cannot enter exclusive mode`.
The next command is not sent. There is no automatic retry, unlock, rollback,
or attempt to terminate another session. Historical messages in show output
do not trigger this command-specific check.

The CLI names and capability contracts remain unchanged. Exact candidates are
identified by commit, tag, package path and SHA-256 in manifest.json. Stable
catalogs and root executables are preserved; advancing the repository gitlink
does not select or install these candidates.

The source regression suite passed 65 tests. Loopback SSH/Telnet fixtures
passed 12 cases against Python source and 12 against these exact binaries,
covering both executors, refusal, successful entry and historical log text.
No production configuration command was used for acceptance.

Packages use deterministic gzip headers. Decompression must match both the
binary size and SHA-256 before staging. Record the installed executor hash,
back it up on DEV, then deploy only the approved component in its authorized
maintenance scope. A rollback must restore that recorded binary atomically;
never guess the prior version from its filename.
