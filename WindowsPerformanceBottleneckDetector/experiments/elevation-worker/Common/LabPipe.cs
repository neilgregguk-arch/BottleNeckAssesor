using System.ComponentModel;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using Microsoft.Win32.SafeHandles;
using Elevation.ProtocolLab;
using System.Buffers.Binary;

namespace Wpbd.ElevationExperiment;

// Medium-only Windows transport laboratory. Never use this descriptor as the high-worker policy.
internal static class LabPipe
{
    internal static string Name(Guid session) => session != Guid.Empty
        ? @"\\.\pipe\WPBD.Experimental.Medium.v1." + session.ToString("N")
        : throw new ArgumentException("Nonzero session required.");

    internal static NamedPipeServerStream Server(Guid session, Peer owner)
    {
        owner.RequireMedium();
        // Medium creator owns this object. Its implicit WRITE_DAC authority is a known
        // limitation, unlike the proposed high/admin-owned endpoint. Not a boundary proof.
        var text = $"O:{owner.User}D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x{Native.ReadRights:x8};;;{owner.Logon})S:(ML;;NW;;;ME)";
        Native.Require(Native.ConvertStringSecurityDescriptorToSecurityDescriptorW(text, 1, out var descriptor, out _));
        try
        {
            var sa = new Native.SecurityAttributes { Length = Marshal.SizeOf<Native.SecurityAttributes>(), Descriptor = descriptor };
            using var file = Native.CreateNamedPipeW(Name(session), 2 | Native.Overlapped | 0x00080000, 8, 1, 65536, 0, 0, ref sa);
            // OUTBOUND | OVERLAPPED | FIRST_PIPE_INSTANCE, BYTE/WAIT | REJECT_REMOTE_CLIENTS, one instance
            if (file.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            var raw = file.DangerousGetHandle(); file.SetHandleAsInvalid();
            var pipeHandle = new SafePipeHandle(raw, true);
            try { return new NamedPipeServerStream(PipeDirection.Out, true, false, pipeHandle); }
            catch { pipeHandle.Dispose(); throw; }
        }
        finally { Native.LocalFree(descriptor); }
    }

    internal static NamedPipeClientStream Client(Guid session)
    {
        using var file = Native.CreateFileW(Name(session), Native.ReadRights, 0, IntPtr.Zero, 3,
            Native.Overlapped | 0x00100000 | 0x00010000, IntPtr.Zero); // SQOS_PRESENT | IDENTIFICATION; never generic write
        if (file.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        var raw = file.DangerousGetHandle(); file.SetHandleAsInvalid();
        var pipeHandle = new SafePipeHandle(raw, true);
        try { return new NamedPipeClientStream(PipeDirection.In, true, true, pipeHandle); }
        catch { pipeHandle.Dispose(); throw; }
    }

    internal static void AuthenticateServer(NamedPipeClientStream pipe, Peer expected, long start)
    {
        Native.Require(Native.GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var pid));
        Native.Require(Native.GetNamedPipeServerSessionId(pipe.SafePipeHandle, out var session));
        expected.Match(pid, session, start);
    }
    internal static void AuthenticateClient(NamedPipeServerStream pipe, Peer expected, long start)
    {
        Native.Require(Native.GetNamedPipeClientProcessId(pipe.SafePipeHandle, out var pid));
        Native.Require(Native.GetNamedPipeClientSessionId(pipe.SafePipeHandle, out var session));
        expected.Match(pid, session, start);
    }

    internal static void InspectDescriptor(NamedPipeServerStream pipe, Peer owner)
    {
        // LABEL_SECURITY_INFORMATION does not request the audit SACL or enable SeSecurityPrivilege.
        using var borrowed = new SafeFileHandle(pipe.SafePipeHandle.DangerousGetHandle(), false);
        var status = Native.GetSecurityInfo(borrowed, 6, 1 | 4 | 0x10, out _, out _, out _, out _, out var descriptor);
        if (status != 0) throw new Win32Exception((int)status);
        try
        {
            var bytes = new byte[Native.GetSecurityDescriptorLength(descriptor)];
            Marshal.Copy(descriptor, bytes, 0, bytes.Length);
            var sd = new RawSecurityDescriptor(bytes, 0);
            if (sd.Owner?.Value != owner.User || sd.DiscretionaryAcl?.Count != 3 || sd.SystemAcl?.Count != 1)
                throw new InvalidDataException("Unexpected native descriptor structure.");
            var expected = new Dictionary<string, int> { ["S-1-5-18"] = 0x1f01ff, ["S-1-5-32-544"] = 0x1f01ff, [owner.Logon] = (int)Native.ReadRights };
            foreach (GenericAce item in sd.DiscretionaryAcl)
            {
                if (item is not CommonAce ace || ace.AceQualifier != AceQualifier.AccessAllowed || ace.AceFlags != AceFlags.None ||
                    !expected.Remove(ace.SecurityIdentifier.Value, out var mask) || ace.AccessMask != mask)
                    throw new InvalidDataException("Unexpected effective DACL.");
            }
            // RawAcl exposes a mandatory-label ACE as CustomAce, not KnownAce.
            // Parse its documented ACE_HEADER + ACCESS_MASK + SID binary layout.
            var label = sd.SystemAcl[0];
            var labelBytes = new byte[label.BinaryLength]; label.GetBinaryForm(labelBytes, 0);
            if ((byte)label.AceType != 17 || label.AceFlags != AceFlags.None || labelBytes.Length != 20 ||
                BinaryPrimitives.ReadUInt32LittleEndian(labelBytes.AsSpan(4, 4)) != 1 ||
                new System.Security.Principal.SecurityIdentifier(labelBytes, 8).Value != "S-1-16-8192")
                throw new InvalidDataException("Unexpected native mandatory label.");
        }
        finally { Native.LocalFree(descriptor); }
    }

    internal static async Task ReceiveAsync(Stream stream, FrozenRequest scope, CancellationToken cancellation)
    {
        using var transcript = new Transcript(scope); // Existing 0.6.3 validator, unchanged.
        var prefix = new byte[4];
        while (!transcript.IsComplete)
        {
            await stream.ReadExactlyAsync(prefix, cancellation);
            var size = BinaryPrimitives.ReadUInt32LittleEndian(prefix);
            if (size is < 2 or > Wire.MaxFrameBytes) throw new InvalidDataException("Length rejected before body allocation/read.");
            var body = new byte[(int)size];
            await stream.ReadExactlyAsync(body, cancellation);
            var frame = Wire.Decode(body);
            transcript.Accept(frame);
            if (transcript.IsCancelled || transcript.IsFailed || frame.Kind == "error") throw new InvalidDataException("No complete result.");
        }
        // EOF is required after completion; do not silently accept appended frames.
        if (await stream.ReadAsync(prefix.AsMemory(0, 1), cancellation) != 0) throw new InvalidDataException("Data after terminal completion.");
    }
}
