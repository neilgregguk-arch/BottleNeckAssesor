using System.Text.Json;

namespace WPBD.Core;

public sealed record HistoryEntry(string Path, string FileName, DateTime Modified, string DiagnosticMode = "Not recorded");

public static class ReportPaths
{
    public static IReadOnlyList<HistoryEntry> History(string directory)
    {
        if (!Directory.Exists(directory)) return [];
        return new DirectoryInfo(directory).EnumerateFiles("WPBD-*.json", SearchOption.TopDirectoryOnly)
            .Where(file => file.Extension.Equals(".json", StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(file => file.LastWriteTimeUtc).ThenBy(file => file.Name)
            .Select(file => new HistoryEntry(file.FullName, file.Name, file.LastWriteTime, ReadDiagnosticMode(file.FullName))).ToArray();
    }

    public static string ReadDiagnosticMode(string path)
    {
        // New reports put Permissions before Samples. Never parse a whole large history report to label its row.
        try
        {
            using var stream=File.OpenRead(path);
            var bytes=new byte[(int)Math.Min(stream.Length,8192)];
            stream.ReadExactly(bytes);
            var offset=bytes.Length>=3 && bytes[0]==0xef && bytes[1]==0xbb && bytes[2]==0xbf ? 3 : 0;
            var reader=new Utf8JsonReader(bytes.AsSpan(offset),false,new JsonReaderState(new JsonReaderOptions{MaxDepth=32}));
            while(reader.Read())
            {
                if(reader.TokenType!=JsonTokenType.PropertyName || reader.CurrentDepth!=1)continue;
                if(reader.ValueTextEquals("Samples")) return "Not recorded";
                if(!reader.ValueTextEquals("Permissions"))continue;
                if(!reader.Read() || !JsonDocument.TryParseValue(ref reader,out var document))return "Unavailable";
                using(document) return new DiagnosticPermissions(document.RootElement).Display.Mode;
            }
            return "Not recorded";
        }
        catch(Exception error) when(error is IOException or UnauthorizedAccessException or JsonException or System.Security.SecurityException)
        { return "Unavailable"; }
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
