using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.Versioning;
using System.Text;
using System.Text.Json;

namespace WPBD.Core;

public sealed class EngineException(string message, string? details = null, Exception? inner = null) : Exception(message, inner)
{
    public string? Details { get; } = details;
}

[SupportedOSPlatform("windows")]
public sealed class EngineRunner(string engineDirectory)
{
    public async Task<DiagnosticReport> RunAsync(DiagnosticOptions options, IProgress<EngineProgress> progress,
        CancellationToken cancellationToken)
    {
        options = options.Validate();
        cancellationToken.ThrowIfCancellationRequested();
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 14393))
            throw new EngineException("Use a supported Windows 10 or Windows 11 workstation.");

        var directory = Path.GetFullPath(engineDirectory);
        var worker = Path.Combine(directory, "Invoke-WpbdDesktop.ps1");
        var required = new[] { worker, Path.Combine(directory, "src", "WPBD.psm1"),
            Path.Combine(directory, "src", "Collect-Metrics.ps1"), Path.Combine(directory, "src", "Analyse-Metrics.ps1"),
            Path.Combine(directory, "src", "Export-Report.ps1") };
        var missing = required.Where(path => !File.Exists(path)).ToArray();
        if (missing.Length > 0)
            throw new EngineException("The bundled diagnostic engine is incomplete. Restore the Engine folder from the same build.",
                string.Join(Environment.NewLine, missing));
        var powershell = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
        if (!File.Exists(powershell))
            throw new EngineException("Windows PowerShell 5.1 could not be found.", powershell);

        var eventName = $@"Local\WPBD-{Guid.NewGuid():N}";
        using var signal = new EventWaitHandle(false, EventResetMode.ManualReset, eventName);
        var start = new ProcessStartInfo(powershell)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = directory
        };
        foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-NonInteractive" }) start.ArgumentList.Add(argument);
        if (options.AllowProcessPolicyOverride)
        {
            start.ArgumentList.Add("-ExecutionPolicy");
            start.ArgumentList.Add("Bypass");
        }
        foreach (var argument in new[] { "-File", worker, "-DurationSeconds", options.DurationSeconds.ToString(CultureInfo.InvariantCulture),
                     "-SampleIntervalSeconds", options.IntervalSeconds.ToString(CultureInfo.InvariantCulture),
                     "-OutputPath", options.OutputDirectory, "-CancellationEvent", eventName })
            start.ArgumentList.Add(argument);

        using var process = new Process { StartInfo = start };
        try
        {
            if (!process.Start()) throw new EngineException("Windows PowerShell did not start.");
        }
        catch (Win32Exception exception)
        {
            throw new EngineException("Windows PowerShell could not be launched.", exception.Message, exception);
        }

        var cancelRequested = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var registration = cancellationToken.Register(() =>
        {
            signal.Set();
            cancelRequested.TrySetResult();
        });
        var writing = 0;
        var output = ReadOutputAsync(process.StandardOutput, progress, () => Volatile.Write(ref writing, 1));
        var stderr = ReadStderrAsync(process.StandardError);
        var exited = process.WaitForExitAsync();
        var forcedCancellation = false;
        if (await Task.WhenAny(exited, cancelRequested.Task).ConfigureAwait(false) == cancelRequested.Task &&
            await Task.WhenAny(exited, Task.Delay(TimeSpan.FromSeconds(15))).ConfigureAwait(false) != exited &&
            Volatile.Read(ref writing) == 0)
        {
            try
            {
                // This is the exact child instance started above. Never enumerate or terminate other processes.
                process.Kill();
                forcedCancellation = true;
            }
            catch (InvalidOperationException) when (process.HasExited) { }
        }
        await exited.ConfigureAwait(false);
        var result = await output.ConfigureAwait(false);
        var errors = await stderr.ConfigureAwait(false);
        if (forcedCancellation || (process.ExitCode == 2 && result.Cancelled))
            throw new OperationCanceledException(cancellationToken);

        var details = string.Join(Environment.NewLine, new[] { $"PowerShell exit code {process.ExitCode}.",
            result.Error, result.Details, result.ProtocolError, errors }.Where(line => !string.IsNullOrWhiteSpace(line)));
        if (process.ExitCode != 0 || result.Files is null || result.ProtocolError is not null)
        {
            var message = errors.Contains("PSSecurityException", StringComparison.OrdinalIgnoreCase) ||
                errors.Contains("running scripts is disabled", StringComparison.OrdinalIgnoreCase)
                ? "Windows blocked the diagnostic script. Check your organisation's script policy. If permitted, enable the process-only override and try again."
                : result.Error is not null
                    ? "The diagnostic engine reported an error. See Technical details."
                    : "The diagnostic ended without a valid completion event. See Technical details.";
            throw new EngineException(message, details);
        }

        var files = ValidateResultFiles(result.Files, options.OutputDirectory);
        try
        {
            return await DiagnosticData.LoadAsync(files.JsonPath).ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            throw new EngineException("The engine wrote a report that could not be loaded.", exception.Message, exception);
        }
    }

    private static ReportFiles ValidateResultFiles(ReportFiles files, string directory)
    {
        var json = ReportPaths.ExistingFile(files.JsonPath, ".json");
        var html = ReportPaths.ExistingFile(files.HtmlPath, ".html");
        if (!string.Equals(Path.GetDirectoryName(json), Path.TrimEndingDirectorySeparator(directory), StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(Path.ChangeExtension(json, ".html"), html, StringComparison.OrdinalIgnoreCase))
            throw new EngineException("The engine returned report paths outside the selected report pair.");
        return new ReportFiles(json, html);
    }

    private sealed record EngineOutput(ReportFiles? Files, bool Cancelled, string? Error, string? Details, string? ProtocolError);

    private static async Task<EngineOutput> ReadOutputAsync(StreamReader reader, IProgress<EngineProgress> progress, Action writing)
    {
        ReportFiles? files = null;
        string? error = null;
        string? details = null;
        string? protocolError = null;
        var cancelled = false;
        while (await reader.ReadLineAsync().ConfigureAwait(false) is { } line)
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            EngineEvent item;
            try { item = DiagnosticData.ParseEvent(line); }
            catch (Exception exception) when (exception is JsonException or InvalidDataException)
            {
                protocolError ??= $"{exception.Message} Output: {line[..Math.Min(line.Length, 1000)]}";
                continue;
            }

            if (item.Progress is { } update)
            {
                if (update.Phase == "Writing reports") writing();
                progress.Report(update);
            }
            if (item.Files is not null) files = item.Files;
            if (item.Type == "cancelled") cancelled = true;
            if (item.Error is not null)
            {
                error = item.Error;
                details = item.Details;
            }
        }
        return new EngineOutput(files, cancelled, error, details, protocolError);
    }

    private static async Task<string> ReadStderrAsync(StreamReader reader)
    {
        var output = new StringBuilder();
        while (await reader.ReadLineAsync().ConfigureAwait(false) is { } line)
            if (output.Length < 12000) output.AppendLine(line[..Math.Min(line.Length, 12000 - output.Length)]);
        return output.ToString();
    }
}
