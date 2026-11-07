using System;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Media;
using Microsoft.Win32;

namespace ImgShare.Ui;

public sealed class InverseBoolToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type t, object p, CultureInfo c) => value is true ? Visibility.Collapsed : Visibility.Visible;
    public object ConvertBack(object value, Type t, object p, CultureInfo c) => throw new NotSupportedException();
}

public sealed class EmptyToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type t, object p, CultureInfo c) =>
        string.IsNullOrEmpty(value as string) ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type t, object p, CultureInfo c) => throw new NotSupportedException();
}

/// <summary>Breite × Faktor (z. B. Sprechblasen max. 78 % der Listenbreite).</summary>
public sealed class RatioConverter : IValueConverter
{
    public object Convert(object value, Type t, object p, CultureInfo c) =>
        value is double d ? Math.Max(120, d * double.Parse((string)p, CultureInfo.InvariantCulture)) : 300.0;
    public object ConvertBack(object value, Type t, object p, CultureInfo c) => throw new NotSupportedException();
}

/// <summary>Folgt dem Hell/Dunkel-Modus von Windows.</summary>
public static class ThemeManager
{
    public static bool IsDark { get; private set; }
    public static event Action? Changed;

    public static void Init()
    {
        Apply();
        SystemEvents.UserPreferenceChanged += (_, e) =>
        {
            if (e.Category == UserPreferenceCategory.General)
                Application.Current.Dispatcher.BeginInvoke(Apply);
        };
    }

    static bool ReadSystemDark()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return k?.GetValue("AppsUseLightTheme") is int v && v == 0;
        }
        catch { return false; }
    }

    static void Apply()
    {
        var dark = ReadSystemDark();
        var dicts = Application.Current.Resources.MergedDictionaries;
        var uri = new Uri(dark ? "Themes/Dark.xaml" : "Themes/Light.xaml", UriKind.Relative);
        var current = dicts.FirstOrDefault(d => d.Source?.OriginalString.StartsWith("Themes/Light") == true
                                             || d.Source?.OriginalString.StartsWith("Themes/Dark") == true);
        if (current is not null && current.Source == uri) { IsDark = dark; return; }
        var index = current is null ? 0 : dicts.IndexOf(current);
        if (current is not null) dicts.Remove(current);
        dicts.Insert(index, new ResourceDictionary { Source = uri });
        IsDark = dark;
        Changed?.Invoke();
    }
}
