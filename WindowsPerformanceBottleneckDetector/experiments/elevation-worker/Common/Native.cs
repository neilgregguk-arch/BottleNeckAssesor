using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]

namespace Wpbd.ElevationExperiment;

// Windows observations only. These primitives do NOT establish protected deployment.
internal static class Native
{
    internal const uint ReadRights = 0x00120089; // READ_DATA, READ_EA, READ_ATTRIBUTES, READ_CONTROL, SYNCHRONIZE
    internal const uint Overlapped = 0x40000000;
    [StructLayout(LayoutKind.Sequential)] internal struct SecurityAttributes
    { internal int Length; internal IntPtr Descriptor; internal int Inherit; }
    [StructLayout(LayoutKind.Sequential)] internal struct SidAndAttributes
    { internal IntPtr Sid; internal uint Attributes; }
    [DllImport("kernel32.dll", SetLastError = true)] internal static extern SafeProcessHandle OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool GetProcessTimes(SafeProcessHandle process, out long creation, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll")] internal static extern uint GetProcessId(SafeProcessHandle process);
    [DllImport("kernel32.dll", SetLastError = true)] internal static extern uint WaitForSingleObject(SafeProcessHandle process, uint milliseconds);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern bool QueryFullProcessImageNameW(SafeProcessHandle process, uint flags, System.Text.StringBuilder path, ref uint length);
    [DllImport("advapi32.dll", SetLastError = true)] internal static extern bool OpenProcessToken(SafeProcessHandle process, uint access, out SafeAccessTokenHandle token);
    [DllImport("advapi32.dll", SetLastError = true)] internal static extern bool GetTokenInformation(SafeAccessTokenHandle token, int kind, IntPtr data, int size, out int required);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string text, uint revision, out IntPtr descriptor, out uint length);
    [DllImport("kernel32.dll")] internal static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("advapi32.dll")] internal static extern uint GetSecurityInfo(SafeFileHandle handle, uint type, uint information, out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr descriptor);
    [DllImport("advapi32.dll")] internal static extern uint GetSecurityDescriptorLength(IntPtr descriptor);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern SafeFileHandle CreateNamedPipeW(string name, uint openMode, uint pipeMode, uint instances, uint outSize, uint inSize, uint timeout, ref SecurityAttributes attributes);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern SafeFileHandle CreateFileW(string name, uint access, uint sharing, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool GetNamedPipeServerSessionId(SafePipeHandle pipe, out uint session);
    [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool GetNamedPipeClientSessionId(SafePipeHandle pipe, out uint session);
    [DllImport("shell32.dll")] private static extern int SHGetKnownFolderPath(in Guid id, uint flags, IntPtr token, out IntPtr path);

    internal static string ProgramFiles()
    {
        var id = new Guid("905e63b6-c1bf-494e-b29c-65b732d3d21a");
        var hr = SHGetKnownFolderPath(in id, 0, IntPtr.Zero, out var path);
        Marshal.ThrowExceptionForHR(hr);
        try { return Marshal.PtrToStringUni(path) ?? throw new InvalidDataException("Known folder unavailable."); }
        finally { Marshal.FreeCoTaskMem(path); }
    }
    internal static void Require(bool success) { if (!success) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    internal static T Query<T>(SafeAccessTokenHandle token, int kind, Func<IntPtr, T> read)
    {
        GetTokenInformation(token, kind, IntPtr.Zero, 0, out var size);
        if (size is < 1 or > 65536) throw new InvalidDataException("Token query budget.");
        var data = Marshal.AllocHGlobal(size);
        try { Require(GetTokenInformation(token, kind, data, size, out _)); return read(data); }
        finally { Marshal.FreeHGlobal(data); }
    }
}

internal sealed class Peer : IDisposable
{
    internal SafeProcessHandle Handle { get; }
    internal uint Pid { get; }
    internal long Start { get; }
    internal uint Session { get; }
    internal bool Elevated { get; }
    internal bool AdminEnabled { get; }
    internal int Integrity { get; }
    // Identities stay in memory and must never be included in logs/results/fixtures.
    internal string User { get; }
    internal string Logon { get; }
    internal string Image { get; }
    internal bool Alive => Native.WaitForSingleObject(Handle, 0) == 0x102;
    internal Peer(uint pid)
    {
        Handle = Native.OpenProcess(0x00101000, false, pid); // SYNCHRONIZE | QUERY_LIMITED_INFORMATION, no terminate/duplicate/VM rights
        try
        {
            if (Handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            Pid = Native.GetProcessId(Handle);
            if (Pid != pid) throw new InvalidDataException("Unexpected process identity.");
            Native.Require(Native.GetProcessTimes(Handle, out var start, out _, out _, out _));
            Start = start;
            Native.Require(Native.OpenProcessToken(Handle, 8, out var token)); // TOKEN_QUERY only; primary process token
            using (token)
            {
                Elevated = Native.Query(token, 20, p => Marshal.ReadInt32(p) != 0);
                Integrity = Native.Query(token, 25, p => { var sid = new SecurityIdentifier(Marshal.ReadIntPtr(p)); return int.Parse(sid.Value.Split('-')[^1], System.Globalization.CultureInfo.InvariantCulture); });
                Session = Native.Query(token, 12, p => unchecked((uint)Marshal.ReadInt32(p)));
                User = Native.Query(token, 1, p => new SecurityIdentifier(Marshal.ReadIntPtr(p)).Value);
                var groups = Native.Query(token, 2, p =>
                {
                    var count = Marshal.ReadInt32(p);
                    if (count is < 1 or > 2048) throw new InvalidDataException("Token groups budget.");
                    var items = new List<(string Sid, uint Attributes)>();
                    // TOKEN_GROUPS aligns its SID_AND_ATTRIBUTES array to pointer alignment.
                    var offset = IntPtr.Size == 8 ? 8 : 4;
                    for (var i = 0; i < count; i++)
                    {
                        var group = Marshal.PtrToStructure<Native.SidAndAttributes>(p + offset + i * Marshal.SizeOf<Native.SidAndAttributes>());
                        items.Add((new SecurityIdentifier(group.Sid).Value, group.Attributes));
                    }
                    return items;
                });
                Logon = groups.Single(g => (g.Attributes & 0xc0000000) == 0xc0000000).Sid;
                AdminEnabled = groups.Any(g => g.Sid == "S-1-5-32-544" && (g.Attributes & 4) != 0 && (g.Attributes & 0x10) == 0);
            }
            var path = new System.Text.StringBuilder(32768); uint length = 32768;
            Native.Require(Native.QueryFullProcessImageNameW(Handle, 0, path, ref length));
            Image = path.ToString();
            if (!Alive) throw new InvalidDataException("Peer exited during inspection.");
        }
        catch { Handle.Dispose(); throw; }
    }
    internal static Peer Current() => new((uint)Environment.ProcessId);
    internal void RequireMedium()
    {
        if (Elevated || Integrity != 0x2000) throw new InvalidDataException("Experiment requires an actual non-elevated Medium primary token.");
    }
    internal void Match(uint pid, uint session, long expectedStart)
    {
        if (!Alive || pid != Pid || session != Session || Start != expectedStart)
            throw new InvalidDataException("Native endpoint process/lifetime/session mismatch.");
    }
    public void Dispose() => Handle.Dispose();
}

internal static class DeploymentGate
{
    // Deliberately no caller/config/environment override. This milestone cannot establish
    // the native build, protected inventory, signing anchor or multi-account install safety.
    internal static void RequireReviewedPackage() => throw new InvalidOperationException(
        "Protected package unavailable: native build, approved inventory/signing, ACL/ancestor and administrator-lab validation are incomplete. No UAC/endpoint permitted.");
}
