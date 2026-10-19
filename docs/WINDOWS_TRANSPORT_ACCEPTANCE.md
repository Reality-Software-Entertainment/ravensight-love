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
The runtime candidate `0229455f40a3ba3cc90196360524518f660577d2` passed the
[Windows matrix](https://github.com/Reality-Software-Entertainment/ravensight-love/actions/runs/39297132584):
143 unit checks and nine actual WinHTTP loopback checks on each architecture.
Version and release tag remain unchanged pending patch-release coordination.

## Assertions

1. POST preserves a binary body containing NUL and non-ASCII bytes, and retains
   the exact encoded query string.
2. Redirects are returned without visiting their target.
3. Body size limits reject a response exceeding the limit.
4. Header size limits reject a response exceeding the limit.
5. A server connection closed before its declared Content-Length is received
   cannot produce HTTP success with a partial body.
6. A sustained delayed response fails before the fixture responds, with measured
   monotonic elapsed time. Three additional Windows cases measure timeout
   resolution, including a shorter response which Windows accepts.

The fixture additionally checks that exactly six requests arrived on libcurl and nine on Windows: no hidden
redirect follow or retry. This is HTTP loopback transport acceptance, not TLS
certificate validation, signed S3 multipart/API integration, actual screenshot
capture, consent UI or a production upload roundtrip.

## Current evidence and Windows failure handling

October 19, 2026: six actual libcurl checks pass on macOS. Actual Windows x64
and x86 each pass 143 unit regressions and nine loopback runtime checks.
Earlier failures are retained in task receipts: the initial Windows suite
exposed a Unix-only shell-curl assumption; actual WinHTTP then exposed normal
EOF before Content-Length and non-subsecond timeout behavior. The strict
truncation assertion was preserved throughout.

The production reader now discards partial bytes on native query/read errors
or early EOF against a declared response length. Malformed/overflow lengths
fail closed; HEAD, bodyless statuses and transfer coding preserve their HTTP
semantics. Header/data timeout configuration failures also fail closed.

### Measured timeout behavior, not a hard-deadline promise

Using native monotonic `GetTickCount64` on Windows Server2022:

| Requested phase timeout | Fixture delay | x64 elapsed | x86 elapsed | Result |
| --- | --- | --- | --- | --- |
|150ms|5000ms|3984ms|3968ms|status0 failure|
|500ms|5000ms|4000ms|4000ms|status0 failure|
|1500ms|5000ms|4000ms|4016ms|status0 failure|
|150ms|1000ms|1000ms|1000ms|HTTP200 success|

Small requested timeouts are therefore **not enforced as subsecond deadlines**
on these tested systems. The approximately four-second observed behavior is
not a documented universal floor or maximum. Timeout settings are native
phase bounds, not a strict whole-operation wall-clock guarantee. Applications
must not rely on a 150ms deadline; these synchronous requests run on the SDK
worker. The test process independently has a 25-second deadline.

Microsoft documents separate [response-header and partial-response timeout
options](https://learn.microsoft.com/en-us/windows/win32/winhttp/option-flags)
and [transaction-phase timeout configuration](https://learn.microsoft.com/en-us/windows/win32/api/winhttp/nf-winhttp-winhttpsettimeouts).
Both header and data settings are explicitly configured and checked. This
acceptance establishes behavior on the tested Windows2022 architectures,
not all Windows releases, TLS certificates, signed S3 upload integration,
actual game capture or production-account acceptance.

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
