# Elevated diagnostics threat model — 0.6.3 architecture milestone

Status: design review, 19 November 2026. Production remains 0.6.2 Standard-only. No privileged boundary has been validated. Read with [Architecture](ELEVATED_DIAGNOSTICS_ARCHITECTURE.md), [Protocol](ELEVATED_DIAGNOSTICS_IPC_PROTOCOL.md), [Tests](ELEVATED_DIAGNOSTICS_TEST_PLAN.md) and [Release gates](ELEVATED_DIAGNOSTICS_RELEASE_GATES.md).

0.6.4 adds real unprivileged Windows transport/refusal evidence only ([report](MILESTONE_0_6_4_REPORT.md)). The Medium lab server is owned by the original user, who can change its DACL; both executable images are user-writable. Kernel PID/session checks and retained handles bind the particular test peers but cannot make these images protected or the same-user session trustworthy. Other-account, high-integrity, effective protected-file access, loader substitution and privileged lifecycle attacks remain untested blockers. No new privileged endpoint, arbitrary operation or production trust boundary is introduced. The native/AOT build and disposable multi-account deployment prerequisites are unavailable; fail-closed entry points enforce that limitation.

## Revalidated baseline

0.6.5 baseline `b3afc6e` still has no privileged deployment/UAC path. New native source remains uncompiled and deployment-refusing; managed descriptor tests validate bytes only. Medium pipe read-back now rejects missing/unprotected/extra/broad/write/inherited grants and wrong labels through a shared policy. This improves rejection coverage but does not mitigate T01–T07/T12–T13/T16–T18 at a validated high boundary. The user-owned Medium object and mutable images remain untrusted. [Environment readiness](0_6_5_ENVIRONMENT_READINESS.md) prevents privileged experiments on the ordinary workstation; no architecture assumption is replaced by a secret/hash/JSON claim or permissive ACL.

At baseline commit `9135515`, the installer still uses LocalAppData and lowest privileges; desktop is asInvoker; Standard PowerShell loads neighbouring files; Elevated is rejected before discovery/launch; there is no privileged worker/IPC. Token/coverage reporting remains present. A fresh read-only ACL inspection of the installed **0.6.2** executable confirmed current-user ownership and a current-user write grant. This verifies a current deployment fact, not a protected-installation test.

## Actors and assumptions

| Actor | Authority and treatment |
| --- | --- |
| Standard workstation user | May run/browse Standard reports; cannot modify protected machine components. May cancel their own session. |
| Authorised technician | Initiates a bounded scan and obtains native Windows approval. Business authorisation is not inferred from a process name. |
| Local administrator | May approve, install/update/remove protected components. A malicious fully privileged local administrator is outside the containment guarantee. |
| Domain administrator | Has broad authority if used locally; not required or hard-coded. Prefer a dedicated workstation-support account according to organisational policy. |
| Malicious same-user process | Can alter per-user files, read user-accessible results, inject into ordinary same-user processes or abuse their handles. Treat desktop and non-elevated relay inputs as untrusted even when their on-disk image is protected. |
| Other unprivileged local account | Cannot normally access the original user's session/results. Test pipe ACL/identity separation; do not assume names or PIDs prove it. |
| Elevated worker | Small trusted computing base: fixed read-only operation, immutable dependencies, native token checks, parser and cleanup. Compromise is a privileged compromise. |
| Original WPBD desktop | Presentation/storage recipient under original user; cannot be made fully trustworthy once that user's session is compromised. Never receives a privileged executable token/handle. |

Assume Windows kernel/UAC/cryptography and approved system runtime binaries are trusted, organisational administrators control machine policy, and supported builds are patched. No claim against kernel compromise, malicious authorised administrators, compromised signing keys/supply chain or a deceived technician approving malicious software. These still require operational detection/recovery. Same-user compromise is **in scope for rejecting arbitrary privileged operations**, but secrecy/integrity of data once delivered to that compromised session is not achievable here. A valid signature does not establish operator intent or benign code.

Do not promote classic same-desktop UAC approval into a general isolation guarantee: Microsoft explicitly distinguishes it from a security boundary in [its UAC security discussion](https://learn.microsoft.com/en-us/troubleshoot/windows-server/windows-security/disable-user-account-control). This is a limitation reference, not a recommendation to disable UAC. The design relies on protected code, narrow operations and OS access controls, not a claim that a consent dialog makes a split-token administrator or compromised desktop unprivileged/trustworthy. Stronger administrative-session isolation may be required by organisational policy and is outside this application's guarantee.

## Assets and boundaries

Assets: credentials/high tokens; executable/module/runtime/configuration integrity; sensitive diagnostic paths/metadata; IPC endpoints; complete results; original-user reports/history; Windows configuration. Credential entry belongs only to Windows. Account SIDs/logon identifiers used for access checks stay transient, not in normal reports.

Boundaries: desktop → native UAC; per-user desktop → protected non-elevated relay; relay → high worker; worker → OS providers; worker → any retained PowerShell/runtime; worker → relay → user storage/presentation; package/update/removal → protected installation. UAC approves an executable, not arbitrary diagnostic output paths or every parameter. All messages remain untrusted until endpoint checks and schema/state validation pass.

## Attack scenarios

The mitigations below are proposed controls, not deployed facts. Validation IDs refer to the test plan.

| ID / scenario | Preconditions and attacker capability | Potential impact | Proposed mitigation | Residual risk | Validation |
| --- | --- | --- | --- | --- | --- |
| T01 Worker replacement | Low user can write/rename installed EXE or an ancestor | Approved process runs attacker code high | Admin-protected root, complete effective-ACL/ancestor checks, canonical file identity, signed deployment | Authorised admin can replace it; publisher compromise | S01/S02 |
| T02 Script/module modification | Worker imports a writable script/profile/module | Arbitrary privileged script execution | Protected complete script inventory; no user profiles, auto-load paths or caller scripts; initially token-only native worker | PowerShell/runtime remains a large TCB if later retained | S02/S03 |
| T03 DLL search hijack | CWD/PATH/plugin/native-loader search reaches writable content | Privileged code substitution | Fixed protected application directory, approved runtime inventory, constrained DLL search, no plugins | Managed/native resolution needs traced validation | S03 |
| T04 Dependency/config substitution | Writable runtimeconfig/deps/config/manifest or code extraction cache | Redirected runtime/code loading | Protect all execution-affecting files and caches; no user-writable sole checksum anchor | Machine admin and runtime vulnerabilities | S02/S03/S14 |
| T05 User-writable execution | Fixed path exists but lies below writable/reparse ancestors | Privilege crossing through mutable code | Refuse privileged deployment outside approved protected root; do not elevate current LocalAppData payload | Physical location alone does not prove effective ACLs | S01/S04 |
| T06 Pipe spoofing/impersonation | Attacker pre-creates name or connects first | False results, token misuse, unauthorised request | High worker owns single local-only server; first-instance flag; peer checks before data; relay opens with Identification SQOS | Same-user relay can be compromised; collision/connection flooding can deny service | S05/S06 |
| T07 PID reuse/false identity | Peer supplies another PID or original process exits | Wrong process accepted | Kernel endpoint PID + retained launch/process handle + creation time/session/token checks; abort on exit; PID alone never authenticates | Handle-rights availability across accounts is a release blocker | S07/S16 |
| T08 Replay | Old transcript/session/challenge is available | Old result accepted or extra scan | Fresh public session/challenge, exact session/config binding, directional sequences, terminal state, no reconnect | Nonces are visible and are not credentials/authentication | S08 |
| T09 Malformed/oversized frames | Low peer sends hostile bytes/JSON | Memory/CPU exhaustion or parser confusion | Length-before-allocation limit, strict UTF-8, depth/property/type bounds, duplicate rejection, total budgets/deadlines | Repeated authorised launches can cause bounded resource pressure | S09/S10 |
| T10 Argument injection | Caller controls parameters/environment | Shell or unsupported operation runs high | Canonical numeric/GUID tokens, fixed operation enumeration and fixed EXE; no free-text command/script/path | Same-user attacker may request the fixed scan after real consent | S11 |
| T11 Arbitrary writes | Caller requests report/cache/output path | Overwrite protected files | No privileged destination/path field; worker streams only; UI saves normally | Compromised UI can corrupt its own files/results | S12 |
| T12 Reparse/symlink attack | Attacker redirects install/update/temp path | Code substitution or privileged overwrite | No privileged report temp files; handle-based ancestor/file identity validation; protected installer staging; reject unsupported reparses | Reparse filters need real Windows filesystem tests | S04/S14 |
| T13 TOCTOU | Payload/path/peer changes after checking | Checked object differs from used object | Protected immutable version directories; held handles; verify final handle identity; no check-then-use by untrusted path | Malicious admin can race; update coordination must be proven | S04/S07/S14 |
| T14 Malicious report | Expected worker or provider returns malformed strings/content | UI injection, resource exhaustion, false success | Typed bounded result schema, full completion check, HTML encoding, no executable links/actions | Trusted sender may still have bugs; same-user UI can alter saved reports | S10/S13 |
| T15 Privileged/compromised actor | Admin controls machine or same-user code controls UI | Data theft or approval manipulation | Narrow read-only worker and native UAC; explain privacy/scope; do not treat UI code identity as complete trust | Cannot contain malicious full admin or protect delivered data from compromised recipient | S06/S16 + explicit limitation |
| T16 Install/update tampering | Writable staging, invalid signature, interrupted switch | Persistent privileged payload change | Enterprise/admin deployment; signed approved package; protected staging; atomic version switch and inventory validation | Enterprise updater/signing authority becomes TCB | S14 |
| T17 Downgrade | Older signed vulnerable worker is offered | Reintroduce old privileged bug | Machine-protected minimum security epoch + approved compatibility inventory; rollback only to approved non-revoked version | Admin can deliberately override policy; offline revocation needs deployment policy | S14/S15 |
| T18 Termination/cleanup | UI/relay/worker disconnects, crashes or hangs | Orphan privileged work, incomplete report | Single-scan process, peer lifetime monitoring, cancellation, absolute watchdogs, discard incomplete output; exact owned-child cleanup design | Stuck kernel/provider calls and UAC UI lifetime need integration tests | S17/S18 |

## Security acceptance

Passing codec tests addresses only portions of T08–T10/T14. It does not validate protected files, native peer identity, UAC, cross-account permissions, impersonation or a high-token boundary. Any such untested dependency blocks enabling production elevation. Keep the existing rejection gate until all blocking gates are met.
