using System.Runtime.Versioning;
using System.Text.Json;
using System.Text.Json.Nodes;
using WPBD.Core;

var temporary = Directory.CreateTempSubdirectory("wpbd-tests-").FullName;
var valid = Path.Combine(temporary, "WPBD-test.json");
var tests = new (string Name, Func<Task> Run)[]
{
    ("0.6 insights preserve structured evidence, nulls and historical absence", async () =>
    {
        var document = JsonNode.Parse(Fixture("0.3"))!;
        document["DiagnosticInsights"] = new JsonArray(new JsonObject {
            ["Id"] = "cpu.sustained", ["Title"] = "Sustained CPU", ["Category"] = "CPU bottleneck",
            ["Priority"] = "Medium", ["Severity"] = "Warning", ["Confidence"] = "High",
            ["Observation"] = "3 of 5 samples", ["DetailText"] = "Recorded details <escaped>",
            ["PotentialContributors"] = new JsonArray(), ["SupportingEvidence"] = new JsonObject { ["Missing"] = null },
            ["SampleSlots"] = new JsonArray(1, 2, 3), ["MeasurementReferences"] = new JsonArray("Statistics.Cpu") });
        await File.WriteAllTextAsync(valid, document.ToJsonString());
        var report = await DiagnosticData.LoadAsync(valid);
        var insight = report.Insights!.Single();
        Check(insight is { Id: "cpu.sustained", Priority: "Medium", Severity: "Warning", Confidence: "High",
            DetailText: "Recorded details <escaped>" }, "Insight presentation changed.");
        Check(insight.Evidence.GetProperty("SupportingEvidence").GetProperty("Missing").ValueKind == JsonValueKind.Null &&
            insight.Evidence.GetProperty("SampleSlots").GetArrayLength() == 3, "Structured evidence did not survive document disposal.");
        foreach (var schema in new[] { "0.1", "0.2", "0.3" }) {
            await File.WriteAllTextAsync(valid, Fixture(schema));
            Check((await DiagnosticData.LoadAsync(valid)).Insights!.Count == 0, "Historical insights were invented.");
        }
    }),
    ("0.5.1 optional attribution evidence and service-only coverage round trip", async () =>
    {
        var document = JsonNode.Parse(Fixture("0.3"))!;
        document["Statistics"]!["Processes"]!["All"] = new JsonArray(new JsonObject {
            ["Id"] = 55, ["Name"] = "agent", ["InstanceKey"] = "provisional/55/1",
            ["IdentityStatus"] = "Provisional", ["AttributionCategory"] = "Identified service process",
            ["MetadataIdentityMatch"] = "BracketedInventories", ["ImagePathSource"] = "LimitedInformation",
            ["AttributionReasons"] = new JsonArray("AccessDenied", "PathUnavailable"),
            ["Services"] = new JsonArray("ServiceA", "ServiceB") });
        document["AttributionQuality"] = new JsonObject { ["UniqueIdentities"] = 1,
            ["IdentifiedServices"] = 1, ["AttributedPercent"] = 100, ["ApplicationAndWindowsPercent"] = 0 };
        await File.WriteAllTextAsync(valid, document.ToJsonString());
        var report = await DiagnosticData.LoadAsync(valid);
        Check(report.Processes.Single() is { MetadataIdentityMatch: "BracketedInventories", ImagePathSource: "LimitedInformation" }
            && report.Processes.Single().AttributionReasons!.Contains("AccessDenied"), "Enrichment evidence was lost.");
        Check(report.Attribution is { IdentifiedServices: 1, AttributedPercent: 100, ApplicationAndWindowsPercent: 0 },
            "Service-only evidence was confused with application ownership.");
        await File.WriteAllTextAsync(valid, Fixture("0.3"));
        var historical = await DiagnosticData.LoadAsync(valid);
        Check(historical.Processes.All(p => p.AttributionReasons is null && p.MetadataIdentityMatch == "Unavailable"),
            "Missing historical evidence was fabricated.");
    }),
    ("schema 0.3 preserves provisional identity, access, service and application quality fields", async () =>
    {
        var document = JsonNode.Parse(Fixture("0.3"))!;
        var process = new JsonObject { ["Id"] = 55, ["Name"] = "restricted", ["InstanceKey"] = "provisional/55/1",
            ["IdentityStatus"] = "Provisional", ["AttributionCategory"] = "Protected or restricted process",
            ["MetadataAccess"] = "Restricted", ["AttributionConfidence"] = "Low", ["ParentId"] = 5,
            ["Observations"] = 15, ["Services"] = new JsonArray("ExampleService"), ["PeakPrivateBytes"] = 1048576 };
        document["Statistics"]!["Processes"]!["All"] = new JsonArray(process.DeepClone());
        document["AttributionQuality"] = new JsonObject {
            ["UniqueIdentities"] = 1, ["UniquePids"] = 1, ["VerifiedIdentities"] = 0, ["ProvisionalIdentities"] = 1,
            ["RestrictedProcesses"] = 1, ["RestrictedOwnership"] = 1, ["Observations"] = 15,
            ["ConcurrentProcesses"] = new JsonObject { ["Maximum"] = 1 },
            ["AttributedPercent"] = 0, ["UnattributedPrivateBytes"] = new JsonObject { ["Maximum"] = 1048576 } };
        document["Applications"] = new JsonArray(new JsonObject {
            ["Name"] = "Protected or restricted process", ["Key"] = "category/restricted",
            ["AttributionCategory"] = "Protected or restricted process", ["AttributionConfidence"] = "Low",
            ["UniqueIdentities"] = 1, ["Observations"] = 15,
            ["ConcurrentProcesses"] = new JsonObject { ["Maximum"] = 1 },
            ["CpuPercent"] = new JsonObject { ["Count"] = 0 },
            ["Processes"] = new JsonArray(process.DeepClone()) });
        var path = Path.Combine(temporary, "WPBD-quality.json");
        await File.WriteAllTextAsync(path, document.ToJsonString());
        var report = await DiagnosticData.LoadAsync(path);
        Check(report.Processes.Single() is { IdentityStatus: "Provisional", MetadataAccess: "Restricted",
            ParentPid: 5, Services: "ExampleService", Observations: 15, AverageCpuPercent: null },
            "Process identity and access metadata were lost.");
        Check(report.Attribution is { UniqueIdentities: 1, Provisional: 1, Observations: 15, PeakConcurrent: 1,
            AttributedPercent: 0, UnattributedPrivateMiB: 1, RestrictedOwnership: 1 }, "Attribution quality was lost.");
        Check(report.Applications!.Single() is { UniqueIdentities: 1, Observations: 15, PeakConcurrent: 1,
            AverageCpu: null, Confidence: "Low" }, "Application counts or missing CPU were confused.");
    }),
    ("legacy raw samples expose processes omitted from top-ten rankings", async () =>
    {
        var document = JsonNode.Parse(Fixture("0.2"))!;
        var samples = document["Samples"]!.AsArray();
        var processes = new JsonArray();
        for (var pid = 1; pid <= 43; pid++)
            processes.Add(new JsonObject { ["Id"] = pid, ["Name"] = pid <= 2 ? "ms-teams" : "msedgewebview2",
                ["StartUtc"] = "2026-01-02T00:00:00Z", ["PrivateBytes"] = 1048576, ["WorkingSetBytes"] = 2097152 });
        samples[0]!["Processes"] = processes;
        var path = Path.Combine(temporary, "WPBD-all-legacy.json");
        await File.WriteAllTextAsync(path, document.ToJsonString());
        var report = await DiagnosticData.LoadAsync(path);
        Check(report.Processes.Count == 43 && report.Processes.Count(row => row.Name == "ms-teams") == 2,
            "Captured processes were lost outside leader rankings.");
        Check(report.Processes.All(row => row.Application == "Unattributed"), "Legacy ownership was guessed.");
        Check(report.Attribution is null && report.Processes.All(row => row.AttributionCategory == "Legacy attribution unavailable"),
            "Historical processes were reclassified using metadata that was not recorded.");
    }),
    ("new all-process and application fields preserve membership and complete-sample counts", async () =>
    {
        var document = JsonNode.Parse(Fixture("0.2"))!;
        var process = new JsonObject { ["Id"] = 123, ["Name"] = "ms-teams", ["StartUtc"] = "2026-01-02T00:00:00Z",
            ["Application"] = "Microsoft Teams", ["OwnershipEvidence"] = "Executable path", ["PeakPrivateBytes"] = 1048576 };
        document["Statistics"]!["Processes"]!["All"] = new JsonArray(process.DeepClone());
        document["Applications"] = new JsonArray(new JsonObject {
            ["Name"] = "Microsoft Teams", ["Key"] = "verified-path", ["Processes"] = new JsonArray(process.DeepClone()),
            ["PrivateBytes"] = new JsonObject { ["Maximum"] = 2097152, ["Count"] = 1 },
            ["WorkingSetBytes"] = new JsonObject { ["Count"] = 0 } });
        var path = Path.Combine(temporary, "WPBD-applications.json");
        await File.WriteAllTextAsync(path, document.ToJsonString());
        var report = await DiagnosticData.LoadAsync(path);
        Check(report.Processes.Single().Pid == 123 && report.Processes.Single().Application == "Microsoft Teams",
            "New all-process field was ignored.");
        Check(report.Applications!.Single() is { PrivateMiB: 2, WorkingSetMiB: null, PrivateSamples: 1, WorkingSetSamples: 0 } app &&
            app.Processes.Single().Pid == 123, "Application coverage or membership was lost.");
    }),
    ("configuration accepts the supported choices", () =>
    {
        var options = new DiagnosticOptions(60, 2, temporary, false).Validate();
        Check(options.DurationSeconds == 60 && options.IntervalSeconds == 2, "Unexpected validated options.");
        return Task.CompletedTask;
    }),
    ("configuration rejects invalid duration, interval and relative paths", () =>
    {
        Throws<ArgumentException>(() => new DiagnosticOptions(33, 2, temporary, false).Validate());
        Throws<ArgumentException>(() => new DiagnosticOptions(60, 0, temporary, false).Validate());
        Throws<ArgumentException>(() => new DiagnosticOptions(60, 2, "relative", false).Validate());
        return Task.CompletedTask;
    }),
    ("report preserves assessment, advisories, evidence, zeroes and missing measurements", async () =>
    {
        await File.WriteAllTextAsync(valid, Fixture("0.2"));
        var report = await DiagnosticData.LoadAsync(valid);
        Check(report.Schema == "0.2" && report.Computer == "TEST", "Report identity was lost.");
        Check(report.Findings.Any(item => item.Level == "Advisory" && item.Title == "Elevated memory utilisation" &&
            item.Evidence.Contains("Available Percent", StringComparison.Ordinal)), "Advisory mapping or evidence is missing.");
        Check(report.Findings.Any(item => item.Level == "Critical" && item.Title == "Severe memory pressure"), "Pressure tier was lost.");
        Check(report.Samples.Single().CpuPercent == 0 && report.Samples.Single().MemoryPercent is null &&
              report.Samples.Single().PeakDiskLatency is null, "Missing readings were confused with measured zeroes.");
        Check(report.Processes.Count == 1 && report.Processes[0].PrivateMiB == 1 && report.Processes[0].Path is null,
            "Process ranking or missing data was parsed incorrectly.");
        Check(report.Quality.Expected == 2 && report.Quality.Missed == 1 && report.Quality.ValidCpu == 1, "Sampling quality was lost.");
    }),
    ("legacy schema 0.1 derives sample coverage from the report", async () =>
    {
        var path = Path.Combine(temporary, "WPBD-legacy.json");
        const string quality = """
            "SamplingQuality":{"ExpectedSamples":2,"ActualSamples":1,"MissedSampleCount":1,"ValidSamples":{"CpuTotal":1}},
            """;
        await File.WriteAllTextAsync(path, Fixture("0.1").Replace(quality, ""));
        var report = await DiagnosticData.LoadAsync(path);
        Check(report.Schema == "0.1" && report.Quality.Missed == 1 && report.Quality.ValidCpu == 1, "Legacy coverage failed.");
    }),
    ("unsupported, truncated and incomplete reports are handled explicitly", async () =>
    {
        var bad = Path.Combine(temporary, "WPBD-bad.json");
        await File.WriteAllTextAsync(bad, Fixture("3.4"));
        await ThrowsAsync<InvalidDataException>(() => DiagnosticData.LoadAsync(bad));
        await File.WriteAllTextAsync(bad, "{");
        await ThrowsAsync<JsonException>(() => DiagnosticData.LoadAsync(bad));
        await File.WriteAllTextAsync(bad, Fixture("0.2").Replace("No clear bottleneck detected", "Insufficient diagnostic data"));
        Check((await DiagnosticData.LoadAsync(bad)).Incomplete, "A report with insufficient evidence appeared complete.");
    }),
    ("event parsing preserves slot, progress, timestamp and genuine storage readings", () =>
    {
        var message = DiagnosticData.ParseEvent("""
            {"Protocol":1,"Type":"sample","Data":{"Slot":3,"Collected":2,"Expected":15,"TimestampUtc":"2026-01-02T00:00:03Z","ElapsedSeconds":3.2,
            "CpuTotalPercent":null,"Memory":{"UsedPercent":85.6,"AvailableBytes":1073741824},
            "Disks":[{"Name":"Disk 0","ActivePercent":0,"ReadLatencyMs":1.2,"WriteLatencyMs":null}]}}
            """);
        Check(message.Progress is { Expected: 15, Collected: 2, Sample: { Slot: 3 } sample } &&
            sample.CpuPercent is null && sample.PeakDiskActivity == 0 && sample.PeakDiskLatency == 1.2 &&
            sample.Timestamp.Second == 3 && sample.ElapsedSeconds == 3.2, "Sample event mismatch.");
        return Task.CompletedTask;
    }),
    ("protocol rejects incompatible and impossible events and preserves error details", () =>
    {
        Throws<InvalidDataException>(() => DiagnosticData.ParseEvent("""{"Protocol":9,"Type":"phase","Data":"Preparing baseline"}"""));
        Throws<InvalidDataException>(() => DiagnosticData.ParseEvent("""
            {"Protocol":1,"Type":"sample","Data":{"Slot":2,"Collected":3,"Expected":1,"ElapsedSeconds":2,"TimestampUtc":"2026-01-02T00:00:03Z"}}
            """));
        var error = DiagnosticData.ParseEvent("""{"Protocol":1,"Type":"error","Data":{"Message":"Access is denied","Code":"PermissionDenied","Details":"Export"}}""");
        Check(error.Error == "Access is denied" && error.Details!.Contains("PermissionDenied"), "Worker error details are missing.");
        Check(DiagnosticData.ParseEvent("""{"Protocol":1,"Type":"cancelled","Data":"Diagnostic cancelled"}""").Type == "cancelled",
            "Cancellation event is missing.");
        return Task.CompletedTask;
    }),
    ("history uses filesystem reports and resolves only adjacent HTML", async () =>
    {
        await File.WriteAllTextAsync(Path.Combine(temporary, "other.json"), "{}");
        Check(ReportPaths.History(temporary).Any(entry => entry.Path == valid) &&
            ReportPaths.History(temporary).All(entry => entry.FileName.StartsWith("WPBD-")), "History indexed unrelated files.");
        Check((await DiagnosticData.LoadAsync(valid)).HtmlPath is null, "Missing companion HTML was treated as present.");
        var html = Path.ChangeExtension(valid, ".html");
        await File.WriteAllTextAsync(html, "<!doctype html><title>test document</title>");
        Check((await DiagnosticData.LoadAsync(valid)).HtmlPath == html, "Adjacent HTML was not found.");
        Throws<InvalidDataException>(() => ReportPaths.ExistingFile(valid, ".html"));
        Throws<FileNotFoundException>(() => ReportPaths.ExistingFile(Path.Combine(temporary, "missing.html"), ".html"));
    })
};

foreach (var test in tests)
{
    await test.Run();
    Console.WriteLine($"PASS {test.Name}");
}
Console.WriteLine($"{tests.Length} .NET checks passed.");

if (OperatingSystem.IsWindows())
{
    await MissingEngineAsync(temporary);
    Console.WriteLine("PASS missing Windows engine files");
    if (args.Length is 2 or 3 && args[0] == "--live")
        await LiveAsync(Path.GetFullPath(args[1]), temporary, args.Length == 3 && args[2] == "--allow-process-policy-override");
}

[SupportedOSPlatform("windows")]
static async Task MissingEngineAsync(string directory)
{
    var attempt = new EngineRunner(directory).RunAsync(
        new DiagnosticOptions(30, 2, directory, false), new InlineProgress(_ => { }), CancellationToken.None);
    await ThrowsAsync<EngineException>(() => attempt);
}

[SupportedOSPlatform("windows")]
static async Task LiveAsync(string engine, string directory, bool overridePolicy)
{
    var runner = new EngineRunner(engine);
    var options = new DiagnosticOptions(30, 2, Path.Combine(directory, "reports [with spaces]"), overridePolicy);
    var events = new List<EngineProgress>();
    using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(100));
    var report = await runner.RunAsync(options, new InlineProgress(events.Add), deadline.Token);
    var liveSamples = events.Where(item => item.Sample is not null).Select(item => item.Sample!).ToArray();
    Check(liveSamples.Length == report.Samples.Count && liveSamples.Length > 0 &&
        liveSamples.Zip(report.Samples).All(pair => pair.First.Slot == pair.Second.Slot &&
            pair.First.Timestamp == pair.Second.Timestamp && pair.First.CpuPercent == pair.Second.CpuPercent &&
            pair.First.MemoryPercent == pair.Second.MemoryPercent), "Live events differed from the written report.");
    Check(report.Quality.ValidCpu > 0 && report.Samples.Any(sample => sample.AvailableBytes.HasValue) &&
        File.Exists(report.JsonPath) && File.Exists(report.HtmlPath), "The live run did not produce real data and a report pair.");
    Check(report.Schema == "0.3" && report.Attribution is { } attribution &&
        attribution.UniqueIdentities == report.Processes.Count &&
        report.Processes.Select(process => process.InstanceKey).Distinct().Count() == report.Processes.Count &&
        report.Applications!.Sum(application => application.Processes.Count) == report.Processes.Count,
        "Live process identity or application membership counts were inconsistent.");
    Check(report.Insights is { Count: > 0 }, "Live report omitted diagnostic insights.");
    using (var written = JsonDocument.Parse(await File.ReadAllTextAsync(report.JsonPath))) {
        var html = await File.ReadAllTextAsync(report.HtmlPath!);
        foreach (var insight in report.Insights!)
            Check(html.Contains(System.Net.WebUtility.HtmlEncode(insight.DetailText)), "Live HTML and desktop insight text differ.");
        Console.WriteLine($"LIVE timing: sample average {written.RootElement.GetProperty("CollectionTiming").GetProperty("SampleWorkSeconds").GetProperty("Average")}; insight seconds {written.RootElement.GetProperty("CollectionTiming").GetProperty("InsightAnalysisSeconds")}");
    }
    Console.WriteLine($"PASS real Windows collection and paired reports ({report.Quality.Actual}/{report.Quality.Expected} samples)");

    using var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(30));
    var partialDirectory = Path.Combine(directory, "cancelled");
    var sawSample = false;
    var attempt = runner.RunAsync(options with { OutputDirectory = partialDirectory },
        new InlineProgress(update =>
        {
            if (update.Sample is null) return;
            sawSample = true;
            cancel.Cancel();
        }), cancel.Token);
    await ThrowsAsync<OperationCanceledException>(() => attempt);
    Check(sawSample && !Directory.Exists(partialDirectory), "Cancellation did not stop a live run before report export.");
    Console.WriteLine("PASS cancellation after a real sample, with no partial reports exported");
}

static string Fixture(string schema) => """
    {
      "SchemaVersion":"SCHEMA","System":{"ComputerName":"TEST"},
      "StartedUtc":"2026-01-02T00:00:00Z","ActualDurationSeconds":4.1,
      "Configuration":{"ExpectedSamples":2},
      "SamplingQuality":{"ExpectedSamples":2,"ActualSamples":1,"MissedSampleCount":1,"ValidSamples":{"CpuTotal":1}},
      "Assessment":{"Category":"No clear bottleneck detected","Summary":"No clear bottleneck detected.","CoverageGaps":[]},
      "Samples":[{"Slot":2,"TimestampUtc":"2026-01-02T00:00:04Z","ElapsedSeconds":4,"CpuTotalPercent":0,
        "Memory":{"UsedPercent":null,"AvailableBytes":0},"Disks":[]}],
      "Findings":[{"Category":"Memory pressure","Classification":"Severe memory pressure","Severity":"Critical","Confidence":"High",
        "Observed":"Observed","Explanation":"Interpretation","SuggestedInvestigation":"Investigate","Measurements":{}}],
      "Advisories":[{"Category":"Elevated memory utilisation","Severity":"Information","Confidence":"Medium","Observed":"Observed",
        "Explanation":"Interpretation","SuggestedInvestigation":"Investigate","Measurements":{"AvailablePercent":{"Count":1,"Average":10}}}],
      "Statistics":{"Processes":{"Leaders":{
        "AverageCpuPercent":[{"Id":21,"Name":"Test","AverageCpuPercent":1.5,"PeakPrivateBytes":1048576}],
        "PeakPrivateBytes":[{"Id":21,"Name":"Test","AverageCpuPercent":1.5,"PeakPrivateBytes":1048576}]}}}
    }
    """.Replace("SCHEMA", schema);

static void Check(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}

static void Throws<T>(Action action) where T : Exception
{
    try { action(); }
    catch (T) { return; }
    throw new InvalidOperationException($"Expected {typeof(T).Name}.");
}

static async Task ThrowsAsync<T>(Func<Task> action) where T : Exception
{
    try { await action(); }
    catch (T) { return; }
    throw new InvalidOperationException($"Expected {typeof(T).Name}.");
}

internal sealed class InlineProgress(Action<EngineProgress> listener) : IProgress<EngineProgress>
{
    public void Report(EngineProgress value) => listener(value);
}
