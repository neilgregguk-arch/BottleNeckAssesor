using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Elevation.ProtocolLab;

// Syntax and memory-stream conformance only. No peer authentication or privileged operation exists here.
public sealed record FrozenRequest(Guid Session, uint RelayPid, long RelayStart, int Duration, int Interval, string Operation)
{
    public string ScopeHash => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(
        FormattableString.Invariant($"v1|{Session:N}|{RelayPid}|{RelayStart}|{Duration}|{Interval}|{Operation}"))));

    public static FrozenRequest Parse(string[] args)
    {
        var allowed = new[] { "--session", "--relay-pid", "--relay-start", "--duration", "--interval", "--operation" };
        if (args.Length != 12) throw new ArgumentException("Exactly six fixed argument pairs are required.");
        var fields = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var n = 0; n < args.Length; n += 2)
            if (!allowed.Contains(args[n], StringComparer.Ordinal) || !fields.TryAdd(args[n], args[n + 1]))
                throw new ArgumentException("Unknown or duplicate argument.");
        if (!Guid.TryParseExact(fields["--session"], "N", out var session) || session == Guid.Empty || fields["--session"] != session.ToString("N"))
            throw new ArgumentException("Noncanonical session.");
        static long Integer(string value, long maximum)
        {
            if (!long.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var number) || number < 1 || number > maximum || number.ToString(CultureInfo.InvariantCulture) != value)
                throw new ArgumentException("Noncanonical positive integer.");
            return number;
        }
        var pid = (uint)Integer(fields["--relay-pid"], uint.MaxValue);
        var start = Integer(fields["--relay-start"], long.MaxValue);
        var duration = (int)Integer(fields["--duration"], 300);
        var interval = (int)Integer(fields["--interval"], 10);
        if (!new[] { 30, 60, 120, 300 }.Contains(duration) || !new[] { 1, 2, 5, 10 }.Contains(interval) || interval > duration || fields["--operation"] != "token-probe-v1")
            throw new ArgumentException("Unsupported operation or sampling configuration.");
        return new(session, pid, start, duration, interval, "token-probe-v1");
    }
}

public sealed record Frame(Guid Session, int Sequence, string Kind, JsonElement Data);

public static class Wire
{
    public const int MaxFrameBytes = 65536;
    public const int MaxChunkBytes = 32768;
    public const int MaxResultBytes = 64 * 1024 * 1024;
    public const int MaxTokenResultBytes = 4096;
    public static readonly UTF8Encoding StrictUtf8 = new(false, true);

    public static Frame Read(Stream stream)
    {
        Span<byte> prefix = stackalloc byte[4];
        stream.ReadExactly(prefix);
        var length = BinaryPrimitives.ReadUInt32LittleEndian(prefix);
        if (length < 2 || length > MaxFrameBytes) throw new InvalidDataException("Frame length rejected before body allocation.");
        var body = new byte[(int)length];
        stream.ReadExactly(body);
        return Decode(body);
    }

    public static Frame Decode(byte[] body)
    {
        if (body.Length < 2 || body.Length > MaxFrameBytes || body.AsSpan().StartsWith(new byte[] { 0xef, 0xbb, 0xbf }))
            throw new InvalidDataException("Invalid frame body.");
        _ = StrictUtf8.GetString(body); // Reject invalid bytes instead of inserting replacement characters.
        using var document = JsonDocument.Parse(body, new JsonDocumentOptions { MaxDepth = 8 });
        RejectDuplicates(document.RootElement);
        Exact(document.RootElement, "v", "session", "seq", "kind", "data");
        var root = document.RootElement;
        if (Integer(root, "v") != 1) throw new InvalidDataException("Unsupported protocol.");
        var sessionText = Text(root, "session");
        if (!Guid.TryParseExact(sessionText, "N", out var session) || session == Guid.Empty || sessionText != session.ToString("N"))
            throw new InvalidDataException("Invalid session.");
        var sequence = Integer(root, "seq");
        if (sequence < 0) throw new InvalidDataException("Invalid sequence.");
        return new(session, sequence, Text(root, "kind"), root.GetProperty("data").Clone());
    }

    public static void Exact(JsonElement value, params string[] names)
    {
        if (value.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Object required.");
        var properties = value.EnumerateObject().Select(p => p.Name).ToArray();
        if (properties.Length != names.Length || properties.Distinct(StringComparer.Ordinal).Count() != properties.Length || properties.Except(names, StringComparer.Ordinal).Any())
            throw new InvalidDataException("Unexpected, missing or duplicate field.");
    }

    private static void RejectDuplicates(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in value.EnumerateObject())
            {
                if (!names.Add(property.Name)) throw new InvalidDataException("Duplicate property.");
                RejectDuplicates(property.Value);
            }
        }
        else if (value.ValueKind == JsonValueKind.Array)
            foreach (var item in value.EnumerateArray()) RejectDuplicates(item);
    }

    public static int Integer(JsonElement data, string name) => data.GetProperty(name) is { ValueKind: JsonValueKind.Number } value && value.TryGetInt32(out var result)
        ? result : throw new InvalidDataException("Exact bounded integer required.");
    public static string Text(JsonElement data, string name) => data.GetProperty(name) is { ValueKind: JsonValueKind.String } value
        ? value.GetString()! : throw new InvalidDataException("String required.");
    public static string Digest(JsonElement data, string name)
    {
        var value = Text(data, name);
        return Regex.IsMatch(value, "\\A[0-9a-f]{64}\\z", RegexOptions.CultureInvariant) ? value : throw new InvalidDataException("Invalid digest.");
    }
}

public sealed class Transcript : IDisposable
{
    private readonly FrozenRequest _request;
    private readonly MemoryStream _result = new();
    private readonly IncrementalHash _hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    private int _sequence, _frames, _chunkIndex, _lastCollected, _declared;
    private string? _digest;
    private string _state = "new";
    public bool IsComplete => _state == "complete"; // Transcript completeness only, never peer authentication.
    public bool IsFailed => _state == "failed";
    public bool IsCancelled => _state == "cancelled";
    public Transcript(FrozenRequest request) => _request = request;

    public void ReadNext(Stream stream)
    {
        try { Accept(Wire.Read(stream)); }
        catch { _state = "failed"; throw; }
    }

    public void Accept(Frame frame)
    {
        try { AcceptCore(frame); }
        catch { _state = "failed"; throw; }
    }
    private void AcceptCore(Frame frame)
    {
        if (_state is "complete" or "failed" or "cancelled" or "error" || ++_frames > 4096 || frame.Session != _request.Session || frame.Sequence != _sequence)
            throw new InvalidDataException("Terminal, replayed or out-of-order frame.");
        var data = frame.Data;
        switch (frame.Kind)
        {
            case "hello":
                Wire.Exact(data, "operation", "epoch", "requestHash");
                if (_state != "new" || Wire.Text(data, "operation") != _request.Operation || Wire.Integer(data, "epoch") != 1 || Wire.Digest(data, "requestHash") != _request.ScopeHash)
                    throw new InvalidDataException("Scope mismatch.");
                _state = "ready";
                break;
            case "progress":
                Wire.Exact(data, "collected", "expected");
                var collected = Wire.Integer(data, "collected");
                var expected = (_request.Duration + _request.Interval - 1) / _request.Interval;
                if (_state != "ready" || Wire.Integer(data, "expected") != expected || collected < _lastCollected || collected > expected)
                    throw new InvalidDataException("Invalid progress.");
                _lastCollected = collected;
                break;
            case "result-begin":
                Wire.Exact(data, "bytes", "sha256");
                _declared = Wire.Integer(data, "bytes");
                if (_state != "ready" || _declared < 2 || _declared > Wire.MaxResultBytes || _declared > Wire.MaxTokenResultBytes)
                    throw new InvalidDataException("Invalid operation-specific result budget.");
                _digest = Wire.Digest(data, "sha256");
                _state = "result";
                break;
            case "result-chunk":
                Wire.Exact(data, "index", "base64");
                if (_state != "result" || Wire.Integer(data, "index") != _chunkIndex) throw new InvalidDataException("Invalid chunk order.");
                var encoded = Wire.Text(data, "base64");
                if (encoded.Length > 43692) throw new InvalidDataException("Encoded chunk too large.");
                byte[] bytes;
                try { bytes = Convert.FromBase64String(encoded); }
                catch (FormatException error) { throw new InvalidDataException("Invalid base64.", error); }
                if (bytes.Length is < 1 or > Wire.MaxChunkBytes || Convert.ToBase64String(bytes) != encoded || _result.Length + bytes.Length > _declared)
                    throw new InvalidDataException("Chunk exceeds budget or is noncanonical.");
                _hash.AppendData(bytes); _result.Write(bytes); _chunkIndex++;
                break;
            case "complete":
                Wire.Exact(data, "bytes", "sha256");
                if (_state != "result" || Wire.Integer(data, "bytes") != _declared || _result.Length != _declared || Wire.Digest(data, "sha256") != _digest || Convert.ToHexStringLower(_hash.GetHashAndReset()) != _digest)
                    throw new InvalidDataException("Incomplete or corrupt result.");
                ValidateTokenResult(_result.ToArray());
                _state = "complete";
                break;
            case "cancelled":
                Wire.Exact(data, "code");
                if (_state == "new" || Wire.Text(data, "code") != "Cancelled") throw new InvalidDataException("Invalid cancellation.");
                _result.SetLength(0); _state = "cancelled";
                break;
            case "error":
                Wire.Exact(data, "code");
                if (_state == "new" || !new[] { "Unsupported", "TrustFailure", "PolicyBlocked", "ResourceLimit", "Timeout", "ProviderFailure" }.Contains(Wire.Text(data, "code")))
                    throw new InvalidDataException("Invalid error.");
                _result.SetLength(0); _state = "error";
                break;
            default: throw new InvalidDataException("Unsupported message kind.");
        }
        _sequence++;
    }

    private static void ValidateTokenResult(byte[] bytes)
    {
        _ = Wire.StrictUtf8.GetString(bytes);
        using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 8 });
        var root = document.RootElement;
        Wire.Exact(root, "available", "isElevated", "integrityRid");
        if (root.GetProperty("available").ValueKind is not (JsonValueKind.True or JsonValueKind.False)) throw new InvalidDataException("Boolean required.");
        var available = root.GetProperty("available").GetBoolean();
        if (!available)
        {
            if (root.GetProperty("isElevated").ValueKind != JsonValueKind.Null || root.GetProperty("integrityRid").ValueKind != JsonValueKind.Null)
                throw new InvalidDataException("Unavailable token facts must remain null.");
        }
        else if (root.GetProperty("isElevated").ValueKind is not (JsonValueKind.True or JsonValueKind.False) || Wire.Integer(root, "integrityRid") < 0)
            throw new InvalidDataException("Invalid token facts.");
    }
    public void Dispose() { _hash.Dispose(); _result.Dispose(); }
}
