using System.Threading;
using System.Windows;

namespace GoldPriceBar.Windows;

public partial class App : Application
{
    private Mutex? singleInstanceMutex;
    private EventWaitHandle? activationEvent;
    private RegisteredWaitHandle? activationRegistration;
    private AppController? controller;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        singleInstanceMutex = new Mutex(true, "Local\\GoldPriceBar.Windows.Singleton", out var createdNew);
        if (!createdNew)
        {
            try
            {
                EventWaitHandle.OpenExisting("Local\\GoldPriceBar.Windows.Activate").Set();
            }
            catch (WaitHandleCannotBeOpenedException)
            {
            }
            Shutdown();
            return;
        }

        activationEvent = new EventWaitHandle(
            false,
            EventResetMode.AutoReset,
            "Local\\GoldPriceBar.Windows.Activate");
        controller = await AppController.CreateAsync(Dispatcher);
        controller.Start();
        activationRegistration = ThreadPool.RegisterWaitForSingleObject(
            activationEvent,
            (_, _) => Dispatcher.BeginInvoke(controller.ShowDetails),
            null,
            Timeout.Infinite,
            false);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        controller?.Dispose();
        activationRegistration?.Unregister(null);
        activationEvent?.Dispose();
        singleInstanceMutex?.Dispose();
        base.OnExit(e);
    }
}
