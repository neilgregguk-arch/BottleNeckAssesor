using System.Text.Json;
namespace WPBD.Core;

public enum DiagnosticMode { Standard, Elevated }
public static class ElevationPolicy
{
    // Release gate: never activate an unverified privileged execution path by discovering files or configuration.
    public static bool IsAvailable => false;
    public static void RequireSupported(DiagnosticMode mode)
    {
        if (!Enum.IsDefined(mode)) throw new ArgumentException("Choose a supported diagnostic mode.");
        if (mode == DiagnosticMode.Elevated)
            throw new EngineException("Elevated diagnostics are unavailable in this build. Select Standard diagnostic.",
                "The protected worker deployment and authenticated cross-account IPC have not been implemented and validated. No UAC request or diagnostic worker was started.");
    }
}
public sealed record PermissionMetric(string Measurement, string Value);
public sealed record PermissionDisplay(string Mode, string Summary, string TokenSummary, IReadOnlyList<PermissionMetric> Coverage, string Limitations);
public sealed record DiagnosticPermissions(JsonElement Evidence)
{
    public PermissionDisplay Display { get; } = PermissionPresenter.Create(Evidence);
}
public static class PermissionPresenter
{
    public static bool VerifiedHighIntegrityAdministrator(bool available, bool? elevated, bool? enabledAdmin, int? integrityRid) =>
        available && elevated == true && enabledAdmin == true && integrityRid >= 0x3000;
    public static PermissionDisplay Create(JsonElement data)
    {
        var requested=Text(data,"RequestedMode");
        if(requested is not ("Standard" or "Elevated")) requested="Not recorded";
        var available=Text(data,"TokenInspectionStatus")=="Available";
        var elevated=Flag(data,"ActualWorkerIsElevated");
        var member=Flag(data,"AdministratorGroupPresent");var enabled=Flag(data,"AdministratorGroupEnabled");
        var rawRid=Get(data,"IntegrityRid"); int? rid=rawRid.ValueKind==JsonValueKind.Number && rawRid.TryGetInt32(out var integerRid) ? integerRid : null; var verified=VerifiedHighIntegrityAdministrator(available,elevated,enabled,rid);
        var mode=requested=="Not recorded" ? "Not recorded" : requested + (available && elevated==false ? " / worker not elevated" : verified ? " / elevated worker token recorded" : " / worker elevation not verified");
        var outcome=Text(data,"ElevationOutcome")=="NotRequested" && requested=="Standard" ? "Not requested" : "Not verified";
        var integrity=Text(data,"IntegrityLevel") ?? "Unavailable";
        var summary=$"{mode}. Elevation: {outcome}.";
        var token=$"Worker elevated: {YesNo(available ? elevated : null)}; administrator group present: {YesNo(member)}; administrator group enabled: {YesNo(enabled)}; integrity: {integrity}.";
        var coverage=Get(data,"Coverage");
        var rows=InsightPresenter.PermissionFields.Select(f=>new PermissionMetric(f.Label,InsightPresenter.Value(Number(coverage,f.Key),f.Unit))).ToArray();
        var limits=Get(data,"Limitations");
        return new(mode,summary,token,rows,limits.ValueKind==JsonValueKind.Array ? string.Join("\n",limits.EnumerateArray().Where(x=>x.ValueKind==JsonValueKind.String).Select(x=>x.GetString())) : "Permission limitations were not recorded.");
    }
    private static string YesNo(bool? value)=>value is null ? "Unavailable" : value.Value ? "Yes" : "No";
    private static JsonElement Get(JsonElement data,string key)=>data.ValueKind==JsonValueKind.Object && data.TryGetProperty(key,out var value) ? value : default;
    private static string? Text(JsonElement data,string key)=>Get(data,key) is {ValueKind:JsonValueKind.String} value ? value.GetString() : null;
    private static double? Number(JsonElement data,string key)=>Get(data,key) is {ValueKind:JsonValueKind.Number} value && value.TryGetDouble(out var number) ? number : null;
    private static bool? Flag(JsonElement data,string key)=>Get(data,key).ValueKind switch {JsonValueKind.True=>true,JsonValueKind.False=>false,_=>null};
}
