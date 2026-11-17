using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace WPBD.Core;

public sealed record DiagnosticOptions(int DurationSeconds, int IntervalSeconds, string OutputDirectory, bool AllowProcessPolicyOverride)
{
    public static IReadOnlyList<int> Durations { get; } = Array.AsReadOnly(new[] { 30, 60, 120, 300 });
    public static IReadOnlyList<int> Intervals { get; } = Array.AsReadOnly(new[] { 1, 2, 5, 10 });

    public DiagnosticOptions Validate()
    {
        if (!Durations.Contains(DurationSeconds) || !Intervals.Contains(IntervalSeconds) || IntervalSeconds > DurationSeconds)
            throw new ArgumentException("Select a supported diagnostic duration and sampling interval.");
        if (string.IsNullOrWhiteSpace(OutputDirectory) || !Path.IsPathFullyQualified(OutputDirectory))
            throw new ArgumentException("Choose an absolute report folder path.");
        var directory = Path.GetFullPath(OutputDirectory);
        if (File.Exists(directory))
            throw new ArgumentException("The report location refers to a file. Choose a folder.");
        return this with { OutputDirectory = directory };
    }
}

public sealed record DiskReading(string Name, double? Active, double? ReadLatency, double? WriteLatency);

public sealed record Sample(int Slot, DateTimeOffset Timestamp, double ElapsedSeconds,
    double? CpuPercent, double? MemoryPercent, double? AvailableBytes, IReadOnlyList<DiskReading> Disks)
{
    public double? PeakDiskActivity => Disks.Select(disk => disk.Active).Max();
    public double? PeakDiskLatency => Disks.SelectMany(disk => new[] { disk.ReadLatency, disk.WriteLatency }).Max();
}

public sealed record Finding(string Title, string Level, string Confidence, string Observed, string Interpretation,
    string Investigation, string Evidence);

public sealed record ProcessReading(string Name, int Pid, string? StartUtc, double? AverageCpuPercent,
    double? PeakCpuPercent, double? CpuSeconds, double? PrivateMiB, double? WorkingSetMiB, string? Path);

public sealed record SamplingQuality(int Expected, int Actual, int ValidCpu, int Missed, double DurationSeconds,
    IReadOnlyList<string> Errors, double? AverageWorkSeconds, double? PeakWorkSeconds);

public sealed record DiagnosticReport(string Schema, string Computer, DateTimeOffset Started, string Assessment,
    bool Incomplete, IReadOnlyList<string> CoverageGaps, IReadOnlyList<Sample> Samples, IReadOnlyList<Finding> Findings,
    IReadOnlyList<ProcessReading> Processes, SamplingQuality Quality, string JsonPath, string? HtmlPath);

public sealed record EngineProgress(string Phase, Sample? Sample = null, int Collected = 0, int Expected = 0);

public sealed record ReportFiles(string JsonPath, string HtmlPath);

public sealed record EngineEvent(string Type, EngineProgress? Progress = null, ReportFiles? Files = null,
    string? Error = null, string? Details = null);

public static class DiagnosticData
{
    public static async Task<DiagnosticReport> LoadAsync(string path, CancellationToken cancellationToken = default)
    {
        path = Path.GetFullPath(path);
        if (!Path.GetExtension(path).Equals(".json", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Choose a WPBD JSON report.");
        await using var stream = File.OpenRead(path);
        using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken).ConfigureAwait(false);
        var root = document.RootElement;
        var schema = RequiredText(root, "SchemaVersion");
        if (schema is not ("0.1" or "0.2"))
            throw new InvalidDataException($"WPBD report schema {schema} is unsupported. Use a schema 0.1 or 0.2 report.");

        var assessment = root.Field("Assessment");
        var category = RequiredText(assessment, "Category");
        var gaps = assessment.Field("CoverageGaps").Items().Select(item => item.GetString() ?? "").ToArray();
        var samples = RequiredArray(root, "Samples").Select(ParseSample).ToArray();
        var findings = RequiredArray(root, "Findings").Select(item => ParseFinding(item, false))
            .Concat(root.Field("Advisories").Items().Select(item => ParseFinding(item, true))).ToArray();
        var errors = root.Field("CollectionErrors").Items()
            .Select(error => $"{error.Text("Source")} · {error.Text("Code")} · {error.Int("Count") ?? 1} occurrence(s)\n{error.Text("Message")}")
            .ToArray();
        var quality = root.Field("SamplingQuality");
        var expected = quality.Int("ExpectedSamples") ?? root.Field("Configuration").Int("ExpectedSamples") ?? samples.Length;
        var actual = quality.Int("ActualSamples") ?? samples.Length;
        var timing = root.Field("CollectionTiming").Field("SampleWorkSeconds");
        var duration = root.Number("ActualDurationSeconds") ?? throw new InvalidDataException("The report is missing its diagnostic duration.");
        if (expected < actual || actual != samples.Length || actual < 0 || duration < 0)
            throw new InvalidDataException("The report's sample counts or duration are inconsistent.");
        var settings = new SamplingQuality(expected, actual,
            quality.Field("ValidSamples").Int("CpuTotal") ?? samples.Count(sample => sample.CpuPercent.HasValue),
            quality.Int("MissedSampleCount") ?? expected - actual, duration, errors, timing.Number("Average"), timing.Number("Maximum"));
        var html = Path.ChangeExtension(path, ".html");
        return new DiagnosticReport(schema, RequiredText(root.Field("System"), "ComputerName"),
            Timestamp(root, "StartedUtc"), RequiredText(assessment, "Summary"),
            category == "Insufficient diagnostic data" || gaps.Length > 0 || actual == 0, gaps, samples, findings,
            ParseProcesses(root.Field("Statistics").Field("Processes").Field("Leaders")), settings, path,
            File.Exists(html) ? html : null);
    }

    public static EngineEvent ParseEvent(string line)
    {
        using var document = JsonDocument.Parse(line);
        var root = document.RootElement;
        if (root.Int("Protocol") != 1)
            throw new InvalidDataException("The bundled engine progress protocol is incompatible.");
        var data = root.Field("Data");
        var type = RequiredText(root, "Type");
        return type switch
        {
            "phase" when data.ValueKind == JsonValueKind.String => new(type, new(data.GetString()!)),
            "sample" => ParseSampleEvent(data),
            "completed" => new(type, Files: new(RequiredText(data, "JsonPath"), RequiredText(data, "HtmlPath"))),
            "cancelled" => new(type),
            "error" => new(type, Error: RequiredText(data, "Message"),
                Details: $"{data.Text("Code")}\n{data.Text("Details")}"),
            _ => throw new InvalidDataException($"Unsupported engine event '{type}'.")
        };
    }

    private static EngineEvent ParseSampleEvent(JsonElement data)
    {
        var sample = ParseSample(data);
        var collected = data.Int("Collected") ?? 0;
        var expected = data.Int("Expected") ?? 0;
        if (collected < 1 || collected > sample.Slot || sample.Slot > expected)
            throw new InvalidDataException("The engine returned invalid progress counts.");
        return new("sample", new("Collecting measurements", sample, collected, expected));
    }

    private static Sample ParseSample(JsonElement data)
    {
        var slot = data.Int("Slot") ?? 0;
        var elapsed = data.Number("ElapsedSeconds") ?? -1;
        if (slot < 1 || elapsed < 0)
            throw new InvalidDataException("A sample is missing its slot or elapsed time.");
        var memory = data.Field("Memory");
        var disks = data.Field("Disks").Items().Select(item => new DiskReading(RequiredText(item, "Name"),
            item.Number("ActivePercent"), item.Number("ReadLatencyMs"), item.Number("WriteLatencyMs"))).ToArray();
        return new Sample(slot, Timestamp(data, "TimestampUtc"), elapsed, data.Number("CpuTotalPercent"),
            memory.Number("UsedPercent"), memory.Number("AvailableBytes"), disks);
    }

    private static Finding ParseFinding(JsonElement item, bool advisory)
    {
        var category = RequiredText(item, "Category");
        return new Finding(item.Text("Classification") ?? category,
            advisory ? "Advisory" : category == "Insufficient diagnostic data" ? "Coverage gap" : item.Text("Severity") ?? "Information",
            item.Text("Confidence") ?? "Unavailable", RequiredText(item, "Observed"), RequiredText(item, "Explanation"),
            RequiredText(item, "SuggestedInvestigation"), FormatEvidence(item.Field("Measurements"), 0));
    }

    private static string FormatEvidence(JsonElement measurements, int depth)
    {
        if (measurements.ValueKind != JsonValueKind.Object)
            return "";
        var lines = new List<string>();
        foreach (var entry in measurements.EnumerateObject())
        {
            var name = Regex.Replace(entry.Name, "(?<=[a-z])(?=[A-Z])", " ");
            var value = entry.Value;
            if (value.ValueKind is JsonValueKind.String or JsonValueKind.Number)
                lines.Add($"{name}  {FormatValue(value, entry.Name)}");
            else if (value.ValueKind == JsonValueKind.Object && value.Int("Count") is int count)
            {
                var numbers = new[] { "Average", "Minimum", "Maximum" }.Where(key => value.Number(key).HasValue)
                    .Select(key => $"{key.ToLowerInvariant()} {FormatValue(value.Field(key), entry.Name)}");
                var summary = string.Join(", ", numbers);
                lines.Add(summary.Length == 0 ? $"{name}  {count} usable sample(s)" : $"{name}  {summary} ({count} samples)");
            }
            else if (depth == 0 && value.ValueKind == JsonValueKind.Object)
            {
                var summary = FormatEvidence(value, depth + 1);
                if (summary.Length > 0) lines.Add($"{name}\n{summary}");
            }
        }
        return string.Join("\n", lines);
    }

    private static string FormatValue(JsonElement value, string key)
    {
        if (!value.TryNumber(out var number)) return value.GetString() ?? "";
        if (key.EndsWith("Bytes", StringComparison.Ordinal)) return $"{number / 1048576:N1} MiB";
        if (key.EndsWith("Percent", StringComparison.Ordinal)) return $"{number:N1}%";
        if (key.EndsWith("Ms", StringComparison.Ordinal)) return $"{number:N2} ms";
        return $"{number:0.##}";
    }

    private static IReadOnlyList<ProcessReading> ParseProcesses(JsonElement leaders)
    {
        if (leaders.ValueKind != JsonValueKind.Object) return [];
        var readings = new HashSet<ProcessReading>();
        foreach (var ranking in leaders.EnumerateObject())
        foreach (var item in ranking.Value.Items())
        {
            var pid = item.Int("Id");
            if (pid is null or < 1) continue;
            readings.Add(new ProcessReading(item.Text("Name") ?? "Unavailable", pid.Value, item.Text("StartUtc"),
                item.Number("AverageCpuPercent"), item.Number("PeakCpuPercent"), item.Number("CumulativeCpuSeconds"),
                item.Number("PeakPrivateBytes") / 1048576, item.Number("PeakWorkingSetBytes") / 1048576, item.Text("Path")));
        }
        return readings.OrderByDescending(item => item.AverageCpuPercent).ThenBy(item => item.Name).ThenBy(item => item.Pid).ToArray();
    }

    private static string RequiredText(JsonElement source, string key) =>
        source.Text(key) is { Length: > 0 } value ? value : throw new InvalidDataException($"Missing report or event field '{key}'.");

    private static DateTimeOffset Timestamp(JsonElement source, string key) =>
        DateTimeOffset.TryParse(RequiredText(source, key), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var value)
            ? value : throw new InvalidDataException($"Invalid timestamp in '{key}'.");

    private static IEnumerable<JsonElement> RequiredArray(JsonElement source, string key) =>
        source.Field(key) is { ValueKind: JsonValueKind.Array } value
            ? value.EnumerateArray() : throw new InvalidDataException($"Missing report array '{key}'.");

    private static JsonElement Field(this JsonElement source, string key) =>
        source.ValueKind == JsonValueKind.Object && source.TryGetProperty(key, out var value) ? value : default;
    private static string? Text(this JsonElement source, string key) =>
        source.Field(key) is { ValueKind: JsonValueKind.String } value ? value.GetString() : null;
    private static int? Int(this JsonElement source, string key) =>
        source.Field(key) is { ValueKind: JsonValueKind.Number } value && value.TryGetInt32(out var number) ? number : null;
    private static double? Number(this JsonElement source, string key) =>
        source.Field(key).TryNumber(out var number) ? number : null;
    private static bool TryNumber(this JsonElement value, out double number)
    {
        number = 0;
        return value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out number) && double.IsFinite(number);
    }
    private static IEnumerable<JsonElement> Items(this JsonElement value) =>
        value.ValueKind == JsonValueKind.Array ? value.EnumerateArray() : [];
}
