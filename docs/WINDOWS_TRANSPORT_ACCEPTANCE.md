# Native upload transport acceptance

The dependency-free loopback fixture runs the **actual selected native transport**.
It uses synthetic bytes, binds only `127.0.0.1` on an ephemeral port, and makes no
production or external requests. It creates no credentials or trust-store entries.
The child has a 25-second hard deadline; fixture cleanup runs on failure.

From the repository root, with Python 3 and a compatible LuaJIT installed:

```sh
python3 spec/runtime/run.py --transport libcurl
```

On a real Windows machine with Python 3 and a standalone LuaJIT executable:

```powershell
py -3 spec/runtime/run.py --transport winhttp --lua C:\path\to\luajit.exe
```

Use a reviewed local LuaJIT distribution with the intended architecture. The
LÖVE graphical executable is not a drop-in Lua command-line interpreter. The
WinHTTP test requires `ffi.os == 'Windows'` and successful loading of `winhttp`;
transport fallback fails the test rather than producing a misleading pass.
No Editor license, cloud compute or account is needed. The dedicated `Windows native transport` workflow builds the official LuaJIT
source at commit `dd3b24369ddfaa83c78cd6fdd91d157c8968ec8d` with the installed
MSVC compiler on Windows 2022, for both x64 and x86. No binary mirror is used.
The workflow and fix were published at `9bb4b73`; the automatic Windows matrix
built both architectures. Its first run exposed a pre-existing shell-curl test
assumption, now corrected to assert the intentional Windows native selection.
Final native runtime acceptance is still pending.

## Assertions

1. POST preserves a binary body containing NUL and non-ASCII bytes, and retains
   the exact encoded query string.
2. Redirects are returned without visiting their target.
3. Body size limits reject a response exceeding the limit.
4. Header size limits reject a response exceeding the limit.
5. A server connection closed before its declared Content-Length is received
   cannot produce HTTP success with a partial body.
6. A delayed response fails within the native receive timeout and outer deadline.

The fixture additionally checks that exactly six requests arrived: no hidden
redirect follow or retry. This is HTTP loopback transport acceptance, not TLS
certificate validation, signed S3 multipart/API integration, actual screenshot
capture, consent UI or a production upload roundtrip.

## Current evidence and Windows failure handling

October 19, 2026: all six tests passed on macOS using actual LuaJIT/libcurl.
Task receipt: `outputs/love-native-loopback-acceptance.log`. No Windows pass is
claimed; this macOS host has no Windows runtime/Wine or Windows executor.

Static inspection identified a WinHTTP partial-response issue: query/read API
failures previously retained the original status and accumulated bytes. The
production reader now discards those bytes and returns status 0/network_error.
It also rejects zero progress after positive availability. Nine unit regressions
exercise the production reader through a fake DLL boundary, including failures
before/after bytes, empty/binary success and cumulative size limits. These prove
the local state machine, not execution through the Windows DLL. The real
truncation test remains required on Windows; libcurl passes it locally.

After this fix, 133 tests pass under both Lua and LuaJIT, and all six real native
libcurl loopback checks still pass. Windows CI must be green for both architectures
before calling WinHTTP runtime acceptance complete.

An authorized Windows executor with Python and LuaJIT is the remaining
prerequisite to run this harness. Broader TLS, packaging and game capture checks
remain separate. Unity Editor/license acceptance and physical-device checks in
other SDKs are not covered by these tests.

## Reviewed CI execution sequence

After the workflow/source is reviewed, committed and pushed through the normal
SDK release process, a main-branch push affecting these paths starts the matrix.
Do not also dispatch a duplicate run. If a manual rerun is necessary:

```sh
gh workflow run windows-transport.yml --repo Reality-Software-Entertainment/ravensight-love --ref main
gh run list --repo Reality-Software-Entertainment/ravensight-love --workflow windows-transport.yml --limit 3
```

Verify the selected run's head SHA equals the reviewed source, inspect both x64
and x86 jobs, and retain their native runtime artifacts. No release/tag/package
version or customer endpoint is changed by this workflow.
