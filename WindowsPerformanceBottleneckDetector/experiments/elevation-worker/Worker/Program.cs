using Elevation.ProtocolLab;
using Wpbd.ElevationExperiment;

// Refusal-stage prototype only. No endpoint, child launch, report write or UAC path exists.
try
{
    _ = FrozenRequest.Parse(args);
    using var own = Peer.Current();
    if (!own.Elevated || !own.AdminEnabled || own.Integrity < 0x3000)
    {
        Console.Error.WriteLine("Worker refused: actual primary token is not an elevated high administrator.");
        return 3;
    }
    DeploymentGate.RequireReviewedPackage();
    return 4;
}
catch (ArgumentException)
{
    Console.Error.WriteLine("Worker refused: unsupported/noncanonical arguments.");
    return 2;
}
catch
{
    Console.Error.WriteLine("Worker refused: protected deployment or native identity unavailable. No endpoint created.");
    return 4;
}
