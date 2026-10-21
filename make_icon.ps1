# 生成电池充电风格应用图标（.ico 多尺寸）
param([string]$OutIco = "$PSScriptRoot\app.ico")
Add-Type -AssemblyName System.Drawing

function New-RoundedPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$rad) {
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 2 * $rad
    $gp.AddArc($x, $y, $d, $d, 180, 90)
    $gp.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $gp.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $gp.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $gp.CloseFigure()
    return $gp
}

function New-IconBitmap([int]$S) {
    $bmp = New-Object System.Drawing.Bitmap($S, $S)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    # 深色渐变圆角底板
    $pad = [single](0.045 * $S); $rad = [single](0.22 * $S)
    $bgRect = New-Object System.Drawing.RectangleF($pad, $pad, ($S - 2*$pad - 1), ($S - 2*$pad - 1))
    $bg = New-RoundedPath $bgRect.X $bgRect.Y $bgRect.Width $bgRect.Height $rad
    $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($bgRect, [System.Drawing.Color]::FromArgb(255, 0x27, 0x2E, 0x44), [System.Drawing.Color]::FromArgb(255, 0x11, 0x14, 0x1D), 65.0)
    $g.FillPath($lg, $bg)
    $penBg = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 0x3E, 0x46, 0x60), [single][math]::Max(1.0, $S / 110.0))
    $g.DrawPath($penBg, $bg)

    # 电池本体（横放，右侧触点）
    $bx = [single](0.17 * $S); $by = [single](0.335 * $S)
    $bw = [single](0.585 * $S); $bh = [single](0.33 * $S)
    $body = New-RoundedPath $bx $by $bw $bh ([single](0.055 * $S))
    $penB = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 0xE9, 0xED, 0xF5), [single][math]::Max(1.5, $S / 85.0))
    $g.DrawPath($penB, $body)
    $nub = New-RoundedPath ([single](0.775 * $S)) ([single](0.445 * $S)) ([single](0.05 * $S)) ([single](0.11 * $S)) ([single](0.02 * $S))
    $nubBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 0xE9, 0xED, 0xF5))
    $g.FillPath($nubBrush, $nub)

    # 绿色电量填充（约74%）
    $ip = [single](0.03 * $S)
    $iw = ($bw - 2*$ip) * 0.74; $ih = $bh - 2*$ip
    $fillRect = New-Object System.Drawing.RectangleF(($bx + $ip), ($by + $ip), $iw, $ih)
    $fill = New-RoundedPath $fillRect.X $fillRect.Y $fillRect.Width $fillRect.Height ([single](0.018 * $S))
    $fg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($fillRect, [System.Drawing.Color]::FromArgb(255, 0x3B, 0xDF, 0x8B), [System.Drawing.Color]::FromArgb(255, 0x15, 0xA0, 0x59), 45.0)
    $g.FillPath($fg, $fill)

    # 白色闪电符号（充电）
    $pts = New-Object System.Drawing.PointF[] 7
    $pts[0] = New-Object System.Drawing.PointF ([single]($bx + $bw*0.55)), ([single]($by + $bh*0.06))
    $pts[1] = New-Object System.Drawing.PointF ([single]($bx + $bw*0.27)), ([single]($by + $bh*0.62))
    $pts[2] = New-Object System.Drawing.PointF ([single]($bx + $bw*0.46)), ([single]($by + $bh*0.62))
    $pts[3] = New-Object System.Drawing.PointF ([single]($bx + $bw*0.39)), ([single]($by + $bh*0.94))
    $pts[4] = New-Object System.Drawing.PointF ([single]($bx + $bw*0.74)), ([single]($by + $bh*0.36))
    $pts[5] = New-Object System.Drawing.PointF ([single]($bx + $bw*0.53)), ([single]($by + $bh*0.36))
    $pts[6] = New-Object System.Drawing.PointF ([single]($bx + $bw*0.65)), ([single]($by + $bh*0.06))
    $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $g.FillPolygon($white, $pts)

    $g.Dispose()
    return $bmp
}

# 生成 ICO（PNG 压缩条目，Vista+ 全兼容）
$sizes = @(256, 64, 48, 32, 16)
$blobs = New-Object System.Collections.Generic.List[byte[]]
foreach ($s in $sizes) {
    $bmp = New-IconBitmap $s
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $blobs.Add($ms.ToArray())
    $ms.Dispose(); $bmp.Dispose()
}
$fs = [IO.File]::Create($OutIco)
$bw2 = New-Object System.IO.BinaryWriter($fs)
$bw2.Write([uint16]0); $bw2.Write([uint16]1); $bw2.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $b = $blobs[$i]
    $dim = if ($s -ge 256) { [byte]0 } else { [byte]$s }
    $bw2.Write($dim); $bw2.Write($dim); $bw2.Write([byte]0); $bw2.Write([byte]0)
    $bw2.Write([uint16]1); $bw2.Write([uint16]32)
    $bw2.Write([uint32]$b.Length); $bw2.Write([uint32]$offset)
    $offset += $b.Length
}
foreach ($b in $blobs) { $bw2.Write($b) }
$bw2.Close(); $fs.Close()
"icon -> $OutIco ($((Get-Item $OutIco).Length) bytes, entries: $($sizes -join ','))"
