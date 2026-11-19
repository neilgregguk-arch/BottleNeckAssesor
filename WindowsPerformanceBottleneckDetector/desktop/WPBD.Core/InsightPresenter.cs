using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace WPBD.Core;

public sealed record EvidenceDisplay(string Key, string Measurement, string Average, string Minimum, string Maximum, string Coverage);
public sealed record ContributorDisplay(string Name, string Kind, string Usage, string Attribution, string Coverage, string Details);
public sealed record InsightDisplay(string Observation, string Interpretation, IReadOnlyList<EvidenceDisplay> Measurements,
    IReadOnlyList<EvidenceDisplay> TechnicalMeasurements, IReadOnlyList<ContributorDisplay> Contributors,
    IReadOnlyList<ContributorDisplay> AllContributors, IReadOnlyList<string> Steps, IReadOnlyList<string> AllSteps,
    string Limitation, string TechnicalReferences, string Limitations);
public sealed record OverviewDisplay(string Summary, string Focus, string Counts, string Sampling);

// Formatting and grouping only. All resource decisions remain recorded engine results.
public static class InsightPresenter
{
    private static readonly JsonElement Spec = LoadSpec();
    private static JsonElement LoadSpec()
    {
        var assembly = typeof(InsightPresenter).Assembly;
        using var stream = assembly.GetManifestResourceStream(assembly.GetManifestResourceNames().Single(n => n.EndsWith("Presentation-Format.json")))!;
        using var document = JsonDocument.Parse(stream);
        return document.RootElement.Clone();
    }
    internal static IEnumerable<(string Key,string Label,string Unit)> PermissionFields => Get(Spec,"PermissionFields").EnumerateObject().Select(p => (p.Name,Text(p.Value,"Label")!,Text(p.Value,"Unit")!));
    public static string Value(double? value, string unit = "count")
    {
        if (value is not double v || !double.IsFinite(v)) return "Unavailable";
        var format = "0.##"; var suffix = "";
        switch (unit)
        {
            case "bytes":
                if (Math.Abs(v) >= 1073741824) { v /= 1073741824; format = "0.00"; suffix = " GiB"; }
                else { v /= 1048576; format = "0.#"; suffix = " MiB"; }
                break;
            case "bytes/s":
                if (Math.Abs(v) >= 1048576) { v /= 1048576; suffix = " MiB/s"; }
                else { v /= 1024; suffix = " KiB/s"; }
                break;
            case "percent": format = "0.0"; suffix = "%"; break;
            case "ms": format = "0.00"; suffix = " ms"; break;
            case "seconds": suffix = " s"; break;
            case "reads/s": case "pages/s": case "ops/s": suffix = " " + unit; break;
        }
        // .NET Framework and modern .NET have different default midpoint formatting.
        v = Math.Round(v, format is "0.#" or "0.0" ? 1 : 2, MidpointRounding.AwayFromZero);
        return v.ToString(format, CultureInfo.InvariantCulture) + suffix;
    }
    public static IReadOnlyList<EvidenceDisplay> Evidence(JsonElement source, string prefix = "")
    {
        var rows = new List<EvidenceDisplay>();
        if (source.ValueKind != JsonValueKind.Object) return rows;
        foreach (var property in source.EnumerateObject())
        {
            var key = property.Name; var v = property.Value;
            var spec = Get(Get(Spec, "Fields"), key);
            var label = Text(spec, "Label") ?? Regex.Replace(key, "(?<=[a-z])(?=[A-Z])", " ");
            if (prefix.Length > 0) label = prefix + " / " + label;
            var unit = Text(spec, "Unit") ?? (key.EndsWith("Percent") ? "percent" : key.EndsWith("Bytes") ? "bytes" : key.EndsWith("Seconds") ? "seconds" : "count");
            if (v.ValueKind == JsonValueKind.Object && Get(v, "Average").ValueKind != JsonValueKind.Undefined && Get(v, "Count").ValueKind != JsonValueKind.Undefined)
                rows.Add(new(key, label, Value(Number(v, "Average"), unit), Value(Number(v, "Minimum"), unit), Value(Number(v, "Maximum"), unit), $"{Number(v, "Count")} samples"));
            else if (v.ValueKind == JsonValueKind.Object) rows.AddRange(Evidence(v, label));
            else if (v.ValueKind == JsonValueKind.Array)
            {
                var index = 0;
                foreach (var item in v.EnumerateArray())
                {
                    if (item.ValueKind == JsonValueKind.Object) rows.AddRange(Evidence(item, $"{label} {index}"));
                    else rows.Add(new(key, label, Scalar(item, unit), "—", "—", "Recorded"));
                    index++;
                }
            }
            else rows.Add(new(key, label, Scalar(v, unit), "—", "—", "Recorded"));
        }
        return rows;
    }
    public static InsightDisplay Create(JsonElement insight)
    {
        var evidence = Get(insight, "SupportingEvidence");
        var rows = Evidence(evidence);
        var keys = Items(Get(Get(Spec, "PrimaryFields"), Text(insight, "Category") ?? "")).Select(x => x.GetString()).ToArray();
        var primary = keys.Length > 0 ? keys.SelectMany(key => rows.Where(row => row.Key == key)).ToArray() : rows.Take(4).ToArray();
        var observation = Text(insight, "Observation") ?? "";
        if (Text(insight, "Category") is "Memory pressure" or "Elevated memory utilisation")
            observation = $"Average physical memory use was {Value(Number(Get(evidence, "UsedPercent"), "Average"), "percent")}; minimum available RAM was {Value(Number(Get(evidence, "AvailableBytes"), "Minimum"), "bytes")}.";
        var contributors = Items(Get(insight, "PotentialContributors")).Select(Contributor).ToArray();
        var steps = Strings(insight, "SuggestedInvestigation").Select((step, index) => $"{index + 1}. {step}").ToArray();
        var limitations = Strings(insight, "DataLimitations");
        var start = Text(insight, "StartedUtc"); var end = Text(insight, "CompletedUtc");
        var window = start is not null && end is not null ? $"{start} to {end}" : "Unavailable";
        var references = $"Observation window (UTC): {window}\nSample slots: {Join(Get(insight, "SampleSlots"))}\nMeasurement references: {Join(Get(insight, "MeasurementReferences"))}";
        return new(observation, Text(insight, "Interpretation") ?? "", primary, rows, contributors.Take(5).ToArray(), contributors,
            steps.Take(3).ToArray(), steps, limitations.LastOrDefault() ?? "", references, string.Join("\n", limitations));
    }
    private static ContributorDisplay Contributor(JsonElement c)
    {
        var unit = Text(c, "Resource") == "CpuPercent" ? "percent" : "bytes";
        var resource = unit == "percent" ? "CPU" : "private allocation";
        var usage = Get(c, "Usage"); var working = Get(c, "WorkingSetBytes"); var coverage = Get(c, "MeasurementCoverage");
        var key = Text(c, "ApplicationKey");
        var kind = string.IsNullOrEmpty(key) ? "Individual process" : key.StartsWith("service/") || key.StartsWith("windows/") ? "Process group" : "Application group";
        var attribution = !string.IsNullOrEmpty(key) ? $"Ownership evidence: {Text(c, "AttributionConfidence")} confidence" : "Ownership unresolved";
        var measured = $"{Number(coverage, "ValidSamples")} of {Number(coverage, "SelectedSamples")} selected samples";
        var details = new List<string> { $"{kind} — {attribution}. {measured}.", Text(c, "Reason") ?? "",
            $"Application reference: {key ?? "Unavailable"}",
            $"Relevant {resource}: average {Value(Number(usage, "Average"), unit)}; minimum {Value(Number(usage, "Minimum"), unit)}; peak {Value(Number(usage, "Maximum"), unit)}; {Value(Number(usage, "Count"))} measured samples.",
            $"Present in {Value(Number(coverage, "PresentSamples"))} of {Value(Number(coverage, "SelectedSamples"))} selected samples.",
            $"Working set: average {Value(Number(working, "Average"), "bytes")}; minimum {Value(Number(working, "Minimum"), "bytes")}; peak {Value(Number(working, "Maximum"), "bytes")}; {Value(Number(working, "Count"))} measured samples." };
        foreach (var p in Items(Get(c, "ProcessIdentities")))
        {
            details.Add($"{Text(p, "Name")} — PID {Number(p, "Id")}, {Text(p, "IdentityStatus")}; identity: {Text(p, "InstanceKey")}");
            var individual = Get(p, "Usage");
            if (individual.ValueKind == JsonValueKind.Object)
                details.Add($"  Average {Value(Number(individual, "Average"), unit)}; minimum {Value(Number(individual, "Minimum"), unit)}; peak {Value(Number(individual, "Maximum"), unit)}; {Value(Number(individual, "Count"))} measured samples.");
            var resident = Get(p, "WorkingSetBytes");
            if (resident.ValueKind == JsonValueKind.Object)
                details.Add($"  Working set: average {Value(Number(resident, "Average"), "bytes")}; minimum {Value(Number(resident, "Minimum"), "bytes")}; peak {Value(Number(resident, "Maximum"), "bytes")}; {Value(Number(resident, "Count"))} measured samples.");
        }
        details.Add("Measured slots: " + Join(Get(c, "SampleSlots")));
        return new(Text(c, "Name") ?? "Unavailable", kind,
            $"Average {Value(Number(usage, "Average"), unit)}; peak {Value(Number(usage, "Maximum"), unit)} {resource}",
            attribution, measured, string.Join("\n", details));
    }
    public static OverviewDisplay Overview(DiagnosticReport report)
    {
        var significant = report.Findings.Count(f => f.Level is not ("Advisory" or "Coverage gap") && f.Title != "No clear bottleneck detected");
        var advisories = report.Findings.Where(f => f.Level == "Advisory").ToArray();
        var summary = report.Assessment;
        if (advisories.Length > 0) summary += " " + string.Join("; ", advisories.Select(a => a.Title)) + ".";
        var top = report.Insights?.FirstOrDefault(i => i.Id != "operation.normal") ?? report.Insights?.FirstOrDefault();
        var focus = top is null ? "Insight priority and confidence were not recorded."
            : $"Highest-priority insight: {top.Title} — {top.Priority} priority; {top.Confidence} confidence.";
        return new(summary, focus, $"{significant} significant {(significant == 1 ? "finding" : "findings")}; {advisories.Length} {(advisories.Length == 1 ? "advisory" : "advisories")}.",
            $"{report.Quality.Actual} of {report.Quality.Expected} scheduled samples collected; {report.Quality.Missed} missed.");
    }
    public static IReadOnlyList<Finding> UnrepresentedFindings(DiagnosticReport report)
    {
        var represented = (report.Insights ?? []).SelectMany(i => new[] { i.Title, i.Category, Text(i.Evidence, "RelatedFindingCategory") }).ToHashSet();
        return report.Findings.Where(f => !represented.Contains(f.Title)).ToArray();
    }
    public static string Ownership(DiagnosticInsight insight, IReadOnlyList<ProcessReading> processes)
    {
        var identities = Items(Get(insight.Evidence, "PotentialContributors")).SelectMany(c => Items(Get(c, "ProcessIdentities")))
            .Select(p => Text(p, "InstanceKey")).ToHashSet();
        return string.Join("\n\n", processes.Where(p => identities.Contains(p.InstanceKey)).Select(p =>
            $"{p.Name} — PID {p.Pid}\nPath: {p.Path ?? "Unavailable"}\nOwnership evidence: {p.OwnershipEvidence}\nAttribution category: {p.AttributionCategory}; confidence: {p.AttributionConfidence}\nMetadata match: {p.MetadataIdentityMatch}; reason codes: {p.AttributionReasons ?? "Unavailable"}"));
    }
    private static string Scalar(JsonElement value, string unit) => value.ValueKind switch {
        JsonValueKind.Number => Value(value.TryGetDouble(out var v) ? v : null, unit),
        JsonValueKind.String => value.GetString() ?? "Unavailable", JsonValueKind.True => "True", JsonValueKind.False => "False", _ => "Unavailable" };
    private static JsonElement Get(JsonElement source, string key) => source.ValueKind == JsonValueKind.Object && source.TryGetProperty(key, out var value) ? value : default;
    private static string? Text(JsonElement source, string key) => Get(source, key) is { ValueKind: JsonValueKind.String } value ? value.GetString() : null;
    private static double? Number(JsonElement source, string key) => Get(source, key) is { ValueKind: JsonValueKind.Number } value && value.TryGetDouble(out var result) ? result : null;
    private static IEnumerable<JsonElement> Items(JsonElement source) => source.ValueKind == JsonValueKind.Array ? source.EnumerateArray() : [];
    private static string[] Strings(JsonElement source, string key) => Items(Get(source, key)).Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!).Where(x => x.Length > 0).ToArray();
    private static string Join(JsonElement source) => string.Join(", ", Items(source).Select(x => x.ValueKind == JsonValueKind.String ? x.GetString() : x.ToString()));
}
