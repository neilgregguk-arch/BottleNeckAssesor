using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Input;
using System.Windows.Data;
using Microsoft.Win32;
using WPBD.Core;

namespace WPBD.Desktop;

internal sealed class MainViewModel : INotifyPropertyChanged
{
    private readonly string _localData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WPBD");
    private readonly EngineRunner _engine = new(Path.Combine(AppContext.BaseDirectory, "Engine"));
    private CancellationTokenSource? _cancellation;
    private bool _writing;
    private bool _loading;
    private bool _refreshing;
    private int _historyRequest;
    private int _timelineIndex;
    private int _expected;
    private int _slot;
    private int _collected;
    private DiagnosticReport? _report;
    private Task _run = Task.CompletedTask;
    private HistoryEntry? _selectedHistory;
    private string _outputDirectory;
    private string? _collectionDetails;

    public MainViewModel()
    {
        var preferences = DesktopPreferences.Load(_localData);
        Duration = preferences.Duration;
        Interval = preferences.Interval;
        _outputDirectory = preferences.OutputDirectory;
        StartCommand = new Command(() => _run = StartAsync(), () => CanConfigure);
        CancelCommand = new Command(Cancel, () => CanCancel);
        ChooseFolderCommand = new Command(ChooseFolder, () => CanConfigure);
        OpenFolderCommand = new Command(() => OpenFolder(OutputDirectory, false));
        OpenLogsCommand = new Command(() => OpenFolder(Path.Combine(_localData, "Logs"), true));
        OpenHtmlCommand = new Command(() => SafeAction(() => Launch(ReportPaths.ExistingFile(_report!.HtmlPath!, ".html"))),
            () => _report?.HtmlPath is not null);
        BrowseReportCommand = new Command(() => RunUiTask(BrowseReportAsync), () => CanConfigure);
        LoadSelectedCommand = new Command(() => RunUiTask(() => LoadAsync(SelectedHistory!.Path)), () => CanConfigure && SelectedHistory is not null);
        RefreshCommand = new Command(() => RunUiTask(RefreshHistoryAsync), () => CanConfigure && !_refreshing);
        AboutCommand = new Command(() => MessageBox.Show(
            $"Windows Performance Bottleneck Detector {Version}\n\nLocal workstation diagnostics using the bundled Windows PowerShell engine.\nReports and logs are stored separately.",
            "About WPBD", MessageBoxButton.OK, MessageBoxImage.Information));
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObservableCollection<Sample> Timeline { get; } = [];
    public IReadOnlyList<int> Intervals => DiagnosticOptions.Intervals;
    public IReadOnlyList<DurationOption> Durations { get; } =
        [new(30, "30 seconds"), new(60, "60 seconds"), new(120, "2 minutes"), new(300, "5 minutes")];
    public int Duration { get; set; }
    public int Interval { get; set; }
    public bool PolicyOverride { get; set; }
    public string Version => App.ProductVersion;
    public string Computer => Environment.MachineName;
    public string Status { get; private set; } = "Ready";
    public string Activity { get; private set; } = "Start a diagnostic or load a saved report.";
    public string? ErrorMessage { get; private set; }
    public string? TechnicalDetails { get; private set; }
    public bool HasError => ErrorMessage is not null;
    public string OutputDirectory => _outputDirectory;
    public bool CanConfigure => _cancellation is null && !_loading;
    public bool CanCancel => _cancellation is { IsCancellationRequested: false } && !_writing;
    public bool IsRunning => _cancellation is not null;
    public bool IsIndeterminate => IsRunning && (_expected == 0 || _writing || _slot == _expected);
    public double ProgressValue => _expected == 0 ? 0 : 100.0 * _slot / _expected;
    public string SampleProgress => _expected == 0 ? "Waiting for samples" : $"{_collected} collected · {_slot} of {_expected} scheduled slots reached";
    public string Elapsed => _report is { } result ? $"{result.Quality.DurationSeconds:N1} s" :
        Timeline.LastOrDefault() is { } sample ? $"{sample.ElapsedSeconds:N1} s" : "—";
    public int TimelineMaximum => Math.Max(0, Timeline.Count - 1);
    public bool HasTimeline => Timeline.Count > 0;
    public int TimelineIndex
    {
        get => _timelineIndex;
        set
        {
            var index = Math.Clamp(value, 0, TimelineMaximum);
            if (index == _timelineIndex) return;
            _timelineIndex = index;
            Changed();
        }
    }
    private Sample? SelectedSample => Timeline.Count > 0 ? Timeline[_timelineIndex] : null;
    public string SampleLabel => SelectedSample is { } sample
        ? $"Slot {sample.Slot} · {sample.Timestamp.ToLocalTime():HH:mm:ss} · {sample.ElapsedSeconds:N1} s"
        : "Waiting for measurements";
    public string CpuValue => Format(SelectedSample?.CpuPercent, "0.0", "%");
    public string MemoryValue => Format(SelectedSample?.MemoryPercent, "0.0", "%");
    public string AvailableValue => Format(SelectedSample?.AvailableBytes / 1073741824, "0.00", " GiB");
    public string StorageValue => Format(SelectedSample?.PeakDiskLatency, "0.00", " ms");
    public string StorageActivity => $"Peak disk activity   {Format(SelectedSample?.PeakDiskActivity, "0.0", "%")}";
    public string DiskDetails => SelectedSample is { Disks.Count: > 0 } sample
        ? string.Join(Environment.NewLine, sample.Disks.Select(disk =>
            $"{disk.Name}   Active {Format(disk.Active, "0.0", "%")}   Read {Format(disk.ReadLatency, "0.00", " ms")}   Write {Format(disk.WriteLatency, "0.00", " ms")}"))
        : "No per-disk measurements available for this sample.";
    public int SelectedTab { get; set; }
    public string Assessment => _report?.Assessment ?? "No completed assessment";
    public string ReportContext => _report is { } report
        ? $"{report.Computer} · {report.Started.ToLocalTime():g} · schema {report.Schema}"
        : "Findings and process rankings are available after collection or when you open a saved report.";
    public IReadOnlyList<DiagnosticInsight> Insights => _report?.Insights ?? [];
    public IReadOnlyList<Finding> Findings => _report?.Findings ?? [];
    private string _processSearch = "";
    private string _processFilter = "All captured";
    private ICollectionView _processes = CollectionViewSource.GetDefaultView(Array.Empty<ProcessReading>());
    private ICollectionView _applications = CollectionViewSource.GetDefaultView(Array.Empty<ApplicationReading>());
    private string _applicationSort = "Private memory";
    public ICollectionView Processes => _processes;
    public ICollectionView Applications => _applications;
    public IReadOnlyList<string> ProcessFilters { get; } = ["All captured", "Identified application", "Windows system process", "Identified service process",
        "Protected or restricted process", "Unattributed application process", "Unknown process ownership",
        "Metadata restricted", "Verified identity", "Provisional identity", "CPU measured", "Memory measured"];
    public IReadOnlyList<string> ApplicationSorts { get; } = ["Private memory", "Working set", "CPU", "Name"];
    public string ApplicationSort
    {
        get => _applicationSort;
        set { _applicationSort = value; SortApplications(); Changed(); }
    }
    public string ProcessSearch
    {
        get => _processSearch;
        set { _processSearch = value; _processes.Refresh(); _applications.Refresh(); Changed(); }
    }
    public string ProcessFilter
    {
        get => _processFilter;
        set { _processFilter = value; _processes.Refresh(); _applications.Refresh(); Changed(); }
    }
    public string ProcessCount => _report?.Attribution is { } quality
        ? $"{quality.UniqueIdentities} identities · {quality.Verified} verified · {quality.Provisional} provisional · {quality.UniquePids} distinct PIDs · {quality.Observations} observations · peak {quality.PeakConcurrent} concurrently captured"
        : $"{_report?.Processes.Count ?? 0} recorded entries. Historical reports retain their original identity rules.";
    public string AttributionSummary => _report?.Attribution is { } quality
        ? $"{quality.Identified} identified application · {quality.WindowsSystem} Windows system · {quality.IdentifiedServices} service-only identities · {quality.RestrictedOwnership} protected/restricted ownership · {quality.Unattributed} unattributed application · {quality.Unknown} unknown ownership. Attributed {Format(quality.AttributedPercent, "0.0", "%")}. Restricted metadata affects {quality.Restricted} identities and can overlap a known process type."
        : "Attribution quality was not recorded in this report.";
    public string AttributionMemory => _report?.Attribution is { } quality
        ? $"Unattributed private-memory footprint peaked at {Format(quality.UnattributedPrivateMiB, "N1", " MiB")} using complete same-sample totals. Attribution confidence describes ownership evidence independently of measurement availability."
        : "Ownership cannot be reassessed without recorded metadata.";
    private bool FilterProcess(object item)
    {
        var process = (ProcessReading)item;
        var text = $"{process.Name} {process.Pid} {process.Path} {process.Application} {process.Services} {process.AttributionCategory} {process.AttributionReasons}";
        return text.Contains(_processSearch, StringComparison.OrdinalIgnoreCase) && _processFilter switch
        {
            "Metadata restricted" => process.MetadataAccess == "Restricted",
            "Verified identity" => process.IdentityStatus.StartsWith("Verified", StringComparison.Ordinal),
            "Provisional identity" => process.IdentityStatus == "Provisional",
            "CPU measured" => process.AverageCpuPercent.HasValue,
            "Memory measured" => process.PrivateMiB.HasValue || process.WorkingSetMiB.HasValue,
            "All captured" => true,
            _ => process.AttributionCategory == _processFilter
        };
    }
    private void SortApplications()
    {
        var property = _applicationSort switch
        {
            "Working set" => nameof(ApplicationReading.WorkingSetMiB),
            "CPU" => nameof(ApplicationReading.AverageCpu),
            "Name" => nameof(ApplicationReading.Name),
            _ => nameof(ApplicationReading.PrivateMiB)
        };
        using (_applications.DeferRefresh())
        {
            _applications.SortDescriptions.Clear();
            _applications.SortDescriptions.Add(new SortDescription(property,
                property == nameof(ApplicationReading.Name) ? ListSortDirection.Ascending : ListSortDirection.Descending));
        }
    }
    public IReadOnlyList<string> CoverageGaps => _report?.CoverageGaps ?? [];
    public IReadOnlyList<string> CollectionErrors => _report?.Quality.Errors ?? [];
    public string QualitySummary => _report is { Quality: var quality }
        ? $"{quality.Actual}/{quality.Expected} collected · {quality.ValidCpu} valid CPU · {quality.Missed} missed · {quality.Errors.Count} error groups · {quality.DurationSeconds:N1} s"
        : "Sampling quality will appear with a completed report.";
    public string TimingSummary => _report?.Quality.AverageWorkSeconds is double average
        ? $"Collection and conversion averaged {average:N2} s per sample. Peak {Format(_report.Quality.PeakWorkSeconds, "0.00", " s")}."
        : "";
    public string ReportPath => _report?.JsonPath ?? "No report selected";
    public IReadOnlyList<HistoryEntry> History { get; private set; } = [];
    public string HistoryStatus { get; private set; } = "Reports are listed from the selected folder.";
    public HistoryEntry? SelectedHistory
    {
        get => _selectedHistory;
        set
        {
            if (_selectedHistory == value) return;
            _selectedHistory = value;
            CommandManager.InvalidateRequerySuggested();
        }
    }

    public ICommand StartCommand { get; }
    public ICommand CancelCommand { get; }
    public ICommand ChooseFolderCommand { get; }
    public ICommand OpenFolderCommand { get; }
    public ICommand OpenLogsCommand { get; }
    public ICommand OpenHtmlCommand { get; }
    public ICommand BrowseReportCommand { get; }
    public ICommand LoadSelectedCommand { get; }
    public ICommand RefreshCommand { get; }
    public ICommand AboutCommand { get; }

    public void Initialize() => RunUiTask(RefreshHistoryAsync);
    public void SavePreferences() => new DesktopPreferences(Duration, Interval, OutputDirectory).Save(_localData);

    public async Task FinishClosingAsync()
    {
        Cancel();
        await _run;
    }

    private async Task StartAsync()
    {
        ErrorMessage = TechnicalDetails = _collectionDetails = null;
        DiagnosticOptions options;
        try { options = new DiagnosticOptions(Duration, Interval, OutputDirectory, PolicyOverride).Validate(); }
        catch (Exception exception) { ShowError(exception, "Check the diagnostic configuration."); return; }

        using var cancellation = new CancellationTokenSource();
        _cancellation = cancellation;
        _report = null;
        _processes = CollectionViewSource.GetDefaultView(Array.Empty<ProcessReading>());
        _applications = CollectionViewSource.GetDefaultView(Array.Empty<ApplicationReading>());
        _writing = false;
        _expected = _slot = _collected = _timelineIndex = 0;
        Timeline.Clear();
        Status = "Running";
        Activity = "Starting the local diagnostic engine…";
        SelectedTab = 0;
        Changed();
        try
        {
            var report = await _engine.RunAsync(options, new Progress<EngineProgress>(UpdateProgress), cancellation.Token);
            ApplyReport(report, false);
            _collectionDetails = string.Join(Environment.NewLine, report.Quality.Errors);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
            Status = "Cancelled";
            Activity = "Collection stopped. Any samples shown belong to the cancelled session.";
        }
        catch (Exception exception)
        {
            Status = "Failed";
            Activity = "The diagnostic did not produce a usable assessment.";
            ShowError(exception, "The diagnostic could not finish.");
        }
        finally
        {
            _writing = true;
            try
            {
                await WriteLogAsync(options);
                await RefreshHistoryAsync();
            }
            finally
            {
                _cancellation = null;
                _writing = false;
                Changed();
            }
        }
    }

    private void UpdateProgress(EngineProgress update)
    {
        if (_cancellation is null) return;
        _writing = update.Phase == "Writing reports";
        if (!_cancellation.IsCancellationRequested) Activity = update.Phase;
        if (update.Sample is { } sample)
        {
            var followLatest = Timeline.Count == 0 || _timelineIndex == Timeline.Count - 1;
            Timeline.Add(sample);
            if (followLatest) _timelineIndex = Timeline.Count - 1;
            _slot = sample.Slot;
            _collected = update.Collected;
            _expected = update.Expected;
        }
        Changed();
    }

    private void Cancel()
    {
        if (!CanCancel) return;
        _cancellation!.Cancel();
        Status = "Cancelling";
        Activity = "Waiting for the diagnostic engine to stop…";
        Changed();
    }

    private async Task WriteLogAsync(DiagnosticOptions options)
    {
        try
        {
            var line = $"{DateTimeOffset.Now:O} · {Status} · {options.DurationSeconds} s / {options.IntervalSeconds} s\n{ErrorMessage}\n{TechnicalDetails}\n{_collectionDetails}";
            var directory = Directory.CreateDirectory(Path.Combine(_localData, "Logs")).FullName;
            await File.WriteAllTextAsync(Path.Combine(directory, $"WPBD-{DateTime.UtcNow:yyyyMMdd-HHmmssfff}-{Guid.NewGuid():N}.log"), line);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            TechnicalDetails = $"{TechnicalDetails}\nThe diagnostic log could not be written. {exception.Message}".Trim();
            ErrorMessage ??= "The application log could not be written.";
            Changed();
        }
    }

    private async Task RefreshHistoryAsync()
    {
        var request = ++_historyRequest;
        _refreshing = true;
        try
        {
            var directory = OutputDirectory;
            var entries = await Task.Run(() => ReportPaths.History(directory));
            if (request != _historyRequest) return;
            History = entries;
            HistoryStatus = entries.Count == 0 ? "No WPBD JSON reports found in this folder." : $"{entries.Count} report file(s)";
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            if (request == _historyRequest)
            {
                History = [];
                HistoryStatus = $"Report history could not be read. {exception.Message}";
            }
        }
        finally
        {
            if (request == _historyRequest)
            {
                _refreshing = false;
                Changed();
            }
        }
    }

    private async Task BrowseReportAsync()
    {
        var dialog = new OpenFileDialog { Filter = "WPBD diagnostic reports (*.json)|*.json", CheckFileExists = true };
        if (Directory.Exists(OutputDirectory)) dialog.InitialDirectory = OutputDirectory;
        if (dialog.ShowDialog() == true) await LoadAsync(dialog.FileName);
    }

    private async Task LoadAsync(string path)
    {
        _loading = true;
        ErrorMessage = TechnicalDetails = null;
        Changed();
        try
        {
            var report = await DiagnosticData.LoadAsync(ReportPaths.ExistingFile(path, ".json"));
            ApplyReport(report, true);
        }
        catch (Exception exception)
        {
            ShowError(exception, "The selected report could not be opened.");
        }
        finally
        {
            _loading = false;
            Changed();
        }
    }

    private void ApplyReport(DiagnosticReport report, bool historical)
    {
        _report = report;
        _processes = new ListCollectionView(report.Processes.ToList());
        _processes.Filter = FilterProcess;
        _applications = new ListCollectionView((report.Applications ?? []).ToList());
        _applications.Filter = item => ((ApplicationReading)item).Processes.Any(FilterProcess);
        SortApplications();
        _expected = report.Quality.Expected;
        _slot = _expected;
        _collected = report.Quality.Actual;
        _timelineIndex = 0;
        Timeline.Clear();
        foreach (var sample in report.Samples) Timeline.Add(sample);
        _timelineIndex = TimelineMaximum;
        Status = report.Incomplete ? "Incomplete evidence" : historical ? "Saved report" : "Complete";
        Activity = historical ? "Viewing a saved diagnostic." : "Analysis finished. Review the findings and sampling quality.";
        SelectedTab = 1;
        Changed();
    }

    private void ChooseFolder() => SafeAction(() =>
    {
        var dialog = new OpenFolderDialog { Title = "Choose the diagnostic report folder" };
        if (Directory.Exists(OutputDirectory)) dialog.InitialDirectory = OutputDirectory;
        if (dialog.ShowDialog() != true) return;
        var directory = Path.GetFullPath(dialog.FolderName);
        if (DesktopPreferences.IsProgramDirectory(directory))
            throw new ArgumentException("Choose a report folder outside the WPBD program directory.");
        _outputDirectory = directory;
        Changed();
        RunUiTask(RefreshHistoryAsync);
    });

    private void OpenFolder(string path, bool create) => SafeAction(() =>
    {
        if (create) Directory.CreateDirectory(path);
        if (!Directory.Exists(path)) throw new DirectoryNotFoundException("The folder does not exist. Run a diagnostic or choose an existing folder.");
        Launch(Path.GetFullPath(path));
    });

    private static void Launch(string path) => Process.Start(new ProcessStartInfo(path) { UseShellExecute = true })?.Dispose();

    private void SafeAction(Action action)
    {
        try { action(); }
        catch (Exception exception) { ShowError(exception, "The requested action could not be completed."); }
    }

    private async void RunUiTask(Func<Task> action)
    {
        try { await action(); }
        catch (Exception exception) { ShowError(exception, "The requested action could not be completed."); }
    }

    private void ShowError(Exception exception, string caption)
    {
        ErrorMessage = $"{caption} {exception.Message}";
        TechnicalDetails = exception is EngineException { Details: { } details } ? details : exception.ToString();
        Changed();
    }

    private void Changed()
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
        CommandManager.InvalidateRequerySuggested();
    }

    private static string Format(double? value, string format, string unit) =>
        value is double measured ? measured.ToString(format) + unit : "Unavailable";

    public sealed record DurationOption(int Seconds, string Label);

    private sealed class Command(Action execute, Func<bool>? canExecute = null) : ICommand
    {
        public bool CanExecute(object? parameter) => canExecute?.Invoke() ?? true;
        public void Execute(object? parameter) => execute();
        public event EventHandler? CanExecuteChanged
        {
            add => CommandManager.RequerySuggested += value;
            remove => CommandManager.RequerySuggested -= value;
        }
    }
}
