# Elevated diagnostics release gates — closed by default

0.6.3 is an architecture milestone; **0.6.4 is classification B, partial proof of concept** ([report](MILESTONE_0_6_4_REPORT.md)). Application VERSION remains **0.6.2**, engine **0.6.0**, schema **0.3**. Elevated remains unavailable and rejected before worker launch. No normal installer is changed. Experimental managed outputs are refusal/lab builds only, cannot be published as the protected package and are not deployed.

| Gate | Exact evidence required before enablement | Current state |
| --- | --- | --- |
| G00 Production isolation | Unchanged production paths/installer/VERSION; no experimental references; original build/regressions/Standard live checks pass | Verified for this milestone; results recorded in the test plan and completion report |
| G01 Deployment/removal decision | Product/security approval of hybrid lifecycle: ordinary desktop removal and explicit administrator/enterprise protected-package removal; no silent leftovers or low-user write/delete grant | **Open — experimental admin-controlled lifecycle authorised by 0.6.4 prompt; protected installer/removal and full product lifecycle unvalidated** |
| G02 Protected inventory | Effective ACL/ownership/ancestor/reparse/TOCTOU tests for every executable, DLL, runtime, script/module, configuration and staging path; original and other standard users cannot modify; no privileged mutable extraction cache | **Open — real A/X tests** |
| G03 Signing/update/downgrade | Approved publisher/product and security epoch, protected trust anchor, atomic update/rollback, minimum safe version, signer rotation/revocation and documented offline policy; WDAC/AppLocker/endpoint-security compatibility | **Open** |
| G04 Narrow real worker | Native token-only first; exact argument schema and fixed operations; no arbitrary commands/scripts/paths, privilege changes, service/process control or credentials; code review and negative real-launch tests | **Open — refusal-stage managed entry point and native own-token guard tested; no successful high worker/native build** |
| G05 Native IPC boundary | High-owned local read-only server, effective ACL/MIC/owner tests, actual kernel endpoint identity and retained lifetimes, original logon/session binding, no token/privileged handle transfer or impersonation authority | **Open — real Medium transport subset only; protected/high/cross-account boundary unimplemented** |
| G06 Genuine Windows elevation | Same-account admin and separate-account standard-user UAC approval, cancellation, bad credentials/policy denial, actual primary-token checks and Administrator-protection/session cases; desktop never high | **Open — no UAC tests** |
| G07 Protocol and budgets | All S08–S11 negative cases plus actual pipe framing/deadlines, streaming caps, terminal states, version/security-epoch checks and typed report validation under measured load | **Partial: 34 memory checks plus Medium native-pipe negative cases; privileged boundary/budgets unvalidated** |
| G08 Lifetime/cleanup | Real cancellation/UI/relay/worker exit, late approval, provider hang and crash tests; absolute watchdog; no orphan or incomplete saved report; only exact owned-child cleanup | **Open — Medium read/connection deadlines and disconnects tested; no privileged/UAC supervision** |
| G09 Authoritative engine integrity | Protected full engine/runtime inventory, traced imports/loads, sanitised startup environment, safe native-helper strategy, no caller execution-policy/module overrides or new sensitive command-line capture; unchanged classification/identity semantics | **Open — token-only step must precede full scan** |
| G10 Result ownership/storage | Complete authenticated-session result validated by relay/UI, original-user ownership, cross-account access, CreateNew/rollback failures, no privileged destinations/temp writes, historical compatibility | **Standard-only evidence; elevated path open** |
| G11 Privacy/operational scope | Approved treatment of other users' paths, path-derived group keys and error data; account/credential omission; technician disclosure; supported-platform/account matrix and collection limits | **Open** |
| G12 Independent acceptance | Security review by someone independent of implementation; signed-off A/X evidence for all blocking gates, deployment/rollback runbook and no unresolved high-risk findings | **Open** |

G01–G12 are all blocking. G07 unit results do not waive any native authentication/deployment gate. Each closure needs an evidence artifact, exact source/binary version, OS/account matrix, reviewer and date. Changing an architectural assumption reopens affected gates. No debug/configuration/environment/worker-discovery switch may bypass the production rejection gate. Enablement requires a separate reviewed implementation/release decision, not this milestone.

## Suggested implementation phases

1. Resolve G01 and approve the threat model, protected inventory, privacy scope and native protocol direction. Set up disposable administrator + two-standard-account lab environments.
2. Implement signed/admin-deployed relay and native **token-probe only** worker. Prove ACLs, loader integrity, native UAC, endpoint/lifetime identity and one-way transfer across accounts. No diagnostic PowerShell yet.
3. Implement real bounds/timeouts/cancellation/crash/update/downgrade tests and obtain independent review of that small boundary.
4. Bring the existing authoritative engine into the protected bundle, trace all loads and eliminate mutable/dynamic compilation inputs. Review additional metadata/privacy. Validate original classifications, same-sample aggregation and conservative identities under real high tokens.
5. Validate original-user report saving, enterprise signing/policy/update/removal and complete A/X matrix; close G01–G12. Only then propose a separately authorised production enablement release.

## Milestone conclusion

Designed: threat model, alternatives/conditional hybrid recommendation, protected inventory, UAC/result/IPC lifecycle and acceptance gates. Implemented experimentally: unchanged memory conformance plus native Medium transport tests, primary-token/process observations and fail-closed refusal entry points, recorded in the test plan. Implemented in production: **nothing new**. Demonstrated secure privileged installation/IPC/elevation: **not yet**. The missing native toolchain and administrator-controlled disposable lab remain blockers, not permission to add a user-writable elevated shortcut.
