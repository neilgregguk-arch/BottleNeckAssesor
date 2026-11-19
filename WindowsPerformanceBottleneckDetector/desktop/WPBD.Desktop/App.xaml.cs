using System.Reflection;
using System.Threading;
using System.Windows;

namespace WPBD.Desktop;

public partial class App : Application
{
    // Setup and Uninstall use this same name to wait for the app and its diagnostic to close.
    private static readonly Mutex InstallationGuard = new(false, "WPBD.Desktop.InstallationGuard");

    internal static string ProductVersion { get; } = typeof(App).Assembly
        .GetCustomAttribute<AssemblyInformationalVersionAttribute>()!.InformationalVersion;

    protected override void OnStartup(StartupEventArgs e)
    {
        var token = Wpbd.WorkerToken.ReadCurrent();
        if (!token.UnprivilegedDesktop)
        {
            MessageBox.Show("Start WPBD normally under your signed-in user. The desktop interface must run without administrator privileges.",
                "WPBD desktop permissions", MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }
        GC.KeepAlive(InstallationGuard);
        base.OnStartup(e);
    }
}
