# WPBD 0.6.3 security architecture — completion report

19 November 2026. Baseline `9135515`; application VERSION remains 0.6.2. This is a research/design milestone, not a completed elevated diagnostic release.

## Executive result

Completed the five requested security documents and an isolated protocol-conformance harness. Recommend **Option B: existing per-user desktop with a separately protected non-elevated relay and one-scan elevated worker**, conditionally on approved deployment/removal policy and real Windows boundary tests. The high worker would own a local read-only results pipe; operation/configuration are fixed at native UAC launch, and cancellation closes the session. No general administrative request channel is proposed.

Nothing was enabled or added to the production execution path. The same Standard-only installer remains current. There is no 0.6.3 installer, privileged executable/service or deployed IPC endpoint.

## Findings and alternatives

Fresh repository inspection confirms LocalAppData/lowest-privilege installation, external mutable Standard PowerShell dependencies, asInvoker desktop, native token/coverage reporting and rejection before any elevated worker launch. Fresh ACL inspection of the actual installed 0.6.2 executable confirms original-user ownership/write access.

Option A protects the entire disk deployment but unnecessarily moves ordinary desktop installation/update/removal into an administrator-managed lifecycle. It remains a possible enterprise alternative. Option C, an on-demand service/COM/RPC broker, adds registration, persistent attack surface/lifetime and potentially broader system authority without a current need. Option B preserves Standard UX and minimises the separately trusted inventory, but has a real policy conflict: protected-component removal needs administrator/enterprise authority. That decision must be approved; no low-user deletion right or silent leftover is acceptable.

## Threat model and proposed worker

The [threat model](ELEVATED_DIAGNOSTICS_THREAT_MODEL.md) covers all eight requested actors, assets and boundaries, with 18 scenarios and preconditions/capabilities, impact, mitigation, residual risk and validation mapping. Malicious fully privileged administrators/kernel/supply-chain compromise are outside the containment guarantee. A compromised original-user session can control ordinary UI processes and read returned data; disk protection does not make that session trustworthy. The worker must remain incapable of arbitrary privileged operations even then.

The proposed worker accepts only canonical session/relay identity/duration/interval/fixed-operation tokens. No script, executable, command, shell, output path, privilege adjustment, service or process-control request is accepted. Native/AOT token-probe comes first. Retaining the current authoritative PowerShell diagnostic engine later requires a protected complete dependency inventory, sanitised startup/load paths and traced imports; user-writable scripts or checksum files cannot authorise privileged execution.

## IPC/UAC/result design

The [protocol](ELEVATED_DIAGNOSTICS_IPC_PROTOCOL.md) specifies a high-owned outbound pipe, original-logon read-only ACL and mandatory-label policy, first-instance/local-only restrictions, kernel endpoint PID checks paired with retained launch/process handles, creation time, protected image/version and original token/session binding. Caller PID/name/nonces alone do not authenticate. Different administrator and original-user accounts must not be assumed to share SIDs/profiles. Identification SQOS is explicit; no privileged token/handle is delivered to the UI.

Native ShellExecuteEx runas is the only proposed approval mechanism. No custom credentials, caching, saved-account tools, policy changes or automatic alternate mechanism. Worker verifies its own primary token. Administrator protection and separate-account scenarios need real tests. Sensitive results go through bounded strict UTF-8/JSON framing, frozen scope and sequence checks, typed validation, full byte/digest/completion checks and ordinary-user saving. Digests detect corruption, not malicious peers or edited saved reports. Privacy approval must cover embedded usernames in paths/group keys/errors as well as explicit fields.

See [architecture](ELEVATED_DIAGNOSTICS_ARCHITECTURE.md) for the diagram, inventory, ACLs, updates, signing/offline trust, lifecycle and remaining risks.

## Evidence: implemented versus tested

| Category | Result |
| --- | --- |
| Design | Five requested documents complete, with primary Microsoft references and explicit assumptions |
| Experimental code | Standalone memory-stream harness; production has no reference to it |
| Experimental tests | **34 conformance checks passed**: arguments, bounds-before-body-read, strict UTF-8/JSON, duplicates/types, scope/replay/sequence, chunks/digests, terminal states and token-result schema |
| Real local observation | Harness's own Windows process was not elevated and had Medium integrity; no account identity recorded |
| What that does not prove | No protected installation, native endpoint authentication, pipe ACL/MIC, UAC, timeout supervision or cross-account privilege separation was implemented/tested |
| Production regressions | **124 PowerShell tests passed; 21 .NET checks passed**, plus existing missing-engine error check |
| Desktop build | Release succeeded with zero warnings/errors |
| Real Standard integration | Current-source engine hashes matched; 15/15 samples with 15 valid CPU samples; original-user report ownership and WPF/HTML permission consistency verified; cancellation produced no partial report. Average sample work 0.1948 s, insight analysis 0.0863 s; not an elevated benchmark. |
| Source preservation | `git diff 9135515 -- src desktop installer VERSION Start-WPBD.ps1` is empty; engine hashes used for final live test match source |
| Packaging | No installer build/change; experimental project lies outside production project/content globs; no binaries, live reports or credentials committed |

A deliberately valid synthetic high-token transcript passes syntax/completeness tests; it authenticates nobody. This explicit test prevents confusing structured claims with genuine elevation. No mocked security-boundary test is counted as native security validation.

## Blockers and exact release gates

All blocking gates G01–G12 remain open: lifecycle approval; protected ACL/inventory; signing/update/downgrade policy; narrow real worker; native IPC boundary; genuine UAC/account matrix; real transport/resource limits; lifecycle/watchdogs; protected authoritative engine; elevated result ownership/storage; privacy; independent security acceptance. G07 has only a unit-conformance subset. G00 production isolation is preserved. [The gate document](ELEVATED_DIAGNOSTICS_RELEASE_GATES.md) gives closure evidence for every gate; none can be waived by passing codec tests.

No administrator-controlled deployment or separate-account test environment was used. The [test plan](ELEVATED_DIAGNOSTICS_TEST_PLAN.md) distinguishes design, unit, mock, real Standard Windows and administrator/separate-account requirements for each scenario. Real UAC refusal/approval, protected path/loader changes, native peer spoofing, effective security descriptors, downgrade/update and orphan cleanup remain unexecuted release blockers.

## Next implementation phases

1. Approve hybrid lifecycle/privacy/threat model and prepare a disposable multi-account administrator lab.
2. Build/deploy only a protected native token-probe relay/worker; prove native UAC, cross-account identity, pipe rights and one-way transfer.
3. Validate resource/lifetime/failure/update controls and independent review of that small boundary.
4. Introduce the protected authoritative engine with full dependency tracing/minimisation; compare original classifications and attribution under real high tokens.
5. Close every gate with exact-version evidence and approval. Only a separately authorised release may remove the production rejection gate.

Designed is not implemented; unit-tested is not authenticated; a successful Standard scan is not an elevated test. **Production elevation remains disabled.**
