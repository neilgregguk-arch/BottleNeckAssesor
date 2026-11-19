# Candidate IPC protocol v1 — not a deployed interface

0.6.3 design. Production exposes no privileged endpoint. An optional isolated conformance harness validates memory-stream syntax/state only. It does not authenticate processes or demonstrate elevation. [Architecture](ELEVATED_DIAGNOSTICS_ARCHITECTURE.md) and [release gates](ELEVATED_DIAGNOSTICS_RELEASE_GATES.md) govern any implementation.

## 0.6.4 transport subset and evidence limits

`experiments/elevation-worker` links the **unchanged** 0.6.3 validator. Real Windows tests use a distinct `\\.\pipe\WPBD.Experimental.Medium.v1.<session>` namespace and refuse any token except non-elevated Medium. The server is outbound/overlapped, first-instance, local-only and single-instance; native client opens `0x00120089` read rights with Identification SQOS and no write right. The lab reads back owner/DACL/Medium mandatory-label policy using GetSecurityInfo and LABEL_SECURITY_INFORMATION, without requesting audit SACL access or enabling privileges. The proposed High/admin-owned descriptor below has **not** been tested.

Kernel endpoint PID/session observations are compared with retained process handles and creation times; the supervisor holds the actual fixture launch handle before opening its limited-query peer handle. Image/logon/user consistency is checked in memory. This establishes native peer correlation within this Medium lab, not protected executable identity, cross-account authorisation or resistance to same-user runtime compromise. PID reuse is not forced; stale/substituted creation-time/session claims are rejected. The lab does not impersonate a client and returns no token/privileged handles. Request/session scope and complete schema validation are separate checks after native peer matching.

The async receiver bounds length before allocation/body read, then calls the original exact-schema/state validator. It requires terminal completion followed by EOF. Real negative cases require the intended failure type; transport EOF cannot pass a malformed-size/schema test. Read deadlines and connection cancellation are real Medium tests, not privileged watchdog or late-UAC tests. No wire schema, permitted high operation or production behaviour has changed. Native UAC, protected peer/inventory validation, High ownership/MIC, separate-account access and admin-controlled install/remove are unimplemented and fail closed.

Primary references used for this subset: [pipe access rights](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights), [CreateFile/SQOS](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew), [client PID](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getnamedpipeclientprocessid), [server PID](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getnamedpipeserverprocessid), [mandatory-label ACE layout](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-system_mandatory_label_ace) and [security-information rights](https://learn.microsoft.com/en-us/windows/win32/secauthz/security-information). Native label read-back required parsing its actual binary ACE; treating it as a .NET KnownAce was rejected in development and corrected before the passing run.

## Direction and authority

Select a **one-way results pipe**: the high-integrity worker creates the outbound server; the original-user protected relay opens a read-only client. This is preferable here to a duplex administrative RPC surface. The worker never connects as a privileged client to a low-owned server. Local RPC/COM with Windows authentication is an alternative if native pipe controls cannot be validated, requiring a new design review rather than an insecure fallback.

No privileged operation is requested over this pipe. A single fixed operation/configuration is frozen in the native UAC launch arguments. There is no start/execute/write/kill/service/privilege-adjust opcode. UI → relay cancellation is ordinary-user control only; relay closes its read handle. The worker treats peer exit/disconnect as cancellation and stops its own diagnostic work. A read-only data channel avoids needing to lower a high pipe object's integrity merely to accept cancellation writes.

## Frozen invocation

Only the fixed protected worker executable may receive exactly these six pairs:

```text
--session <32 lowercase hex GUID, nonzero>
--relay-pid <canonical positive uint32>
--relay-start <canonical positive process-creation FILETIME integer, <= Int64.MaxValue>
--duration <30|60|120|300>
--interval <1|2|5|10>
--operation <token-probe-v1 | diagnose-v1>
```

No duplicates, extra flags, shorthand, paths, free text, shell quoting constructs, environment overrides, output format/path or script arguments. Interval must not exceed duration. Initial protected PoC authorises **token-probe-v1 only**; diagnose-v1 needs later engine gates. The in-memory harness likewise accepts only token-probe-v1. Canonical tokens make constructing ShellExecuteEx parameters deterministic; do not concatenate unvalidated strings. Worker security epoch, permitted operations and version policy come from protected deployment policy, never a caller manifest.

Session identifiers are correlation/replay protection, not secrets or authentication. Relay PID/start arguments are consistency claims, not identity proof. Pipe name is derived: `\\.\pipe\WPBD.Diagnostic.v1.<session>`; no caller-supplied endpoint or network host.

## Native endpoint establishment — required, unimplemented

1. Non-elevated relay retains the exact process handle returned by its fixed UAC launch. If Windows does not return a usable live identity reference, abort. Retain its creation time; do not repeatedly reopen a numeric PID as if it were the original process.
2. Worker verifies protected deployment and its own primary high/admin token. It opens/holds the claimed relay process, obtains creation time, primary token user/logon identity, interactive session and final protected relay image identity from Windows. Require a non-elevated original-user relay and exact creation-time agreement. Failure to obtain these facts across accounts blocks the operation.
3. Worker creates one outbound byte-stream server with overlapped I/O, FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_REJECT_REMOTE_CLIENTS and one instance. Existing name is a failure, not an invitation to attach/reuse it. No reconnect/session resume.
4. Candidate security descriptor: administrator/SYSTEM-controlled ownership and DACL, explicit access for the **original relay logon SID** to read data/attributes, read security and synchronise only. No Everyone/Anonymous/Network or ordinary-user write/delete/owner/DACL rights. Preserve a High mandatory label; no low-to-high write path is needed. Prove owner/mandatory-label creation and client access on real Windows without enabling extra privileges. If that fails, architecture revision is required.
5. Relay uses native CreateFile with read-only specific rights and SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION. Avoid convenience APIs that silently request GENERIC_WRITE: named-pipe write rights can include creation of another server instance. It obtains the kernel server PID from its actual pipe handle and compares it with the retained UAC process identity. Verify approved protected image/version/epoch and live lifetime; terminate the session on disagreement.
6. Worker obtains the kernel client PID/session from the connected pipe handle, compares it with the held relay process and its original token/logon/session identity, and refuses unrelated clients **before emitting token/results**. Use any impersonation only for identification, always revert in finally, and never use an impersonated token for report writes or privileged execution. No high token or privileged process handle crosses to the relay/UI.

The candidate descriptor is a policy to test, **not a validated SDDL recipe**. Logon SID, interactive session ID and account SID are distinct; a separate administrator account has a different authentication identity. Do not require the worker's account/logon SID to equal the original user. Other-session same-user clients must also be tested. Same-user injection into a relay defeats claims that its runtime code is trustworthy; therefore the worker still restricts every argument and operation.

Kernel PID APIs identify the endpoint process, not its benignness. Pair them with retained process handles, creation time and protected deployment. See [pipe functions](https://learn.microsoft.com/en-us/windows/win32/ipc/pipe-functions), [server PID](https://learn.microsoft.com/en-us/windows/desktop/api/winbase/nf-winbase-getnamedpipeserverprocessid), [process creation times](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocesstimes), [pipe DACLs](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights), and [CreateFile SQOS](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew). Correct rights/handle behaviour and cross-account token inspection remain real-test blockers.

## Frames and schemas

Each frame is a four-byte unsigned little-endian byte length followed by exactly that many UTF-8 JSON bytes. Minimum 2, maximum **65,536 bytes**. Reject the advertised size before allocating/reading a body. Strict UTF-8, no BOM/comments/trailing data, depth <=8, duplicate properties rejected recursively. Root has exactly `v`, `session`, `seq`, `kind`, `data`; no case folding, coercion, extension or unknown-field fallback. Integers must be exact and bounded. Maximum 4,096 frames per session.

`v=1`; `session` exactly matches the invocation; `seq` starts at zero and increases by one, no duplicates/gaps/wrap. Config digest is SHA-256 of the UTF-8 canonical string `v1|session|relayPid|relayStart|duration|interval|operation`. Digests are 64 lowercase hex characters. They bind scope/detect corruption; they are **not MACs, authentication or protection against a malicious trusted worker**.

| Kind | Exact data fields | Allowed state / bounds |
| --- | --- | --- |
| hello | `operation` string, `epoch` integer, `requestHash` digest | First frame only; approved operation/epoch; matches frozen request |
| progress | `collected` integer, `expected` integer | After hello, before result-begin; expected equals ceil(duration/interval), 0 <= collected <= expected; no regressions |
| result-begin | `bytes` integer, `sha256` digest | Once after hello/progress; 2..67,108,864 bytes; no report path |
| result-chunk | `index` integer, `base64` string | After begin; contiguous indexes from zero; decoded chunk 1..32,768 bytes, canonical base64, encoded string <=43,692 chars; cumulative bytes cannot exceed declared size |
| complete | `bytes` integer, `sha256` digest | After all bytes; agrees with begin, running count and computed hash; then terminal |
| cancelled | `code` = `Cancelled` | After hello, before complete; terminal; discard any body |
| error | `code` enum | After hello; terminal; codes: Unsupported, TrustFailure, PolicyBlocked, ResourceLimit, Timeout, ProviderFailure; no arbitrary exception text/account identity |

No frame is accepted after terminal success/failure/cancellation. Invalid UTF-8/schema/state/size/sequence/session/digest makes the receiver terminally failed. Do not resynchronise to another frame or retry another transport. Progress is not a valid diagnostic result.

Token-probe result JSON is limited to **4 KiB**, with exactly `available` boolean, `isElevated` boolean-or-null and `integrityRid` nonnegative int32-or-null. Unavailable token facts must be null. It contains no account name/SID. A syntactically valid high-token claim in the memory harness is **not verified elevation**. A real protected worker must derive/validate its own token before endpoint creation; relay acceptance additionally requires native peer/deployment checks. No peer-authentication assertion is implemented by the codec.

Future diagnose-v1 result is the full supported WPBD report, retaining schema/engine/release distinction, full-precision measurements, identity safeguards and token evidence. Relay/UI must validate the report's typed fields/counts/window/limits independently of sender identity. A malformed result is not saved as a historical scan.

## Budgets, lifetime and cancellation

Initial design ceilings: 64 MiB complete JSON, 32 KiB decoded chunks, 4,096 frames, 512 MiB worker process-tree committed-memory budget. These are proposed fail-closed caps needing measurement/implementation validation, not permission to drop samples or reinterpret results. If full accurate data cannot fit, return ResourceLimit and no report. Do not create privileged spool/temp files to escape a cap.

Peer-connect deadline 30 seconds after worker startup; no-byte I/O deadline 15 seconds; worker total deadline duration+180 seconds (max 480); cooperative cancellation grace 10 seconds. Provider queries may delay; a real supervisor/owned-child job design must prove cleanup without acting on arbitrary processes. Frame activity does not reset the absolute lifetime. UAC UI is controlled by Windows: a relay timeout cannot safely pretend the credential dialog was dismissed. If consent arrives after the relay has gone, worker detects the dead/mismatched relay and exits without collection.

On UI cancellation/close, relay closes its read handle and exits/cooperatively signals local cancellation; worker watches pipe and retained relay lifetime, cancels the fixed diagnostic and exits. The lower-integrity side must not be expected to terminate an elevated process across accounts. Never enumerate/kill PIDs from protocol data. No system-process/service termination is a diagnostic operation. A self-bounded worker and owned-child cleanup need real integration evidence; the isolated harness terminates no processes.

## Saving and privacy

Worker writes only its pipe; relay writes only inherited original-user output. Desktop waits for valid complete data, matching digest, acceptable result schema and successful worker termination before saving the existing CreateNew JSON/HTML pair under original-user permissions. Failed/incomplete/cancelled transfer produces no report. Report-save failure must be distinct from scan/IPC success and roll back partial pairs. A digest is not durable report authenticity after a user can edit a saved report.

No administrator profile report directory, supplied destination, inherited privileged file handle or automatic remote upload. Sensitive executable paths/process metadata require technician awareness and ordinary-user access protection. HTML remains encoded/self-contained; no process-provided markup, executable actions or unsafe deserialisation. Historical reports without new fields retain unavailable values, not reconstructed evidence.
