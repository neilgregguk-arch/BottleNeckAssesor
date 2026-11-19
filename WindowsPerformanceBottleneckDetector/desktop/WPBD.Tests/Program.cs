using System.Runtime.Versioning;
using System.Text.Json;
using System.Text.Json.Nodes;
using WPBD.Core;

var temporary = Directory.CreateTempSubdirectory("wpbd-tests-").FullName;
var valid = Path.Combine(temporary, "WPBD-test.json");
var tests = new (string Name, Func<Task> Run)[]
{
    ("0.6.2 Standard default and unavailable elevated requests fail before engine execution", async () =>
    {
        var options=new DiagnosticOptions(30,2,temporary,false);
        Check(options.Mode==DiagnosticMode.Standard && !ElevationPolicy.IsAvailable,"Default mode or feature gate changed.");
        ElevationPolicy.RequireSupported(options.Mode);
        Throws<ArgumentException>(()=>(options with { Mode=(DiagnosticMode)99 }).Validate());
        if(OperatingSystem.IsWindows()){
            // Even a directory containing a worker-looking executable cannot activate the release gate.
            await File.WriteAllTextAsync(Path.Combine(temporary,"WPBD.Worker.exe"),"not a trusted worker");
            try { await new EngineRunner(temporary).RunAsync(options with {Mode=DiagnosticMode.Elevated},new InlineProgress(_=>throw new Exception("Unexpected progress")),CancellationToken.None); }
            catch(EngineException error){Check(error.Message.Contains("unavailable"),"Elevated mode reached the launch path.");return;}
            throw new Exception("An unavailable elevated request was accepted.");
        }
    }),
    ("0.6.2 token proof requires availability, elevation, enabled administrator and high integrity", () =>
    {
        Check(!PermissionPresenter.VerifiedHighIntegrityAdministrator(true,false,true,0x3000),"Membership was treated as elevation.");
        Check(!PermissionPresenter.VerifiedHighIntegrityAdministrator(true,true,false,0x3000),"Disabled admin group accepted.");
        Check(!PermissionPresenter.VerifiedHighIntegrityAdministrator(true,true,true,0x2000),"Medium integrity accepted.");
        Check(!PermissionPresenter.VerifiedHighIntegrityAdministrator(false,true,true,0x3000),"Unavailable evidence accepted.");
        Check(!PermissionPresenter.VerifiedHighIntegrityAdministrator(true,true,true,null),"Missing integrity accepted.");
        Check(PermissionPresenter.VerifiedHighIntegrityAdministrator(true,true,true,0x3000),"Complete token proof rejected.");
        var snapshot=new Wpbd.TokenSnapshot{Available=false,IsElevated=false,IntegrityRid=0x2000};
        Check(!snapshot.UnprivilegedDesktop,"Partial token proof enabled the desktop.");
        snapshot.Available=true;Check(snapshot.UnprivilegedDesktop,"Unprivileged desktop rejected.");
        snapshot.IsElevated=true;Check(!snapshot.UnprivilegedDesktop,"Elevated desktop accepted.");
        snapshot.IsElevated=false;snapshot.IntegrityRid=0x3000;Check(!snapshot.UnprivilegedDesktop,"High-integrity desktop accepted.");
        return Task.CompletedTask;
    }),
    ("0.6.2 report mode cannot claim UAC success from a forged verified flag", async () =>
    {
        var node=JsonNode.Parse(Fixture("0.3"))!;
        node["Permissions"]=JsonNode.Parse("""{"RequestedMode":"Elevated","ElevationOutcome":"Succeeded","TokenInspectionStatus":"Available","ActualWorkerIsElevated":false,"AdministratorGroupPresent":true,"AdministratorGroupEnabled":true,"IntegrityRid":12288,"VerifiedHighIntegrityAdministrator":true,"Coverage":{}}""");
        await File.WriteAllTextAsync(valid,node.ToJsonString());var report=await DiagnosticData.LoadAsync(valid);
        Check(report.Permissions!.Display.Summary.Contains("Not verified") && !report.Permissions.Display.Mode.Contains("elevated worker token recorded"),"A failed elevation was displayed as successful.");
        node["Permissions"]!["ActualWorkerIsElevated"]=true;node["Permissions"]!["IntegrityRid"]=12288.5;
        await File.WriteAllTextAsync(valid,node.ToJsonString());
        Check(!(await DiagnosticData.LoadAsync(valid)).Permissions!.Display.Mode.Contains("elevated worker token recorded"),"Fractional integrity accepted.");
        foreach(var schema in new[]{"0.1","0.2","0.3"}){await File.WriteAllTextAsync(valid,Fixture(schema));Check((await DiagnosticData.LoadAsync(valid)).Permissions is null,"Historical permission evidence was fabricated.");}
    }),
    ("0.6.2 history reads bounded mode headers and preserves old report labels", async () =>
    {
        var history=Path.Combine(temporary,"WPBD-mode-header.json");
        var header="""{"Permissions":{"RequestedMode":"Standard","ElevationOutcome":"NotRequested","TokenInspectionStatus":"Available","ActualWorkerIsElevated":false},"Samples":[""";
        await File.WriteAllTextAsync(history,header+new string(' ',1024*1024)+"]}");
        Check(ReportPaths.ReadDiagnosticMode(history)=="Standard / worker not elevated","History mode was lost in a large report.");
        await File.WriteAllTextAsync(history,"{\"Samples\":[],\"Permissions\":{\"RequestedMode\":\"Standard\"}}");
        Check(ReportPaths.ReadDiagnosticMode(history)=="Not recorded","History guessed from unbounded trailing data.");
        await File.WriteAllTextAsync(history,"{invalid");Check(ReportPaths.ReadDiagnosticMode(history)=="Unavailable","Malformed history header was accepted.");
    }),
    ("0.6.1 units preserve nulls, zeroes and sensible precision", () =>
    {
        Check(InsightPresenter.Value(1790373888, "bytes") == "1.67 GiB" && InsightPresenter.Value(663*1048576d,"bytes") == "663 MiB", "Memory units differ.");
        Check(InsightPresenter.Value(90.7432911177168,"percent") == "90.7%" && InsightPresenter.Value(0,"percent") == "0.0%", "Percent formatting differs.");
        Check(InsightPresenter.Value(22.25,"percent")=="22.3%" && InsightPresenter.Value(0.005,"ms")=="0.01 ms", "Framework midpoint rounding differs.");
        Check(InsightPresenter.Value(0.450677637,"ms") == "0.45 ms" && InsightPresenter.Value(1048576,"bytes/s") == "1 MiB/s", "Disk units differ.");
        Check(InsightPresenter.Value(40,"reads/s") == "40 reads/s" && InsightPresenter.Value(null,"bytes") == "Unavailable" && InsightPresenter.Value(double.NaN) == "Unavailable", "Unavailable evidence was lost.");
        return Task.CompletedTask;
    }),
    ("0.6.1 contributors preserve rank, accounting and all expanded details", () =>
    {
        var insight = JsonNode.Parse(PresentationFixture())!;
        var rows = insight["PotentialContributors"]!.AsArray();
        for (var n = 1; n < 7; n++) { var c=rows[0]!.DeepClone(); c["Name"]=$"Candidate {n}"; rows.Add(c); }
        using var json = JsonDocument.Parse(insight.ToJsonString());
        var p=InsightPresenter.Create(json.RootElement);
        Check(p.Contributors.Count==5 && p.AllContributors.Count==7 && p.Contributors[0].Name=="Example" && p.AllContributors[6].Name=="Candidate 6", "Contributor ranking or expansion changed.");
        Check(p.Contributors[0].Usage.Contains("1.67 GiB") && p.Contributors[0].Usage.Contains("private allocation") && p.Contributors[0].Attribution=="Ownership unresolved" && p.Contributors[0].Kind=="Individual process", "Ownership or memory accounting was inferred.");
        Check(p.AllContributors[0].Details.Contains("identity: key21") && p.Steps.Count==3 && p.AllSteps[3]=="4. Fourth", "Full evidence or step order was lost.");
        Check(p.Observation.Contains("90.7%") && p.Measurements.Single(m=>m.Key=="PagesOutputPerSecond").Average=="Unavailable", "Memory presentation lost precision or nulls.");
        return Task.CompletedTask;
    }),
    ("0.6.1 grouping retains original findings, metadata and version identifiers", async () =>
    {
        var document=JsonNode.Parse(Fixture("0.3"))!;
        document["ApplicationVersion"]="0.6.1";document["EngineVersion"]="0.6.0";
        document["DiagnosticInsights"]=new JsonArray(JsonNode.Parse(PresentationFixture()));
        document["Statistics"]!["Processes"]!["All"]=new JsonArray(new JsonObject {
            ["Id"]=21,["Name"]="Example",["InstanceKey"]="key21",["OwnershipEvidence"]="No matching executable evidence",
            ["AttributionCategory"]="Unknown process ownership",["AttributionConfidence"]="Low" });
        await File.WriteAllTextAsync(valid,document.ToJsonString());var report=await DiagnosticData.LoadAsync(valid);
        Check(report.Findings.Count==2 && InsightPresenter.UnrepresentedFindings(report).Count==1, "Underlying findings were removed or duplicates remain.");
        Check(report.Insights![0].TechnicalOwnership.Contains("No matching executable evidence"), "Attribution evidence was hidden.");
        Check(report is { ApplicationVersion:"0.6.1",EngineVersion:"0.6.0",Schema:"0.3" }, "Version identifiers were conflated.");
        var overview=InsightPresenter.Overview(report);
        Check(overview.Counts=="1 significant finding; 1 advisory." && overview.Summary.Contains("Elevated memory utilisation") && overview.Sampling.Contains("1 of 2"), "Advisory or incomplete sampling vanished from overview.");
    }),
    ("0.6.1 large reports cache formatted projections without cloning raw measurements twice", async () =>
    {
        var document=JsonNode.Parse(Fixture("0.3"))!;var insights=new JsonArray();
        for(var n=0;n<300;n++){var item=JsonNode.Parse(PresentationFixture())!;item["Id"]=$"synthetic/{n}";insights.Add(item);}
        document["DiagnosticInsights"]=insights;
        await File.WriteAllTextAsync(valid,document.ToJsonString());var timer=System.Diagnostics.Stopwatch.StartNew();
        var report=await DiagnosticData.LoadAsync(valid);timer.Stop();
        Check(report.Insights!.Count==300 && ReferenceEquals(report.Insights[0].Display,report.Insights[0].Display), "Projection was missing or rerun on access.");
        Console.WriteLine($"INFO 300-insight report loaded in {timer.Elapsed.TotalMilliseconds:0.0} ms");
    }),
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

if (args.Length == 2 && args[0] == "--presentation-fixtures")
{
    var checkedCount=0;
    foreach(var expectedPath in Directory.GetFiles(args[1], "*.presentation.json"))
    {
        var reportPath=expectedPath.Replace(".presentation.json", ".json");
        var report=await DiagnosticData.LoadAsync(reportPath);
        var expected=JsonNode.Parse(await File.ReadAllTextAsync(expectedPath))!;
        var actual=JsonSerializer.SerializeToNode(new {
            Overview=InsightPresenter.Overview(report),
            Insights=report.Insights!.Select(i=>new { i.Id, Display=i.Display }).ToArray()
        });
        if(!JsonNode.DeepEquals(expected,actual)) {
            await File.WriteAllTextAsync(expectedPath+".actual",actual!.ToJsonString(new JsonSerializerOptions{WriteIndented=true}));
            throw new Exception("PowerShell/WPF presentation mismatch: " + expectedPath);
        }
        checkedCount++;
    }
    Check(checkedCount>=5,"Expected representative presentation fixtures.");
    Console.WriteLine($"PASS PowerShell/HTML and .NET/WPF presentation parity ({checkedCount} fixtures)");
}

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
            Check(html.Contains(System.Net.WebUtility.HtmlEncode(insight.Id == "operation.normal" ? report.Assessment : insight.Display.Observation)), "Live HTML and desktop insight text differ.");
        Console.WriteLine($"LIVE timing: sample average {written.RootElement.GetProperty("CollectionTiming").GetProperty("SampleWorkSeconds").GetProperty("Average")}; insight seconds {written.RootElement.GetProperty("CollectionTiming").GetProperty("InsightAnalysisSeconds")}");
    }
    Check(report.Permissions is { } permission && permission.Display.Mode=="Standard / worker not elevated", "Actual Standard worker status was not recorded.");
    using(var identity=System.Security.Principal.WindowsIdentity.GetCurrent()){
        var owner=new FileInfo(report.JsonPath).GetAccessControl().GetOwner(typeof(System.Security.Principal.SecurityIdentifier));
        Check(owner.Equals(identity.User),"The report was not owned by the original user.");
    }
    var permissionHtml=await File.ReadAllTextAsync(report.HtmlPath!);
    Check(permissionHtml.Contains(System.Net.WebUtility.HtmlEncode(report.Permissions!.Display.Summary)) &&
        permissionHtml.Contains(System.Net.WebUtility.HtmlEncode(report.Permissions.Display.TokenSummary)),"WPF/HTML permission metadata differs.");
        foreach(var metric in report.Permissions.Display.Coverage)Check(permissionHtml.Contains($"<td>{System.Net.WebUtility.HtmlEncode(metric.Measurement)}</td><td>{System.Net.WebUtility.HtmlEncode(metric.Value)}</td>"),"Coverage labels or values differ.");
    Console.WriteLine("PASS actual unprivileged Standard worker, permission reporting and original-user report ownership");
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

static string PresentationFixture() => """
    { "Id":"memory.pressure", "Title":"Severe memory pressure", "Category":"Memory pressure", "RelatedFindingCategory":"Memory pressure",
      "Priority":"Medium", "Severity":"Critical", "Confidence":"Medium", "Observation":"Recorded observation", "Interpretation":"Recorded interpretation",
      "SupportingEvidence":{"UsedPercent":{"Count":5,"Average":90.7432911177168,"Minimum":90.6,"Maximum":91},
        "AvailableBytes":{"Count":5,"Average":1556925644.8,"Minimum":1520488448,"Maximum":1577058304},
        "PagesOutputPerSecond":{"Count":0,"Average":null,"Minimum":null,"Maximum":null}},
      "PotentialContributors":[{"Name":"Example","ApplicationKey":null,"Resource":"PrivateBytes",
        "Usage":{"Count":5,"Average":1790373888,"Minimum":1700000000,"Maximum":1790373888},
        "WorkingSetBytes":{"Count":0,"Average":null,"Maximum":null}, "AttributionConfidence":"Low",
        "MeasurementCoverage":{"ValidSamples":5,"SelectedSamples":5},
        "ProcessIdentities":[{"Name":"Example","Id":21,"InstanceKey":"key21","IdentityStatus":"Provisional"}],"SampleSlots":[1,2,3,4,5]}],
      "SuggestedInvestigation":["First","Second","Third","Fourth"],"DataLimitations":["Recorded limitations"],
      "SampleSlots":[1,2,3,4,5],"MeasurementReferences":["Statistics.Memory"] }
    """;

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
