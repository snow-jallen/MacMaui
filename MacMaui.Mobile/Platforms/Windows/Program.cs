using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using System.Runtime.InteropServices;
using Velopack;

namespace MacMaui.Mobile.WinUI;

/// <summary>
/// The Windows entry point, replacing the one WinUI generates. Enabled by
/// DISABLE_XAML_GENERATED_MAIN in the csproj, and it exists for one reason: Velopack has to
/// run before anything else.
///
/// Velopack drives installs and updates by re-running this same executable with hook arguments
/// such as --veloapp-install. <see cref="VelopackApp.Run"/> handles those and exits the
/// process. If WinUI had already started, each hook would flash a window and pay the whole
/// MAUI startup cost. Putting the call first keeps hooks invisible and fast.
/// </summary>
public static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        VelopackApp.Build().Run();

        WinRT.ComWrappersSupport.InitializeComWrappers();
        // Fully qualified: MAUI's implicit usings also define an Application type.
        Microsoft.UI.Xaml.Application.Start(callbackParams =>
        {
            var context = new DispatcherQueueSynchronizationContext(
                DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            // WinUI keeps hold of the instance; nothing here needs the reference.
            new App();
        });
    }
}
