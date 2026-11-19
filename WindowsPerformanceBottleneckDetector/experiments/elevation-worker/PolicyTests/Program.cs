using System.Runtime.InteropServices;
using Wpbd.ElevationExperiment;

if (args.Length != 1 || args[0] != "--self-test") return 2;
using var own = Peer.Current(); own.RequireMedium();
Console.WriteLine("DESCRIPTOR POLICY TESTS ONLY: Windows converts SDDL in memory. No High pipe, elevation, install or effective-access proof.");
var passed = 0;
byte[] Descriptor(string text)
{
    Native.Require(Native.ConvertStringSecurityDescriptorToSecurityDescriptorW(text, 1, out var data, out var length));
    try { var bytes = new byte[length]; Marshal.Copy(data, bytes, 0, bytes.Length); return bytes; }
    finally { Native.LocalFree(data); }
}
void Check(string name, Action test) { test(); passed++; Console.WriteLine("PASS " + name); }
void Reject(string text)
{
    try { EndpointDescriptor.ValidateCandidateHigh(Descriptor(text), own.Logon); }
    catch (InvalidDataException) { return; }
    throw new Exception("Invalid descriptor was accepted.");
}
var candidate = EndpointDescriptor.CandidateHighSddl(own.Logon);
Check("fixed High policy parses with SYSTEM/Administrators owner", () => {
    EndpointDescriptor.ValidateCandidateHigh(Descriptor(candidate), own.Logon);
    EndpointDescriptor.ValidateCandidateHigh(Descriptor(candidate.Replace("O:BA", "O:SY", StringComparison.Ordinal)), own.Logon);
});
foreach (var label in new[] { "ME", "LW", "SI" })
    Check("reject wrong mandatory level " + label, () => Reject(candidate.Replace(";;;HI)", $";;;{label})", StringComparison.Ordinal)));
Check("reject absent mandatory label", () => Reject(candidate[..candidate.IndexOf("S:", StringComparison.Ordinal)]));
Check("reject wrong mandatory policy", () => Reject(candidate.Replace("ML;;NW", "ML;;NR", StringComparison.Ordinal)));
Check("reject combined read-up block", () => Reject(candidate.Replace("ML;;NW", "ML;;NWNR", StringComparison.Ordinal)));
Check("reject unrelated owner", () => Reject(candidate.Replace("O:BA", "O:BU", StringComparison.Ordinal)));
Check("reject unprotected DACL", () => Reject(candidate.Replace("D:P", "D:", StringComparison.Ordinal)));
Check("reject null/empty DACL", () => { Reject("O:BAD:NO_ACCESS_CONTROLS:(ML;;NW;;;HI)"); Reject("O:BAD:PS:(ML;;NW;;;HI)"); });
Check("reject broad read grant", () => Reject(candidate.Replace("S:", "(A;;FR;;;WD)S:", StringComparison.Ordinal)));
Check("reject original-logon write/create-instance grant", () => Reject(candidate.Replace("0x00120089", "0x0012019f", StringComparison.Ordinal)));
Check("reject original-logon WRITE_DAC", () => Reject(candidate.Replace("0x00120089", "0x00160089", StringComparison.Ordinal)));
Check("reject inherited/or inheritable grants", () => Reject(candidate.Replace("(A;;FA;;;SY)", "(A;CI;FA;;;SY)", StringComparison.Ordinal)));
Check("reject duplicate logon ACE", () => Reject(candidate.Replace("S:", $"(A;;FR;;;{own.Logon})S:", StringComparison.Ordinal)));
Check("reject missing administrator grant", () => Reject(candidate.Replace("(A;;FA;;;BA)", "", StringComparison.Ordinal)));
Check("reject deny ACE substitution", () => Reject(candidate.Replace("(A;;FA;;;SY)", "(D;;FA;;;SY)", StringComparison.Ordinal)));
Check("reject wrong logon/session binding", () => {
    try { EndpointDescriptor.ValidateCandidateHigh(Descriptor(candidate), "S-1-5-5-0-0"); }
    catch (InvalidDataException) { return; }
    throw new Exception("Wrong logon accepted.");
});
Check("reject account SID in place of logon identity", () => {
    try { _ = EndpointDescriptor.CandidateHighSddl(own.User); }
    catch (InvalidDataException) { return; }
    throw new Exception("Account SID accepted.");
});
Check("Medium descriptor cannot pass High policy", () => Reject($"O:{own.User}D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x00120089;;;{own.Logon})S:(ML;;NW;;;ME)"));
Check("reject empty or truncated descriptor", () => {
    foreach (var bytes in new[] { Array.Empty<byte>(), new byte[20] })
    {
        try { EndpointDescriptor.ValidateCandidateHigh(bytes, own.Logon); }
        catch (InvalidDataException) { continue; }
        throw new Exception("Malformed descriptor accepted.");
    }
});
Console.WriteLine($"{passed} descriptor policy checks passed. High object creation/cross-account rights remain UNTESTED.");
return 0;
