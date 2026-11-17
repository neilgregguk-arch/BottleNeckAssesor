using System.Diagnostics;
using System.IO;
using System.Text.Json;
using WPBD.Core;

namespace WPBD.Desktop;

internal sealed record DesktopPreferences(int Duration, int Interval, string OutputDirectory)
{
    private const string FileName = "Preferences.json";

    internal static DesktopPreferences Load(string dataDirectory)
    {
        var defaults = new DesktopPreferences(60, 2, Path.Combine(dataDirectory, "Reports"));
        var path = Path.Combine(dataDirectory, FileName);
        try
        {
            if (!File.Exists(path)) return defaults;
            var saved = JsonSerializer.Deserialize<DesktopPreferences>(File.ReadAllText(path));
            if (saved is null) return defaults;

            var directory = defaults.OutputDirectory;
            if (saved.OutputDirectory is { Length: > 0 } && Path.IsPathFullyQualified(saved.OutputDirectory))
            {
                var candidate = Path.GetFullPath(saved.OutputDirectory);
                if (!IsProgramDirectory(candidate) && !File.Exists(candidate)) directory = candidate;
            }

            return new DesktopPreferences(
                DiagnosticOptions.Durations.Contains(saved.Duration) ? saved.Duration : defaults.Duration,
                DiagnosticOptions.Intervals.Contains(saved.Interval) ? saved.Interval : defaults.Interval,
                directory);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or ArgumentException)
        {
            Trace.TraceWarning($"WPBD settings could not be loaded: {exception.Message}");
            return defaults;
        }
    }

    internal void Save(string dataDirectory)
    {
        try
        {
            Directory.CreateDirectory(dataDirectory);
            var pending = Path.Combine(dataDirectory, $"Preferences-{Guid.NewGuid():N}.tmp");
            File.WriteAllText(pending, JsonSerializer.Serialize(this));
            File.Move(pending, Path.Combine(dataDirectory, FileName), overwrite: true);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            Trace.TraceWarning($"WPBD settings could not be saved: {exception.Message}");
        }
    }

    internal static bool IsProgramDirectory(string directory)
    {
        var relative = Path.GetRelativePath(AppContext.BaseDirectory, directory);
        return !Path.IsPathRooted(relative) && relative != ".." && !relative.StartsWith($"..{Path.DirectorySeparatorChar}", StringComparison.Ordinal);
    }
}
