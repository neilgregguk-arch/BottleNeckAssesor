using System.Text.Json;
using Wpbd.ElevationExperiment;

if (args.Length != 1 || args[0] != "--inspect") return 2;
try
{
    using var own = Peer.Current(); own.RequireMedium();
    // Redacted facts only. In-memory account/logon/image details are never serialised.
    Console.WriteLine(JsonSerializer.Serialize(new
    {
        operation = "ReadinessOnly", available = true, elevated = own.Elevated,
        integrityRid = own.Integrity, administratorGroupPresent = own.AdminPresent,
        administratorGroupEnabled = own.AdminEnabled,
        knownFolderResolved = Path.IsPathFullyQualified(Native.ProgramFiles()),
        approvedAdministratorLab = "NotEstablishedByThisProbe",
        authorisesElevation = false
    }));
    return 0;
}
catch
{
    Console.Error.WriteLine("Readiness unavailable or context is not non-elevated Medium. No privileged action performed.");
    return 3;
}
