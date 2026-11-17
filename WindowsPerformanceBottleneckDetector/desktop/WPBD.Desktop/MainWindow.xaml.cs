using System.ComponentModel;
using System.Windows;

namespace WPBD.Desktop;

public partial class MainWindow : Window
{
    private readonly MainViewModel _viewModel = new();
    private bool _closing;

    public MainWindow()
    {
        InitializeComponent();
        DataContext = _viewModel;
        _viewModel.Initialize();
    }

    protected override async void OnClosing(CancelEventArgs e)
    {
        base.OnClosing(e);
        if (e.Cancel || !_viewModel.IsRunning) return;
        e.Cancel = true;
        if (_closing) return;
        _closing = true;
        try
        {
            await _viewModel.FinishClosingAsync();
            Close();
        }
        finally { _closing = false; }
    }

    protected override void OnClosed(EventArgs e)
    {
        _viewModel.SavePreferences();
        base.OnClosed(e);
    }
}
