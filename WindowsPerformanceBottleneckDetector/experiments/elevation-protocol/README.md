# Experimental protocol-conformance harness

**Not an elevated worker, IPC implementation or authentication demonstration.** Production does not reference/package this project. It creates no endpoint, launches no process, requests no UAC, writes no diagnostic reports/configuration and handles no credentials. It refuses an elevated or unverifiable Windows execution context. The only native observation is its own current token through the existing read-only helper.

The recommended architecture was documented before this code. Real protected deployment and authenticated cross-account IPC cannot be established in the current non-administrator context, so no user-writable privileged shortcut was built. This smaller experiment makes the proposed bounds, argument grammar and transcript state machine independently executable. A valid transcript is **not** proof of a trusted peer or real elevation.

```powershell
dotnet run --project .\experiments\elevation-protocol\Elevation.ProtocolLab.csproj -c Release -- --self-test
```

Run from the repository root under an ordinary user with .NET 10. No test packages/network services are needed after the normal SDK restore. `--self-test` is the only external command. Internally exercised invocation parsing accepts token-probe-v1 only; it does not execute parsed requests. A future privileged worker must not load this experimental managed executable from a user-writable directory.

The lab uses MemoryStream frames and simulated transcripts. It checks UTF-8/JSON bounds, duplicate/unknown fields, integer types, scope, sequence, progress, chunk/digest completeness, terminal errors/cancellation and fixed arguments. Token-probe result size is limited to 4 KiB; general proposed framing retains its 64 KiB frame/32 KiB chunk bounds. No Windows pipe DACL, MIC, PID/handle proof, UAC, timeout, installation, update or cross-account boundary is tested. See the five documents in `docs/security` for those release blockers.
