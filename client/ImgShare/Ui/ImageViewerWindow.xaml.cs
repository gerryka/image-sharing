using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using ImgShare.Core;
using Microsoft.Win32;

namespace ImgShare.Ui;

public partial class ImageViewerWindow : Window
{
    string _fileName = "";
    byte[]? _bytes;
    int _loadId;

    public ImageViewerWindow(Func<Task<byte[]>> load, string fileName)
    {
        InitializeComponent();
        Icon = Tray.IconFactory.CreateImageSource(false);
        SourceInitialized += (_, _) =>
        {
            WindowPlacement.CenterOnOwnerMonitor(this, Owner);
            WindowPlacement.ApplyTitleBarTheme(this, ThemeManager.IsDark);
        };
        ThemeManager.Changed += OnThemeChanged;
        Closed += (_, _) => ThemeManager.Changed -= OnThemeChanged;
        KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Escape) Close(); };
        ShowImage(load, fileName);
    }

    void OnThemeChanged() => WindowPlacement.ApplyTitleBarTheme(this, ThemeManager.IsDark);

    /// <summary>Zeigt ein (anderes) Bild in diesem Fenster an.</summary>
    public async void ShowImage(Func<Task<byte[]>> load, string fileName)
    {
        int id = ++_loadId;
        _fileName = fileName;
        _bytes = null;
        Title = fileName;
        Info.Text = fileName;
        Picture.Source = null;
        Loading.Text = "Bild wird entschlüsselt …";
        Loading.Visibility = Visibility.Visible;
        try
        {
            var bytes = await load();
            var img = await Task.Run(() => ImageHelper.Decode(bytes, ImageHelper.MaxViewEdge));
            if (id != _loadId) return; // inzwischen anderes Bild gewählt
            var (w, h) = ImageHelper.Probe(bytes);
            _bytes = bytes;
            Picture.Source = img;
            Info.Text = $"{_fileName} · {w}×{h} · {ImageFormat.FormatSize(bytes.Length)}";
            Loading.Visibility = Visibility.Collapsed;
        }
        catch (Exception ex)
        {
            if (id == _loadId) Loading.Text = "Bild konnte nicht geladen werden: " + ErrorText.Describe(ex);
        }
    }

    async void Copy_Click(object sender, RoutedEventArgs e)
    {
        if (_bytes is null) return;
        try
        {
            ImageHelper.CopyToClipboard(_bytes);
            CopyButton.Content = "Kopiert";
            await Task.Delay(1500);
            CopyButton.Content = "Kopieren";
        }
        catch (Exception ex) { MessageBox.Show(this, ErrorText.Describe(ex), "Bildsharing"); }
    }

    async void Save_Click(object sender, RoutedEventArgs e)
    {
        if (_bytes is null) return;
        var bytes = _bytes;
        await SaveAsAsync(this, () => Task.FromResult(bytes), _fileName);
    }

    void Close_Click(object sender, RoutedEventArgs e) => Close();

    /// <summary>Speichert das entschlüsselte Bild dort, wo der Benutzer es explizit haben will.</summary>
    public static async Task SaveAsAsync(Window owner, Func<Task<byte[]>> load, string fileName)
    {
        try
        {
            var bytes = await load();
            var mime = ImageFormat.DetectMime(bytes) ?? throw new InvalidDataException("Kein gültiges Bild.");
            // Endung immer passend zum echten Format, Name bereinigt
            var safe = ImageFormat.SafeFileName(fileName, mime);
            var dlg = new SaveFileDialog
            {
                FileName = safe,
                DefaultExt = Path.GetExtension(safe),
                AddExtension = true,
                Filter = mime == "image/png" ? "PNG-Bild (*.png)|*.png" : "JPG-Bild (*.jpg)|*.jpg",
                Title = "Bild speichern"
            };
            if (dlg.ShowDialog(owner) != true) return;
            await File.WriteAllBytesAsync(dlg.FileName, bytes);
        }
        catch (Exception ex) { MessageBox.Show(owner, ErrorText.Describe(ex), "Bildsharing"); }
    }
}
