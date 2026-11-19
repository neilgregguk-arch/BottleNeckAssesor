using Wpbd.ElevationExperiment;

if (args.Length != 1 || args[0] != "--probe")
{
    Console.Error.WriteLine("Experimental relay: --probe is the only action; deployment is blocked.");
    return 2;
}
try
{
    using var own = Peer.Current(); own.RequireMedium();
    _ = Native.ProgramFiles(); // Windows known-folder API, never caller environment/path.
    DeploymentGate.RequireReviewedPackage();
    return 4;
}
catch
{
    Console.Error.WriteLine("Relay refused: no reviewed protected native package. No UAC or worker launch performed.");
    return 4;
}
