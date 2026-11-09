# Erzeugt client/ImgShare/ImgShare.ico (16–256 px) mit demselben Motiv wie
# client/ImgShare/Tray/IconFactory.cs. Nur nötig, wenn sich das Symbol ändert.
#   powershell -ExecutionPolicy Bypass -File tools/make-icon.ps1
Add-Type -AssemblyName System.Drawing
$out = Join-Path $PSScriptRoot '..\client\ImgShare\ImgShare.ico'
$accent = [System.Drawing.Color]::FromArgb(0x0F, 0x5F, 0xA8)

function Draw([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $s = $size / 32.0
    $r = New-Object System.Drawing.RectangleF (2 * $s), (4 * $s), (28 * $s), (24 * $s)
    $d = 10 * $s
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc($r.X, $r.Y, $d, $d, 180, 90)
    $p.AddArc($r.Right - $d, $r.Y, $d, $d, 270, 90)
    $p.AddArc($r.Right - $d, $r.Bottom - $d, $d, $d, 0, 90)
    $p.AddArc($r.X, $r.Bottom - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush $accent), $p)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), (2.4 * $s)
    $pen.LineJoin = 'Round'; $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $pts = @((7, 23), (13, 16), (17, 20), (20, 17), (25, 23)) | ForEach-Object { New-Object System.Drawing.PointF ($_[0] * $s), ($_[1] * $s) }
    $g.DrawLines($pen, [System.Drawing.PointF[]]$pts)
    $g.FillEllipse([System.Drawing.Brushes]::White, 20 * $s, 8 * $s, 4.5 * $s, 4.5 * $s)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return ,$ms.ToArray()
}

$sizes = 16, 20, 24, 32, 40, 48, 64, 256
$images = foreach ($sz in $sizes) { ,(Draw $sz) }
$fs = [System.IO.File]::Create($out)
$w = New-Object System.IO.BinaryWriter $fs
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $sz = $sizes[$i]; $len = $images[$i].Length
    $w.Write([byte]($sz % 256)); $w.Write([byte]($sz % 256))
    $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]$len); $w.Write([uint32]$offset)
    $offset += $len
}
foreach ($img in $images) { $w.Write($img) }
$w.Close()
"geschrieben: $out"
