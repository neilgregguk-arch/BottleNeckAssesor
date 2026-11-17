namespace WPBD.Core;

public sealed record HistoryEntry(string Path, string FileName, DateTime Modified);

public static class ReportPaths
{
    public static IReadOnlyList<HistoryEntry> History(string directory)
    {
        if (!Directory.Exists(directory)) return [];
        return new DirectoryInfo(directory).EnumerateFiles("WPBD-*.json", SearchOption.TopDirectoryOnly)
            .Where(file => file.Extension.Equals(".json", StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(file => file.LastWriteTimeUtc).ThenBy(file => file.Name)
            .Select(file => new HistoryEntry(file.FullName, file.Name, file.LastWriteTime)).ToArray();
    }

    public static string ExistingFile(string path, string extension)
    {
        if (!Path.IsPathFullyQualified(path) || !Path.GetExtension(path).Equals(extension, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException($"Choose a valid {extension} file.");
        var fullPath = Path.GetFullPath(path);
        if (!File.Exists(fullPath)) throw new FileNotFoundException("The report file could not be found.", fullPath);
        return fullPath;
    }
}
