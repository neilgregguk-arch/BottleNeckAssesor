# WPBD 0.6.5 — partial implementation/validation (B)

19 November 2026; baseline **`b3afc6e`**. Production application **0.6.2**, Standard-only. This report is experimental security evidence, not a native elevated release or security certification.

## 1. Executive summary

Revalidated the 0.6.3/0.6.4 source/design and environment. The required native tooling, approved signer and disposable administrator/multi-account lab remain unavailable or unestablished. Following the prompt's environment gate, performed only non-privileged development, inspection and tests. Added native C++ refusal-stage worker/parser source, a redacted readiness probe, stricter shared endpoint-descriptor policy validation and independent review/deployment/removal preparation. Production source, rejection gate, installer, engine and VERSION are unchanged.

## 2. Completion classification

**B — Partial implementation or validation.** No protected native executable was compiled/deployed; native UAC, High-owned IPC, separate-account operation and protected removal were not exercised. No failed cross-account Windows API assumption has been observed; these tests are unavailable, not successful or a proven architectural failure. There is no basis for A. The conditional hybrid architecture remains unchanged, with no weakened authentication or new privileged fallback.

## 3. Changes since 0.6.4

- `native/Request.h`, `Worker.cpp`, `RequestTests.cpp` and CMake settings: minimal native TokenProbeV1 grammar/own-primary-token refusal source. **Uncompiled**; no working privileged result path.
- `Readiness`: real Medium own-token/known-folder probe, redacted booleans and explicit `authorisesElevation=false`; no lab authorisation can be inferred from it.
- `EndpointDescriptor`: shared exact owner/DACL/mandatory-label content validation. The real Medium pipe read-back now uses it. Added High-candidate policy tests for absent/wrong labels, extra/broad/write/owner/inheritance/identity grants and malformed descriptors; no High object is created.
- Readiness record, independent review brief, explicit fixed-target installation/removal design, five updated security documents, README and changelog. No tool/account/VM/policy installation or reconfiguration.

## 4. Native toolchain and environment readiness

See [readiness](0_6_5_ENVIRONMENT_READINESS.md): Windows NT **10.0.26300 x64**, SDKs **8.0.428/10.0.303**. No detected C++ vswhere instance, native compiler/linker/CMake/signtool command, expected Windows SDK Include/Lib tree or cached AOT pack in inspected locations. Zero code-signing certificates/key associations found in the inspected personal stores; no external/enterprise signer or unsigned-lab exception established. No approved VM, separate admin/second standard account or independent reviewer established. Coarse application-control observations do not authorise unsigned software. No prerequisites were installed automatically.

The C++ target proposes C++20/x64/MSVC, static CRT, asInvoker manifest, warnings-as-errors, CFG/ASLR/NX/CET options and System32-only static-import resolution. **None is an inspected native PE fact.** Native build and 17 compile-time parser checks remain **not executed**. Actual compilation, imports/forwarders/runtime inventory, signing and hostile CWD/PATH/environment loader tests must precede any elevated run. Managed builds are not a substitute.

## 5. Protected installation results

**Not implemented/deployed/tested.** No protected package, staged payload, signed inventory, native relay, security-epoch policy or authorised privileged installation exists. No effective protected-file/ancestor modification, rename/delete/DeleteChild, WRITE_DAC/WRITE_OWNER, dependency replacement or reparse/race test ran. Known-folder resolution and parsed SDDL do not prove filesystem protection. The [review brief](0_6_5_INDEPENDENT_REVIEW_BRIEF.md) gives the fixed immutable version-root, protected staging, complete inventory, signed authorisation and actual denial-test design. No enterprise readiness claim is made.

## 6. Actual Windows UAC results

**Not implemented/executed.** No ShellExecuteExW runas call, real consent, separate credentials, cancellation, incorrect credentials, policy denial, worker start failure/early exit or late approval was tested. No custom credentials, saved-account tool, service/task fallback or UAC policy modification exists. Existing managed relay refuses before launch; native relay and actual retained UAC process-handle validation remain required work. No UAC attempt was made against user-writable builds on the ordinary workstation.

## 7. Actual token observations and native worker status

Readiness used native APIs on the actual current process primary token: inspection succeeded; elevation **false**, integrity **8192 (Medium)**; administrator group present **false**, enabled **false**. No administrator authority is inferred or requested, and no identity/SID/credentials were output. The existing managed worker's canonical Medium request was genuinely refused before any endpoint; high/admin success remains untested.

The new native source validates all 12 argument tokens before own-token queries, allows token-probe-v1 only, bounds token query buffers at 64 KiB and validates primary token/elevation/enabled-admin/High facts. It queries no other process memory, adjusts no privileges and launches/writes nothing. A compile-time unconditional protected-deployment refusal then prevents a result/endpoint even if high. There is no config/environment/argument bypass. The successful operation/IPC sender, protected startup validation and privileged lifetime supervisor remain **unimplemented**. Source inspection is not native execution evidence; these drafts must not be elevated.

## 8. Authenticated IPC results

**21 real Medium Windows transport checks passed** using separate ordinary-user processes, retained actual fixture launch handles, kernel pipe PID/session observations, creation times and live-state checks. The actual Medium owner/DACL/label is read back and validated with the stricter shared policy; native read opens succeed and write opens fail. First-instance/local-only/one-instance and Identification SQOS remain in code. The original 0.6.3 protocol source is unchanged.

These observations bind the Medium test peers only. User-owned pipe DACL and mutable image paths are not protected executable authentication; no High owner/label creation, protected file identity, unrelated-account/remote denial or cross-account authorisation is proven. High descriptor policy conversion/tests are not a communication boundary. No impersonation API or privileged handle/token transfer is used.

## 9. Separate-account testing

**Not executed.** No distinct administrator account/logon/profile was used. Windows process/token query rights across accounts, High-to-original-logon pipe read rights, protected image identity, Administrator protection and other-user/session rejection remain A/X blockers. The design still derives original identity from the retained relay's Windows token and does not equate it with the administrator. No shared-secret/user-writable-manifest shortcut was introduced. No specific cross-account API failure can be claimed before the actual test.

## 10. Negative security and lifecycle results

| Test category | Actual 0.6.5 result | Evidence limit |
| --- | --- | --- |
| Descriptor policy | **21 passed**: Windows in-memory SDDL conversion plus exact content checks; missing/wrong mandatory label, owner, null/unprotected/broad/duplicate/inheritable/write grants and wrong logon rejected | U/Windows serialisation, **no High object or effective-access test** |
| Real Medium transport | **21 passed**, including wrong peers, stale PID/start/session claims, replay/order, oversize prefix, bad UTF-8/duplicates/truncation/after-complete data, cancellation/error, deadlines and disconnect/relay exit | W only; no protected/high/cross-account boundary or real forced PID reuse |
| Real managed refusal | **21 passed**, including Medium-token refusal, command/script/path/operation/privilege/process/service/duplicate/noncanonical/bounds rejection and relay refusal | W only; no high/native successful operation |
| Publish guard | **2 passed**, managed Worker/Relay publication explicitly blocked | Deployment remains absent; copying the binaries would not create trust |
| Original protocol lab | **34 passed**, unchanged UTF-8/schema/size/session/scope/sequence/chunk/digest/terminal-state validator | In-memory conformance, not peer authentication |
| Native parser assertions | **17 pending compilation**, not counted as passing | No native toolchain |

Medium fixture connection/read/absolute supervisor deadlines remain enforced, with retained process lifetime/disconnect checks and scoped handle cleanup. Test processes exited; no arbitrary-PID termination occurs. Privileged watchdogs, native worker crash, UAC cancellation/late approval, active-version update/removal and orphaned high process tests are **not implemented/validated**. No incomplete/error/cancelled transcript is accepted as success in the tested Medium transport. No privileged result, report or temporary file is written.

## 11. Installation/removal validation

**No installation or removal performed.** No protected component, service, task or registration was created, so none is silently left behind. Current ordinary build outputs remain under ignored experimental bin/obj directories; native build settings target ignored `artifacts/native-065`. No runnable privileged installer/remover is supplied while the environment/signing gates are closed.

The independent review brief specifies a fixed known-folder-derived immutable root and reviewed inventory, admin-only staging/authority, handle/reparse/ancestor checks, no caller targets/scripts, protected minimum epoch/rollback policy, active-session coordination and exact safe removal that preserves unrelated files. These are pending design requirements, not an implemented installer. Real interruption, replacement, downgrade, offline trust and complete admin removal must be tested in the approved disposable VM; never delete arbitrary caller paths or relax ACLs to make removal ordinary-user writable.

## 12. Production regressions

**124 PowerShell tests passed**, zero failed/skipped. **21 .NET checks passed** plus missing-engine rejection, including history/HTML/JSON, attribution, unavailable Elevated and rejection before worker launch. Desktop Release build and five experimental managed builds passed with zero warnings/errors. Rebuilding unchanged .NET test source emitted the existing CS8602 at Program.cs:377; no production edit was made to suppress it.

Freshly built Standard engine hashes matched current source. Real Standard scan collected **15/15 samples**, validated original-user ownership/permission reporting/paired reports; cancellation exported no partial report. Sample-work average 0.1846 s, insight analysis 0.3858 s; not elevated performance or security evidence. Production src/desktop/installer/VERSION/Start-WPBD.ps1 diff against baseline is empty, and no production payload glob/reference includes experiments. VERSION stays **0.6.2**. No production installer build or classification/sampling/attribution/schema change occurred.

## 13. Release-gate status

G00 production isolation preserved. **G01–G12 remain blocking**, G07 partial. G04 gains uncompiled native refusal source; it is not a real high worker. G05 gains stricter descriptor content validation, not High/cross-account proof. G03 lacks approved signing/inventory; G01/G02 lack actual protected install/remove/effective permissions. G06 genuine UAC, G08 high lifecycle, G12 independent acceptance remain open. Full diagnostic engine integration (G09) is deliberately excluded. See [exact gate conditions](ELEVATED_DIAGNOSTICS_RELEASE_GATES.md).

## 14. Risks, binary identity and limitations

No protected trust boundary has been certified. Native source may have compilation/runtime/loader defects until compiled/reviewed on approved tooling. Managed startup occurs before guards, so do not elevate the unsigned prototypes. A valid policy descriptor, token JSON or hash cannot authenticate protected executable content; same-user compromise remains an explicit limitation. No signing, ACL, UAC or enterprise policy was weakened to pass tests. No generated binaries, account identities, private keys, credentials, raw workstation reports/configuration exports or privileged session data are committed.

Actual managed test identities from this run (all apphosts **NotSigned**, ordinary mutable build outputs; hashes are evidence identifiers only). Relative directory: `experiments/elevation-worker/<name>/bin/Release/net10.0-windows/`. The paired DLL matters; the apphost hash alone is not its code identity or complete runtime inventory.

| Name | Apphost EXE SHA-256 | Managed DLL SHA-256 |
| --- | --- | --- |
| TransportLab | `cba2442f1117c008bb3497854ff1081c83ab7bf6509d49d962bbc23920f9039c` | `2f30278f5ac0226135e1df4070bb34ea723775e210a16c8833353d7abc9cb7bb` |
| Worker | `0973ea159568021e578c8e7057990f3897004d7d9acf602012ed1a1a5c57cac9` | `a66921cee0cbe5e715797eff4daf75a0c335748fa477cea091dfe0bba3ef4385` |
| Relay | `504505a4e94920c45f19b4a216b51d5e63319c5402f2141641c7faebd8291d61` | `04ea20d118330db16b5f88d6447d254a2fc714ff94111c178eed7067933fb99e` |
| Readiness | `39ca5dfd3bfce3d89274398bfaf805f501c055fa36add056b89ac0acb7ec40d2` | `4ef8b926a6b38087c28934e1231507266f3444912bc521cc39270432c7b8ec27` |
| PolicyTests | `da87cdaaa2561a96198806128d1723e29a58be76fe5e1de3ccf36c81fac67862` | `4ec164daf11fa71a659ecbc1db605fa2a649d1b297493d339b91635f8edb5ed3` |

There is **no native executable identity/hash** to report because no native binary was built. No hashes in this document authorise elevation.

## 15. Next phase

Obtain explicit authorisation for native tooling and an approved disposable multi-account Windows VM/snapshot/recovery process, approved signer or explicit isolated unsigned-lab policy, and independent reviewer. Compile/review the native request/token source and actual complete PE/dependency/load inventory without elevation. Implement the fixed protected relay/worker installer/remover, native runas handle/lifetime path and authenticated High-owned one-way transport only after those prerequisites. Validate actual standard-user denials, separate-account consent, endpoint/MIC/identity/late-consent/deadline/cleanup and complete removal with exact-version evidence. Resolve any observed Windows API limitation in the architecture before continuing. Do not add the diagnostic engine or enable production elevation during that boundary proof.

## 16. Source and Git reference

All code/tests/documentation are committed together on master; baseline is `b3afc6e`. Resolve this milestone's exact commit with `git log -1 --format=%H -- docs/security/MILESTONE_0_6_5_REPORT.md`. The delivered review pack also records the exact final commit/tree in `SOURCE_REVISION.txt`, and the completion reply supplies the commit reference. This avoids embedding a self-referential commit hash into its own content. Generated binaries/raw logs remain outside Git; no privileged tests are implied by the commit.
