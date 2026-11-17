using System.Collections.Specialized;
using System.Globalization;
using System.Windows;
using System.Windows.Media;
using WPBD.Core;

namespace WPBD.Desktop;

public enum ChartMetric { Cpu, Memory, Available, Disk }

public sealed class MetricChart : FrameworkElement
{
    public static readonly DependencyProperty SamplesProperty = DependencyProperty.Register(nameof(Samples),
        typeof(IEnumerable<Sample>), typeof(MetricChart), new FrameworkPropertyMetadata(null,
            FrameworkPropertyMetadataOptions.AffectsRender, OnSamplesChanged));
    public static readonly DependencyProperty MetricProperty = DependencyProperty.Register(nameof(Metric),
        typeof(ChartMetric), typeof(MetricChart), new FrameworkPropertyMetadata(ChartMetric.Cpu, FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty CursorIndexProperty = DependencyProperty.Register(nameof(CursorIndex),
        typeof(int), typeof(MetricChart), new FrameworkPropertyMetadata(0, FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty LineBrushProperty = DependencyProperty.Register(nameof(LineBrush),
        typeof(Brush), typeof(MetricChart), new FrameworkPropertyMetadata(Brushes.LightBlue, FrameworkPropertyMetadataOptions.AffectsRender));

    public IEnumerable<Sample>? Samples { get => (IEnumerable<Sample>?)GetValue(SamplesProperty); set => SetValue(SamplesProperty, value); }
    public ChartMetric Metric { get => (ChartMetric)GetValue(MetricProperty); set => SetValue(MetricProperty, value); }
    public int CursorIndex { get => (int)GetValue(CursorIndexProperty); set => SetValue(CursorIndexProperty, value); }
    public Brush LineBrush { get => (Brush)GetValue(LineBrushProperty); set => SetValue(LineBrushProperty, value); }

    private static readonly Brush Label = (Brush)new BrushConverter().ConvertFromString("#B7C4D5")!;
    private static readonly Pen GridPen = new((Brush)new BrushConverter().ConvertFromString("#293A50")!, 1);
    private static readonly Pen CursorPen = new((Brush)new BrushConverter().ConvertFromString("#7286A3")!, 1) { DashStyle = DashStyles.Dash };
    private static readonly Typeface Typeface = new("Segoe UI");

    protected override void OnRender(DrawingContext drawing)
    {
        base.OnRender(drawing);
        if (ActualWidth < 100 || ActualHeight < 70) return;
        var samples = Samples?.ToArray() ?? [];
        var values = samples.Select(Value).ToArray();
        var width = ActualWidth - 63;
        var height = ActualHeight - 34;
        var rect = new Rect(45, 7, width, height);
        var maxTime = Math.Max(1, samples.LastOrDefault()?.ElapsedSeconds ?? 1);
        var highest = values.Max() ?? 0;
        var maxValue = Metric is ChartMetric.Cpu or ChartMetric.Memory ? 100 : AxisMaximum(highest);

        for (var tick = 0; tick <= 4; tick++)
        {
            var y = rect.Top + rect.Height * tick / 4;
            drawing.DrawLine(GridPen, new Point(rect.Left, y), new Point(rect.Right, y));
            var label = Text((maxValue * (4 - tick) / 4).ToString("0.##"));
            drawing.DrawText(label, new Point(rect.Left - label.Width - 6, y - label.Height / 2));
        }
        drawing.DrawText(Text("0 s"), new Point(rect.Left, rect.Bottom + 5));
        var endLabel = Text($"{maxTime:0.#} s");
        drawing.DrawText(endLabel, new Point(rect.Right - endLabel.Width, rect.Bottom + 5));

        if (values.All(value => value is null))
        {
            var caption = Text(samples.Length == 0 ? "Waiting for samples" : "Measurement unavailable");
            drawing.DrawText(caption, new Point(rect.Left + (rect.Width - caption.Width) / 2, rect.Top + (rect.Height - caption.Height) / 2));
            return;
        }

        var line = new Pen(LineBrush, 2);
        Point? previous = null;
        int previousSlot = 0;
        for (var index = 0; index < samples.Length; index++)
        {
            var sample = samples[index];
            var x = rect.Left + rect.Width * Math.Clamp(sample.ElapsedSeconds / maxTime, 0, 1);
            if (index == CursorIndex) drawing.DrawLine(CursorPen, new Point(x, rect.Top), new Point(x, rect.Bottom));
            if (values[index] is not double value) { previous = null; continue; }
            var point = new Point(x, rect.Bottom - rect.Height * Math.Clamp(value / maxValue, 0, 1));
            if (previous is Point start && sample.Slot == previousSlot + 1)
                drawing.DrawLine(line, start, point);
            else drawing.DrawEllipse(LineBrush, null, point, 2, 2);
            if (index == CursorIndex) drawing.DrawEllipse(LineBrush, null, point, 4, 4);
            previous = point;
            previousSlot = sample.Slot;
        }
    }

    private double? Value(Sample sample) => Metric switch
    {
        ChartMetric.Cpu => sample.CpuPercent,
        ChartMetric.Memory => sample.MemoryPercent,
        ChartMetric.Available => sample.AvailableBytes / 1073741824,
        _ => sample.PeakDiskLatency
    };

    private static double AxisMaximum(double highest)
    {
        if (highest <= 0) return 1;
        var magnitude = Math.Pow(10, Math.Floor(Math.Log10(highest)));
        return Math.Ceiling(highest / magnitude) * magnitude;
    }

    private FormattedText Text(string value) => new(value, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, Typeface,
        11, Label, VisualTreeHelper.GetDpi(this).PixelsPerDip);

    private static void OnSamplesChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args)
    {
        var chart = (MetricChart)sender;
        if (args.OldValue is INotifyCollectionChanged before)
            CollectionChangedEventManager.RemoveHandler(before, chart.OnCollectionChanged);
        if (args.NewValue is INotifyCollectionChanged after)
            CollectionChangedEventManager.AddHandler(after, chart.OnCollectionChanged);
    }

    private void OnCollectionChanged(object? sender, NotifyCollectionChangedEventArgs args) => InvalidateVisual();
}
