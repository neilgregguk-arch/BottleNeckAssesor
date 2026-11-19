# WPBD 0.6.4 — partial proof of concept (B)

19 November 2026. Baseline `e50dd89`; application VERSION **0.6.2**, Standard-only. This is an experimental security milestone, not a validated protected-worker release. No new production installer or privilege path exists.

## 1. Summary

Reviewed all seven requested 0.6.3 documents/experiment instructions and the actual repository. Added isolated native Windows observation/transport primitives, a separate-process Medium transport lab and refusal-stage worker/relay entry points under `experiments/elevation-worker`. The original protocol validator is linked unchanged. Real transport and negative tests are progress beyond memory simulation, but both peers remain non-elevated with user-writable images.

**Classification B, partial proof of concept.** A working protected elevated TokenProbeV1, native UAC launch, cross-account authentication and safe protected deployment/removal have not been implemented or demonstrated. No component is production-ready and no privileged gate is closed. The prompt explicitly permits only safely testable portions when administrator-controlled testing is unavailable; no shortcut is used to label this A.

## 2. Selected implementation architecture

Retain Option B: per-user Standard desktop plus separately protected asInvoker relay and one-shot native/AOT worker. The candidate high worker owns a local-only outbound results pipe; original-logon relay is read-only, arguments select only TokenProbeV1, and native Windows UAC is the sole future launch mechanism. There is no general administrative command channel. The current native/AOT toolchain and disposable multi-account prerequisites are missing, so this milestone implements only the safe subset. No successful elevated path or `ShellExecuteExW(runas)` call is present.

No security assumption changed. The Medium lab has its own namespace and owner/label model; it is not a revised High endpoint policy. The original [architecture](ELEVATED_DIAGNOSTICS_ARCHITECTURE.md), [threat model](ELEVATED_DIAGNOSTICS_THREAT_MODEL.md) and [protocol](ELEVATED_DIAGNOSTICS_IPC_PROTOCOL.md) now describe that separation.

## 3. Protected deployment evidence

**None: no protected components installed.** Existing per-user production source/installer is unchanged. The Windows Program Files known-folder API is implemented/tested independently of a changed caller environment variable; that alone proves no filesystem protection. Native C++/Windows SDK build tools were not detected via installed-tool inventory/vswhere; native/AOT compilation was not attempted. No signer/inventory trust anchor, protected immutable version tree, effective file/ancestor ACL test, loader trace, staging/update floor or reviewed admin removal package exists.

Managed project builds are for Medium/refusal tests only. Worker/Relay publication is explicitly blocked before deployment output; their unconditional deployment gate has no debug/config/environment bypass. The existing application and normal installer do not reference experimental projects. Copying managed output to Program Files would not satisfy the missing inventory/startup/dependency tests and is not an installation instruction.

## 4. Worker and relay behaviour

Worker accepts only the existing canonical six-pair TokenProbeV1 grammar. It queries its **own primary process token** through TOKEN_QUERY and requires actual elevation, enabled administrator group and High-or-above integrity before the protected-package gate. The tested Medium invocation returns refusal without an endpoint. Unsupported commands/scripts/executables/destinations/privilege adjustments/process or service controls are rejected before token inspection. The successful elevated operation remains unimplemented.

Relay supports only explicit `--probe`. It requires a genuine non-elevated Medium primary token, resolves the known folder and refuses the unavailable protected package before any UAC or launch. Neither relay nor worker starts a process, executes PowerShell, writes reports/configuration, adjusts privileges, stores credentials or creates an endpoint. Both have asInvoker manifests. The managed runtime starts before application guards, so these unreviewed builds **must not be elevated**; do not infer a safe privileged startup from the guards.

Only the Medium TransportLab launches children: the exact same fixed lab executable, non-elevated, using fixed fixture modes. It retains the actual process launch handle before peer inspection. Native peer handles request only limited query/synchronisation, never terminate, VM or token-duplication authority. Token/user/logon facts used to correlate peers remain in memory; no administrator name/SID/credentials are returned or committed. The successful transport sends only actual own Medium elevation/integrity facts in the existing token schema.

## 5. Genuine Windows UAC results

**Not executed:** same-account consent, separate-account credentials, incorrect credentials, cancellation, policy denial, late approval and protected worker launch failure. No UAC API is called. The documented ShellExecuteExW runas/retained launch handle sequence remains the required implementation. No service/task/saved-credential fallback or policy change is added.

Host evidence: Windows NT **10.0.26300 x64**; observed primary token elevation false, integrity 8192 (Medium), administrator group not enabled. Account membership/type beyond this token was not established; a filtered administrator cannot be relabelled an ordinary standard account. UAC registry values were read only: EnableLUA=1, ConsentPromptBehaviorAdmin=5, ConsentPromptBehaviorUser=3, PromptOnSecureDesktop=1. These values are not genuine consent/credential test results. No disposable multi-account administrator lab was established or protected installation attempted on this workstation.

## 6. Cross-account communication

**Not executed.** All fixture processes run in the original user's logon/session at Medium. No separate administrator/other-user/other-session authentication, High-to-Medium access, Administrator protection or cross-account process-token query is proven. The protocol must derive original-user/logon/session from Windows and must not equate them with the administrator's identity. Failure to obtain required facts remains an abort, not a caller-claim fallback.

## 7. IPC authentication and authorisation

Real lab pipes use outbound/overlapped/first-instance/local-only/single-instance creation and native read-only Identification-SQOS client open. Windows endpoint PID/session APIs are checked against retained peer handles, creation times and live state. The supervisor additionally compares the actual launched fixture process and image/logon/user consistency before sending. Wrong client/server checks are distinct from schema validation, and the protocol binds session/sequence/frozen request separately.

The actual Medium owner, three-entry DACL and Medium no-write-up label are read back; read opens work and write opens fail. This is not a complete effective-access audit: the original user owns the object and can change its DACL, and image-path equality does not authenticate immutable protected code. High/admin ownership, mandatory-label creation, original-logon effective access, remote rejection and unrelated accounts need real A/X tests. No impersonation API, privileged token or privileged handle transfer is used. Candidate high-pipe policy remains unchanged and unvalidated.

## 8. Negative and lifetime evidence

**21 real Medium transport checks passed** (full list in the [test plan](ELEVATED_DIAGNOSTICS_TEST_PLAN.md)): native peer mismatch, first-instance collision, write-open denial, connect cancellation, oversize/UTF-8/duplicate/sequence/stale-session/truncation/after-completion rejection, cancellation/provider-error incomplete results, idle deadline, server disconnect and relay exit. Negative frame tests require the expected failure type; mere EOF cannot pass malformed-size/schema cases. A valid bounded transcript succeeds only after complete validation and EOF.

**21 real non-elevated executable refusal checks passed** for worker token/input restrictions and relay refusal. **Two publish guards passed**: Worker/Relay cannot produce deployment packages. The current guards are deliberate blockers, not evidence of protected execution.

Fixture read limits are five seconds (400 ms idle case); supervisor limit eight seconds, connect-cancel test 250 ms. Native process/pipe/token handles are scoped/disposed; child exit is observed and disconnected pipes rejected. No arbitrary-PID kill occurs. These tests do not prove privileged watchdogs, forced crashes, real PID reuse, late UAC approval or orphan cleanup. No protected file tampering, DLL/CWD/PATH substitution or admin removal test ran.

## 9. Protocol conformance

**34 original in-memory checks passed**, with the 0.6.3 source unchanged. The async pipe adapter validates frame lengths before allocation/body read and delegates exact UTF-8/JSON/schema/sequence/scope/chunk/digest checks to that validator. Limits remain 64 KiB frames, 32 KiB chunks, 4 KiB token result, 4096 frames/session, exact terminal completion. No wire format, diagnostic operation or production report schema changed. Protocol validity, native peer correlation and permission to participate are distinct; none substitutes for the missing protected/cross-account boundary.

## 10. Production regressions

- **124 PowerShell tests passed**, zero failed/skipped.
- **21 .NET checks passed** plus missing-engine rejection; historical HTML/JSON, attribution, unavailable Elevated and pre-launch rejection covered. Rebuilding unchanged test source emitted existing CS8602 at Program.cs:377; production source was not altered to silence it.
- Desktop Release build passed with zero warnings/errors. All three experimental builds passed with zero warnings/errors; no native/AOT or installer build claimed.
- Real Standard integration used a freshly built engine after source-hash matching: **15/15 samples**, original-user ownership, permissions consistency and paired reports passed; cancellation exported no partial report. Average sample work 0.2660 s, insight 0.3919 s. This is not elevated/performance-boundary evidence.
- `git diff e50dd89 -- src desktop installer VERSION Start-WPBD.ps1` is empty. No production reference or payload glob includes experiments. VERSION remains 0.6.2 and the unconditional production rejection gate remains intact.

## 11. Release gates

G00 production isolation is preserved. **G01–G12 remain blocking**, with partial G07 conformance/Medium transport evidence. G04 has refusal-stage source, not a working native high worker. G05 has Medium-only transport, not protected/high/cross-account authentication. G08 has Medium disconnect/deadline evidence, not privileged supervision. Experimental admin-controlled lifecycle testing is authorised by the prompt, but no safe installer/removal implementation or A/X evidence closes G01/G02/G03. The authoritative PowerShell engine remains completely outside this experiment (G09 intentionally deferred). See [exact gates](ELEVATED_DIAGNOSTICS_RELEASE_GATES.md).

## 12. Build, inspect, install and remove

Run `experiments/elevation-worker/Test-Experiment.ps1` **without elevation**, with Windows x64/.NET 10 SDK; see the [experimental README](../../experiments/elevation-worker/README.md). Builds are isolated under ignored experimental bin/obj, with no generated binaries in Git. Review source and native transient descriptor tests. No installer/protected software/service/task/registration is created, so there is no privileged uninstall operation. Ordinary build outputs can be cleaned per project with `dotnet clean` or removal of only those bin/obj folders after exit.

Installation is **blocked**, not a manual-copy workaround. A future disposable-VM-only package must be built natively/AOT with reviewed signed inventory, fixed known-folder root, protected staging, effective ancestor/file ACL/reparse/load tests and explicit admin-only removal. Never invoke an elevated script/custom action with arbitrary caller paths. Record the exact inventory and prove complete authorised removal before claiming the package safe. Current managed builds are not that package.

## 13. Risks and blockers

Missing native toolchain, approved signing/inventory/minimum-version policy, safe protected installer/removal, disposable multi-account lab and independent review prevent a validated A result. Medium object ownership and mutable images cannot be used as privileged trust anchors. Managed runtime startup precedes application guards; no elevation of these builds is supported. Actual High descriptor/SQOS/cross-account rights, native UAC handle identity, loader integrity, effective protected-file access and privileged lifetime/late-consent control are unresolved. All 23 requested security scenarios are individually classified in the test plan; unexecuted scenarios remain blockers, not passes. No security control was weakened or credential/diagnostic report committed.

## 14. Recommended next milestone

Provision a disposable Windows x64 VM with standard user, separate authorised support administrator and second standard account, UAC enabled and approved native/AOT build tools. Independently review the small native TokenProbeV1 relay/worker and fixed admin-only install/remove package, immutable inventory/signing and loader policy **before UAC**. Then implement and test exact protected launch handles, High-owned outbound pipe, native peer/logon/session identity, effective ACL/MIC and cross-account access, refusal/cancellation/policy/late-approval/watchdog paths and complete removal. Resolve any failed Windows assumption in the architecture before proceeding. Do not add the full diagnostic engine or enable production elevation as part of that boundary proof.
