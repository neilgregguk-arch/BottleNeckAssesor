using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Elevation.ProtocolLab;

if (args.Length != 1 || args[0] != "--self-test")
{
    Console.Error.WriteLine("Experimental memory-stream lab. Only --self-test is supported.");
    return 2;
}
if (OperatingSystem.IsWindows())
{
    var own = Wpbd.WorkerToken.ReadCurrent();
    if (!own.UnprivilegedDesktop)
    {
        Console.Error.WriteLine("Lab requires a verified non-elevated process; no privileged experiment will run.");
        return 3;
    }
    Console.WriteLine($"LOCAL WINDOWS OBSERVATION: elevated={own.IsElevated}; integrity={own.IntegrityLevel}. No account identity recorded.");
}
Console.WriteLine("CONFORMANCE ONLY: memory streams; no IPC endpoint, UAC, authentication, process launch or privileged operation.");

var command = new[] { "--session", "1234567890abcdef1234567890abcdef", "--relay-pid", "42", "--relay-start", "133000000000000000", "--duration", "30", "--interval", "2", "--operation", "token-probe-v1" };
var request = FrozenRequest.Parse(command);
var tokenBytes = Encoding.UTF8.GetBytes("""{"available":true,"isElevated":false,"integrityRid":8192}""");
var passed = 0;

void Check(string name, Action test) { test(); passed++; Console.WriteLine("PASS " + name); }
static void Require(bool condition) { if (!condition) throw new Exception("Conformance expectation failed."); }
static void Reject(Action action)
{
    try { action(); }
    catch (Exception error) when (error is InvalidDataException or ArgumentException or EndOfStreamException or JsonException) { return; }
    throw new Exception("Invalid input was accepted.");
}
static Frame Message(FrozenRequest scope, int sequence, string kind, object data) => Wire.Decode(JsonSerializer.SerializeToUtf8Bytes(new { v = 1, session = scope.Session.ToString("N"), seq = sequence, kind, data }));
static void Hello(Transcript receiver, FrozenRequest scope) => receiver.Accept(Message(scope, 0, "hello", new { operation = scope.Operation, epoch = 1, requestHash = scope.ScopeHash }));
static string Hash(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
static void Begin(Transcript receiver, FrozenRequest scope, byte[] bytes) => receiver.Accept(Message(scope, 1, "result-begin", new { bytes = bytes.Length, sha256 = Hash(bytes) }));
static void Chunk(Transcript receiver, FrozenRequest scope, int seq, int index, byte[] bytes) => receiver.Accept(Message(scope, seq, "result-chunk", new { index, base64 = Convert.ToBase64String(bytes) }));
static void Finish(Transcript receiver, FrozenRequest scope, int sequence, byte[] bytes) => receiver.Accept(Message(scope, sequence, "complete", new { bytes = bytes.Length, sha256 = Hash(bytes) }));

Check("fixed canonical token-probe arguments", () => Require(request.Duration == 30 && request.Interval == 2 && request.Operation == "token-probe-v1"));
foreach (var flag in new[] { "--script", "--command", "--shell", "--executable", "--output", "--privilege", "--kill", "--service" })
    Check("reject unsupported argument " + flag, () => { var input = (string[])command.Clone(); input[0] = flag; Reject(() => FrozenRequest.Parse(input)); });
Check("reject duplicate and extra arguments", () => { var input = (string[])command.Clone(); input[2] = "--session"; Reject(() => FrozenRequest.Parse(input)); Reject(() => FrozenRequest.Parse(command.Concat(new[] { "--output", "arbitrary" }).ToArray())); });
Check("reject unsupported diagnostic operation", () => { var input = (string[])command.Clone(); input[11] = "diagnose-v1"; Reject(() => FrozenRequest.Parse(input)); });
Check("reject noncanonical/overflow integers and configuration", () =>
{
    foreach (var value in new[] { "042", "+42", "42.0", "4294967296", "42;command", "0" }) { var input = (string[])command.Clone(); input[3] = value; Reject(() => FrozenRequest.Parse(input)); }
    var bad = (string[])command.Clone(); bad[7] = "31"; Reject(() => FrozenRequest.Parse(bad)); bad[7] = "30"; bad[9] = "3"; Reject(() => FrozenRequest.Parse(bad));
});
Check("reject empty and uppercase sessions", () => { var input = (string[])command.Clone(); input[1] = Guid.Empty.ToString("N"); Reject(() => FrozenRequest.Parse(input)); input[1] = command[1].ToUpperInvariant(); Reject(() => FrozenRequest.Parse(input)); });
Check("request hash binds numeric scope, not process identity", () => Require(request.ScopeHash != (request with { RelayPid = 43 }).ScopeHash));
Check("reject oversized length before reading a body", () =>
{
    using var input = new CountingStream(new byte[] { 255, 255, 255, 255, 99 });
    Reject(() => Wire.Read(input)); Require(input.BytesRead == 4);
});
Check("reject zero, truncated prefix and truncated body", () =>
{
    Reject(() => Wire.Read(new MemoryStream(new byte[4])));
    Reject(() => Wire.Read(new MemoryStream(new byte[] { 1, 2 })));
    Reject(() => Wire.Read(new MemoryStream(new byte[] { 10, 0, 0, 0, 123 })));
});
Check("framing failure poisons the whole receiver", () =>
{
    using var receiver = new Transcript(request);
    Reject(() => receiver.ReadNext(new MemoryStream(new byte[] { 255, 255, 255, 255 })));
    Require(receiver.IsFailed); Reject(() => Hello(receiver, request));
});
Check("valid bounded stream frame", () =>
{
    var body = JsonSerializer.SerializeToUtf8Bytes(new { v = 1, session = request.Session.ToString("N"), seq = 0, kind = "hello", data = new { operation = request.Operation, epoch = 1, requestHash = request.ScopeHash } });
    using var stream = new MemoryStream(); Span<byte> prefix = stackalloc byte[4]; BinaryPrimitives.WriteUInt32LittleEndian(prefix, (uint)body.Length); stream.Write(prefix); stream.Write(body); stream.Position = 0;
    Require(Wire.Read(stream).Session == request.Session);
});
Check("reject malformed UTF-8, BOM and JSON", () =>
{
    Reject(() => Wire.Decode(new byte[] { 123, 34, 0xff, 34, 125 }));
    Reject(() => Wire.Decode(new byte[] { 0xef, 0xbb, 0xbf, 123, 125 }));
    foreach (var text in new[] { "{} trailing", "{/*comment*/}", "[]", "null", "{\"v\":1,}" }) Reject(() => Wire.Decode(Encoding.UTF8.GetBytes(text)));
});
Check("reject duplicates, unknown fields and integer coercion", () =>
{
    var valid = JsonSerializer.Serialize(new { v = 1, session = request.Session.ToString("N"), seq = 0, kind = "hello", data = new { operation = request.Operation, epoch = 1, requestHash = request.ScopeHash } });
    foreach (var text in new[] { valid.Replace("\"v\":1", "\"v\":2"), valid.Replace("\"v\":1", "\"v\":1,\"v\":1"), valid.Replace("\"v\":1", "\"v\":1.0"), valid.Replace("\"v\":1", "\"v\":\"1\""), valid.Replace("\"v\":1", "\"v\":1,\"command\":\"x\""), valid.Replace("\"epoch\":1", "\"epoch\":1,\"epoch\":1") }) Reject(() => Wire.Decode(Encoding.UTF8.GetBytes(text)));
});
Check("reject excessive JSON depth", () => Reject(() => Wire.Decode(Encoding.UTF8.GetBytes(new string('[', 10) + "0" + new string(']', 10)))));
Check("reject stale session and sequence; failure is terminal", () =>
{
    using var receiver = new Transcript(request); Hello(receiver, request);
    Reject(() => receiver.Accept(Message(request with { Session = Guid.NewGuid() }, 1, "progress", new { collected = 1, expected = 15 })));
    Require(receiver.IsFailed); Reject(() => receiver.Accept(Message(request, 1, "progress", new { collected = 1, expected = 15 })));
});
Check("reject replayed hello and sequence gaps", () =>
{
    using var replay = new Transcript(request); Hello(replay, request); Reject(() => Hello(replay, request));
    using var gap = new Transcript(request); Reject(() => gap.Accept(Message(request, 2, "hello", new { operation = request.Operation, epoch = 1, requestHash = request.ScopeHash })));
});
Check("reject epoch, operation and scope mismatch", () =>
{
    using var epoch = new Transcript(request); Reject(() => epoch.Accept(Message(request, 0, "hello", new { operation = request.Operation, epoch = 0, requestHash = request.ScopeHash })));
    using var scope = new Transcript(request); Reject(() => scope.Accept(Message(request, 0, "hello", new { operation = request.Operation, epoch = 1, requestHash = new string('0', 64) })));
});
Check("validate monotonic bounded progress", () =>
{
    using var receiver = new Transcript(request); Hello(receiver, request); receiver.Accept(Message(request, 1, "progress", new { collected = 2, expected = 15 }));
    Reject(() => receiver.Accept(Message(request, 2, "progress", new { collected = 1, expected = 15 })));
    using var wrong = new Transcript(request); Hello(wrong, request); Reject(() => wrong.Accept(Message(request, 1, "progress", new { collected = 16, expected = 15 })));
});
Check("result is incomplete until every chunk and digest agree", () =>
{
    using var receiver = new Transcript(request); Hello(receiver, request); Begin(receiver, request, tokenBytes);
    Chunk(receiver, request, 2, 0, tokenBytes[..20]); Require(!receiver.IsComplete);
    Chunk(receiver, request, 3, 1, tokenBytes[20..]); Finish(receiver, request, 4, tokenBytes); Require(receiver.IsComplete);
    Reject(() => receiver.Accept(Message(request, 5, "progress", new { collected = 1, expected = 15 })));
});
Check("reject missing/reordered/excess result data", () =>
{
    using var missing = new Transcript(request); Hello(missing, request); Begin(missing, request, tokenBytes); Reject(() => Finish(missing, request, 2, tokenBytes));
    using var order = new Transcript(request); Hello(order, request); Begin(order, request, tokenBytes); Reject(() => Chunk(order, request, 2, 1, tokenBytes));
    using var excess = new Transcript(request); Hello(excess, request); Begin(excess, request, tokenBytes); Reject(() => Chunk(excess, request, 2, 0, tokenBytes.Concat(new byte[] { 32 }).ToArray()));
});
Check("reject wrong digest and malformed base64", () =>
{
    using var receiver = new Transcript(request); Hello(receiver, request); Begin(receiver, request, tokenBytes);
    Reject(() => receiver.Accept(Message(request, 2, "result-chunk", new { index = 0, base64 = "!not-base64!" })));
    using var corrupt = new Transcript(request); Hello(corrupt, request); Begin(corrupt, request, tokenBytes); Chunk(corrupt, request, 2, 0, tokenBytes);
    Reject(() => corrupt.Accept(Message(request, 3, "complete", new { bytes = tokenBytes.Length, sha256 = new string('0', 64) })));
});
Check("reject operation-specific result and chunk budgets", () =>
{
    using var large = new Transcript(request); Hello(large, request); Reject(() => large.Accept(Message(request, 1, "result-begin", new { bytes = 4097, sha256 = Hash(tokenBytes) })));
    using var chunk = new Transcript(request); Hello(chunk, request); Begin(chunk, request, tokenBytes); Reject(() => Chunk(chunk, request, 2, 0, new byte[32769]));
});
Check("cancel/error terminal states never yield a complete result", () =>
{
    using var cancelled = new Transcript(request); Hello(cancelled, request); Begin(cancelled, request, tokenBytes); cancelled.Accept(Message(request, 2, "cancelled", new { code = "Cancelled" }));
    Require(cancelled.IsCancelled && !cancelled.IsComplete); Reject(() => Chunk(cancelled, request, 3, 0, tokenBytes));
    using var error = new Transcript(request); Hello(error, request); error.Accept(Message(request, 1, "error", new { code = "Timeout" })); Require(!error.IsComplete); Reject(() => Begin(error, request, tokenBytes));
});
Check("unknown operations and output-path requests have no protocol endpoint", () =>
{
    using var receiver = new Transcript(request); Hello(receiver, request); Reject(() => receiver.Accept(Message(request, 1, "execute", new { command = "anything" })));
    using var path = new Transcript(request); Hello(path, request); Reject(() => path.Accept(Message(request, 1, "result-begin", new { bytes = 2, sha256 = Hash(tokenBytes), outputPath = "arbitrary" })));
});
Check("token result schema rejects credentials/unknown fields and preserves nulls", () =>
{
    foreach (var text in new[] { """{"available":true,"isElevated":"true","integrityRid":8192}""", """{"available":true,"isElevated":false,"integrityRid":8192,"accountName":"not-accepted"}""" })
    {
        var bytes = Encoding.UTF8.GetBytes(text); using var receiver = new Transcript(request); Hello(receiver, request); Begin(receiver, request, bytes); Chunk(receiver, request, 2, 0, bytes); Reject(() => Finish(receiver, request, 3, bytes));
    }
    var unavailable = Encoding.UTF8.GetBytes("""{"available":false,"isElevated":null,"integrityRid":null}""");
    using var unknown = new Transcript(request); Hello(unknown, request); Begin(unknown, request, unavailable); Chunk(unknown, request, 2, 0, unavailable); Finish(unknown, request, 3, unavailable); Require(unknown.IsComplete);
});
Check("syntactic high-token claims do not establish authentication", () =>
{
    var bytes = Encoding.UTF8.GetBytes("""{"available":true,"isElevated":true,"integrityRid":12288}""");
    using var receiver = new Transcript(request); Hello(receiver, request); Begin(receiver, request, bytes); Chunk(receiver, request, 2, 0, bytes); Finish(receiver, request, 3, bytes);
    Require(receiver.IsComplete); // Only syntax/completeness; this deliberately authenticates nobody.
});
Check("absolute frame-count ceiling", () =>
{
    using var receiver = new Transcript(request); Hello(receiver, request);
    for (var n = 1; n < 4096; n++) receiver.Accept(Message(request, n, "progress", new { collected = 0, expected = 15 }));
    Reject(() => receiver.Accept(Message(request, 4096, "progress", new { collected = 0, expected = 15 })));
});

Console.WriteLine($"{passed} experimental conformance checks passed. Native privileged deployment/IPC/UAC remain UNTESTED.");
return 0;

sealed class CountingStream(byte[] bytes) : MemoryStream(bytes)
{
    public int BytesRead { get; private set; }
    public override int Read(Span<byte> buffer) { var count = base.Read(buffer); BytesRead += count; return count; }
}
