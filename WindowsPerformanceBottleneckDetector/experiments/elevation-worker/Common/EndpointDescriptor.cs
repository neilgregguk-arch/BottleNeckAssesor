using System.Buffers.Binary;
using System.Security.AccessControl;
using System.Security.Principal;

namespace Wpbd.ElevationExperiment;

// Checks descriptor CONTENT only, never endpoint identity or effective cross-account access.
internal static class EndpointDescriptor
{
    private const int FullFileControl = 0x1f01ff;
    internal static string CandidateHighSddl(string originalLogon)
    {
        RequireLogon(originalLogon);
        return $"O:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x{Native.ReadRights:x8};;;{originalLogon})S:(ML;;NW;;;HI)";
    }

    internal static void ValidateCandidateHigh(byte[] bytes, string originalLogon)
    {
        var sd = Parse(bytes);
        if (sd.Owner?.Value is not ("S-1-5-18" or "S-1-5-32-544")) throw new InvalidDataException("High candidate requires SYSTEM/Administrators owner.");
        Validate(sd, originalLogon, 0x3000);
    }
    internal static void ValidateMediumLab(byte[] bytes, string originalUser, string originalLogon)
    {
        var sd = Parse(bytes);
        if (sd.Owner?.Value != originalUser) throw new InvalidDataException("Unexpected Medium lab owner.");
        Validate(sd, originalLogon, 0x2000);
    }
    private static RawSecurityDescriptor Parse(byte[] bytes)
    {
        if (bytes.Length is < 20 or > 65536) throw new InvalidDataException("Descriptor size rejected.");
        try { return new RawSecurityDescriptor(bytes, 0); }
        catch (ArgumentException) { throw new InvalidDataException("Malformed descriptor."); }
    }
    private static void RequireLogon(string logon)
    {
        try
        {
            var sid = new SecurityIdentifier(logon);
            if (!sid.Value.StartsWith("S-1-5-5-", StringComparison.Ordinal) || sid.Value.Split('-').Length != 6)
                throw new InvalidDataException("Windows logon SID required.");
        }
        catch (ArgumentException) { throw new InvalidDataException("Invalid Windows logon SID."); }
    }
    private static void Validate(RawSecurityDescriptor sd, string originalLogon, int integrity)
    {
        RequireLogon(originalLogon);
        var required = ControlFlags.DiscretionaryAclPresent | ControlFlags.DiscretionaryAclProtected | ControlFlags.SystemAclPresent;
        if ((sd.ControlFlags & required) != required || sd.DiscretionaryAcl?.Count != 3 || sd.SystemAcl?.Count != 1)
            throw new InvalidDataException("Missing/protected ACL or unexpected ACE count.");
        var expected = new Dictionary<string, int> { ["S-1-5-18"] = FullFileControl, ["S-1-5-32-544"] = FullFileControl, [originalLogon] = (int)Native.ReadRights };
        foreach (GenericAce item in sd.DiscretionaryAcl)
        {
            if (item is not CommonAce ace || ace.AceType != AceType.AccessAllowed || ace.IsCallback || ace.AceFlags != AceFlags.None ||
                !expected.Remove(ace.SecurityIdentifier.Value, out var mask) || ace.AccessMask != mask)
                throw new InvalidDataException("Unexpected DACL grant/type/inheritance.");
        }
        var label = sd.SystemAcl[0];
        var encoded = new byte[label.BinaryLength]; label.GetBinaryForm(encoded, 0);
        if ((byte)label.AceType != 17 || label.AceFlags != AceFlags.None || encoded.Length != 20 ||
            BinaryPrimitives.ReadUInt32LittleEndian(encoded.AsSpan(4, 4)) != 1 ||
            new SecurityIdentifier(encoded, 8).Value != $"S-1-16-{integrity}")
            throw new InvalidDataException("Missing/incorrect mandatory integrity policy.");
    }
}
