using System.Buffers.Binary;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using Elevation.ProtocolLab;
using Wpbd.ElevationExperiment;

// Real Windows transport tests, deliberately BOTH endpoints Medium and user-writable.
// No UAC, privileged endpoint, deployment, service, process termination or credentials.
using var own = Peer.Current();
own.RequireMedium(); // Also enforced before accepting internal fixture arguments.
var modes = new[] { "valid", "wrong-client", "wrong-server", "oversize", "malformed", "duplicates", "sequence", "replay", "truncated", "appended", "cancelled", "error", "idle", "server-exit", "relay-exit" };
if (args.Length != 0 && args[0] == "--fixture") return await FixtureAsync();
if (args.Length != 1 || args[0] != "--self-test") return 2;

Console.WriteLine("MEDIUM WINDOWS TRANSPORT ONLY: protected installation, high MIC/owner, UAC and cross-account authentication are UNTESTED.");
Console.WriteLine($"LOCAL primary token: elevated={own.Elevated}; integrityRid={own.Integrity}; enabledAdministrator={own.AdminEnabled}. No identities logged.");
var passed = 0;
async Task Check(string name, Func<Task> test)
{
    await test(); passed++;
    Console.WriteLine("PASS " + name);
}
static void Require(bool result) { if (!result) throw new InvalidOperationException("Transport expectation failed."); }

await Check("Windows known-folder API resolves Program Files independently of environment", () =>
{
    var before = Native.ProgramFiles();
    var value = Environment.GetEnvironmentVariable("ProgramFiles");
    try { Environment.SetEnvironmentVariable("ProgramFiles", @"Z:\Untrusted"); Require(Native.ProgramFiles() == before && Path.IsPathFullyQualified(before)); }
    finally { Environment.SetEnvironmentVariable("ProgramFiles", value); }
    return Task.CompletedTask;
});
await Check("retained process creation time and session reject substituted claims", () =>
{
    own.Match(own.Pid, own.Session, own.Start);
    foreach (var input in new[] { (own.Pid, own.Session, own.Start + 1), (own.Pid + 1, own.Session, own.Start), (own.Pid, own.Session + 1, own.Start) })
    {
        try { own.Match(input.Item1, input.Item2, input.Item3); throw new Exception("Substitution accepted."); }
        catch (InvalidDataException) { }
    }
    return Task.CompletedTask;
});
await Check("native pipe owner/DACL/Medium label read back; no broad read grant", () =>
{
    using var pipe = LabPipe.Server(Guid.NewGuid(), own); LabPipe.InspectDescriptor(pipe, own);
    return Task.CompletedTask;
});
await Check("first-instance server rejects an existing endpoint", () =>
{
    var session = Guid.NewGuid(); using var pipe = LabPipe.Server(session, own);
    try { using var second = LabPipe.Server(session, own); throw new Exception("Duplicate endpoint accepted."); }
    catch (Win32Exception e) when (e.NativeErrorCode == 5) { }
    return Task.CompletedTask;
});
await Check("native outbound pipe denies client write access", () =>
{
    var session = Guid.NewGuid(); using var pipe = LabPipe.Server(session, own);
    using var write = Native.CreateFileW(LabPipe.Name(session), 2, 0, IntPtr.Zero, 3, Native.Overlapped | 0x00110000, IntPtr.Zero);
    var error = System.Runtime.InteropServices.Marshal.GetLastWin32Error();
    Require(write.IsInvalid && error == 5);
    return Task.CompletedTask;
});
await Check("unconnected overlapped server cancels with a bounded deadline", async () =>
{
    using var pipe = LabPipe.Server(Guid.NewGuid(), own);
    using var deadline = new CancellationTokenSource(TimeSpan.FromMilliseconds(250));
    try { await pipe.WaitForConnectionAsync(deadline.Token); throw new Exception("Connection unexpectedly succeeded."); }
    catch (OperationCanceledException) when (deadline.IsCancellationRequested) { }
});
foreach (var mode in modes)
    await Check("separate Medium processes: " + mode, () => RunCaseAsync(mode));
Console.WriteLine($"{passed} real Medium Windows checks passed. These do not validate a privileged boundary.");
return 0;

FrozenRequest Scope(Guid session, Peer relay) => FrozenRequest.Parse(new[]
{
    "--session", session.ToString("N"), "--relay-pid", relay.Pid.ToString(CultureInfo.InvariantCulture),
    "--relay-start", relay.Start.ToString(CultureInfo.InvariantCulture), "--duration", "30", "--interval", "2", "--operation", "token-probe-v1"
});

async Task RunCaseAsync(string mode)
{
    var session = Guid.NewGuid();
    using var server = LabPipe.Server(session, own);
    using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(8));
    var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
    foreach (var value in new[] { "--fixture", mode, session.ToString("N"), own.Pid.ToString(CultureInfo.InvariantCulture), own.Start.ToString(CultureInfo.InvariantCulture) }) start.ArgumentList.Add(value);
    using var child = Process.Start(start) ?? throw new InvalidOperationException("Fixture start failed.");
    // Retain the actual launch process handle BEFORE inspecting a PID; never manage an arbitrary PID.
    _ = child.SafeHandle;
    var stdout = child.StandardOutput.ReadToEndAsync(); var stderr = child.StandardError.ReadToEndAsync();
    using var peer = new Peer((uint)child.Id);
    Require(peer.Start == child.StartTime.ToFileTime() && peer.Image == own.Image && peer.Logon == own.Logon && peer.User == own.User);
    peer.RequireMedium();
    try
    {
        await server.WaitForConnectionAsync(deadline.Token);
        if (mode == "wrong-client")
        {
            try { LabPipe.AuthenticateClient(server, own, own.Start); throw new Exception("Wrong client accepted."); }
            catch (InvalidDataException) { }
        }
        else
        {
            LabPipe.AuthenticateClient(server, peer, peer.Start);
            if (mode == "relay-exit")
            {
                await child.WaitForExitAsync(deadline.Token);
                Require(!peer.Alive);
                try { await server.WriteAsync(new byte[] { 1 }, deadline.Token); throw new Exception("Dead relay accepted data."); }
                catch (IOException) { }
            }
            else if (mode == "idle")
                await child.WaitForExitAsync(deadline.Token); // Child enforces its own 400ms read deadline.
            else if (mode is not ("server-exit" or "wrong-server"))
                await SendAsync(server, Scope(session, peer), mode, deadline.Token);
        }
    }
    finally { server.Dispose(); } // EOF / cancellation, never a privileged write destination.
    await child.WaitForExitAsync(deadline.Token);
    var output = await stdout; var error = await stderr;
    if (child.ExitCode != 0 || !string.IsNullOrEmpty(output) || !string.IsNullOrEmpty(error))
        throw new InvalidOperationException($"Fixture {mode} failed with code {child.ExitCode}; outputPresent={output.Length != 0}; errorPresent={error.Length != 0}.");
    Require(!peer.Alive);
}

async Task<int> FixtureAsync()
{
    if (args.Length != 5 || !modes.Contains(args[1], StringComparer.Ordinal)) return 2;
    // Reuse the canonical request parser to reject alternate numeric/session spellings.
    var claim = FrozenRequest.Parse(new[] { "--session", args[2], "--relay-pid", args[3], "--relay-start", args[4], "--duration", "30", "--interval", "2", "--operation", "token-probe-v1" });
    using var server = new Peer(claim.RelayPid);
    server.RequireMedium();
    if (server.Start != claim.RelayStart || server.Image != own.Image || server.Logon != own.Logon || server.User != own.User) return 3;
    // A user-writable image comparison is test correlation, NOT protected executable authentication.
    using var pipe = LabPipe.Client(claim.Session);
    var mode = args[1];
    if (mode == "wrong-server")
    {
        try { LabPipe.AuthenticateServer(pipe, own, own.Start); return 9; }
        catch (InvalidDataException) { return 0; }
    }
    // Authentication failures in all other cases are test failures, never protocol negatives.
    LabPipe.AuthenticateServer(pipe, server, server.Start);
    try
    {
        if (mode == "relay-exit") return 0;
        using var deadline = new CancellationTokenSource(TimeSpan.FromMilliseconds(mode == "idle" ? 400 : 5000));
        await LabPipe.ReceiveAsync(pipe, Scope(claim.Session, own), deadline.Token);
        return mode == "valid" ? 0 : 5;
    }
    catch (OperationCanceledException) { return mode == "idle" ? 0 : 6; }
    catch (Exception e) when (e is InvalidDataException or EndOfStreamException or JsonException or IOException or System.Text.DecoderFallbackException)
    {
        // Require the intended rejection, so an EOF cannot pass an oversized/schema test.
        var expected = mode switch
        {
            "oversize" or "sequence" or "replay" or "appended" or "cancelled" or "error" => e is InvalidDataException,
            "malformed" => e is System.Text.DecoderFallbackException,
            "duplicates" => e is InvalidDataException,
            "truncated" => e is EndOfStreamException,
            "server-exit" or "wrong-client" => e is EndOfStreamException or IOException,
            _ => false
        };
        return expected ? 0 : 7;
    }
}

static async Task SendAsync(Stream stream, FrozenRequest scope, string mode, CancellationToken cancellation)
{
    async Task Raw(byte[] body)
    {
        var header = new byte[4]; BinaryPrimitives.WriteUInt32LittleEndian(header, (uint)body.Length);
        await stream.WriteAsync(header, cancellation); await stream.WriteAsync(body, cancellation);
    }
    async Task Message(int seq, string kind, object data, Guid? session = null) => await Raw(JsonSerializer.SerializeToUtf8Bytes(new { v = 1, session = (session ?? scope.Session).ToString("N"), seq, kind, data }));
    if (mode == "oversize") { var size = new byte[4]; BinaryPrimitives.WriteUInt32LittleEndian(size, Wire.MaxFrameBytes + 1); await stream.WriteAsync(size, cancellation); return; }
    if (mode == "malformed") { await Raw(new byte[] { 0xc0, 0xaf }); return; }
    if (mode == "duplicates") { await Raw("{\"v\":1,\"v\":1}"u8.ToArray()); return; }
    if (mode == "truncated") { var size = new byte[4]; BinaryPrimitives.WriteUInt32LittleEndian(size, 100); await stream.WriteAsync(size, cancellation); await stream.WriteAsync(new byte[] { 1, 2 }, cancellation); return; }
    await Message(mode == "sequence" ? 1 : 0, "hello", new { operation = scope.Operation, epoch = 1, requestHash = scope.ScopeHash }, mode == "replay" ? Guid.NewGuid() : null);
    if (mode is "sequence" or "replay") return;
    if (mode is "cancelled" or "error") { await Message(1, mode, new { code = mode == "cancelled" ? "Cancelled" : "ProviderFailure" }); return; }
    // Actual own primary token observations, not a synthetic high claim. Still Medium only.
    using var token = Peer.Current(); token.RequireMedium();
    var bytes = JsonSerializer.SerializeToUtf8Bytes(new { available = true, isElevated = token.Elevated, integrityRid = token.Integrity });
    var digest = Convert.ToHexStringLower(SHA256.HashData(bytes));
    await Message(1, "result-begin", new { bytes = bytes.Length, sha256 = digest });
    await Message(2, "result-chunk", new { index = 0, base64 = Convert.ToBase64String(bytes) });
    await Message(3, "complete", new { bytes = bytes.Length, sha256 = digest });
    if (mode == "appended") await Message(4, "hello", new { operation = scope.Operation, epoch = 1, requestHash = scope.ScopeHash });
}
