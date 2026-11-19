// Read-only token evidence, shared by PowerShell 5.1 and the desktop. Never reads account names.
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;

namespace Wpbd {
    public sealed class TokenSnapshot {
        public bool Available;
        public bool? IsElevated;
        public bool? AdministratorGroupPresent;
        public bool? AdministratorGroupEnabled;
        public int? IntegrityRid;
        public string IntegrityLevel = "Unavailable";
        public int? ErrorCode;
        public bool VerifiedHighIntegrityAdministrator {
            get { return Available && IsElevated == true && AdministratorGroupEnabled == true && IntegrityRid >= 0x3000; }
        }
        public bool UnprivilegedDesktop {
            get { return Available && IsElevated == false && IntegrityRid.HasValue && IntegrityRid.Value < 0x3000; }
        }
    }
    public static class WorkerToken {
        [DllImport("advapi32.dll", SetLastError=true)]
        static extern bool GetTokenInformation(IntPtr token, int informationClass, IntPtr data, int size, out int required);
        [DllImport("advapi32.dll")]
        static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
        [DllImport("advapi32.dll")]
        static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);
        static IntPtr Query(IntPtr token, int informationClass) {
            int required;
            GetTokenInformation(token, informationClass, IntPtr.Zero, 0, out required);
            if (required <= 0 || required > 65536) throw new Win32Exception(Marshal.GetLastWin32Error());
            IntPtr data = Marshal.AllocHGlobal(required);
            if (!GetTokenInformation(token, informationClass, data, required, out required)) {
                int error = Marshal.GetLastWin32Error(); Marshal.FreeHGlobal(data); throw new Win32Exception(error);
            }
            return data;
        }
        public static TokenSnapshot ReadCurrent() {
            var result = new TokenSnapshot();
#if NET5_0_OR_GREATER
            if (!OperatingSystem.IsWindows()) return result;
#else
            if (Environment.OSVersion.Platform != PlatformID.Win32NT) return result;
#endif
            try {
                using (var identity = WindowsIdentity.GetCurrent()) {
                    IntPtr elevation = Query(identity.Token, 20); // TokenElevation
                    try { result.IsElevated = Marshal.ReadInt32(elevation) != 0; }
                    finally { Marshal.FreeHGlobal(elevation); }
                    IntPtr integrity = Query(identity.Token, 25); // TokenIntegrityLevel
                    try {
                        IntPtr sid = Marshal.ReadIntPtr(integrity);
                        byte count = Marshal.ReadByte(GetSidSubAuthorityCount(sid));
                        if (count == 0) throw new Win32Exception(1337);
                        int rid = Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)(count - 1)));
                        result.IntegrityRid = rid;
                        result.IntegrityLevel = rid >= 0x4000 ? "System" : rid >= 0x3000 ? "High" : rid >= 0x2000 ? "Medium" : rid >= 0x1000 ? "Low" : "Untrusted";
                    } finally { Marshal.FreeHGlobal(integrity); }
                    if (identity.Groups != null) {
                        result.AdministratorGroupPresent = false;
                        foreach (var group in identity.Groups) if (group.Value == "S-1-5-32-544") result.AdministratorGroupPresent = true;
                    }
                    result.AdministratorGroupEnabled = new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
                    result.Available = true;
                }
            } catch (Win32Exception error) { result.ErrorCode = error.NativeErrorCode; }
              catch (UnauthorizedAccessException) { result.ErrorCode = 5; }
              catch (System.Security.SecurityException) { result.ErrorCode = 5; }
            return result;
        }
    }
}
