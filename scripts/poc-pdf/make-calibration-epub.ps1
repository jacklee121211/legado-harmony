# 标定实验：同一张图渲成 3 种宽度（1080 / 1320 / 1600），各占一章，
# 用来判定 ReaderKit 是否会"把宽于视口的页图缩小"，以及缩小比例与像素宽度的关系。
# 用法：pwsh -File scripts/poc-pdf/make-calibration-epub.ps1
param([string]$OutFile = "")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $OutFile) { $OutFile = Join-Path $root "entry/src/main/resources/rawfile/poc_pages.epub" }

$work = Join-Path $env:TEMP ("poc_cal_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$oebps = Join-Path $work "OEBPS"
$imgs = Join-Path $oebps "images"
New-Item -ItemType Directory -Force -Path $oebps, $imgs, (Join-Path $work "META-INF") | Out-Null

Add-Type -AssemblyName System.Drawing
$specs = @(@{n=1; w=1080}, @{n=2; w=1320}, @{n=3; w=1600})
foreach ($s in $specs) {
  $w = $s.w
  $h = [int]($w * 1.5)
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::White)
  $red = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(210, 20, 20), 8)
  $g.DrawRectangle($red, 6, 6, ($w - 13), ($h - 13))
  $f = New-Object System.Drawing.Font("Microsoft YaHei", 46, [System.Drawing.FontStyle]::Bold)
  $g.DrawString("W=${w}px", $f, [System.Drawing.Brushes]::Black, 60, 60)
  $g.DrawString("页面 ${w} 宽", $f, [System.Drawing.Brushes]::Black, 60, ($h / 2))
  $g.DrawString("底边 BOTTOM", $f, [System.Drawing.Brushes]::Black, 60, ($h - 200))
  $g.Dispose()
  $bmp.Save((Join-Path $imgs "w$w.jpg"), [System.Drawing.Imaging.ImageFormat]::Jpeg)
  $bmp.Dispose()
}

Set-Content -Path (Join-Path $work "mimetype") -Value "application/epub+zip" -NoNewline -Encoding utf8
$container = @'
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
'@
Set-Content -Path (Join-Path $work "META-INF/container.xml") -Value $container -Encoding utf8
Set-Content -Path (Join-Path $oebps "style.css") -Value "html,body{margin:0;padding:0;background:#fff;}img{display:block;margin:0;padding:0;}" -Encoding utf8

$manifest = New-Object System.Text.StringBuilder
$spine = New-Object System.Text.StringBuilder
$navLis = New-Object System.Text.StringBuilder
$navPts = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt 3; $i++) {
  $w = $specs[$i].w
  $xhtml = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>W$w</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
<body><img src="images/w$w.jpg" alt="w$w"/></body></html>
"@
  Set-Content -Path (Join-Path $oebps "c$($i+1).xhtml") -Value $xhtml -Encoding utf8
  [void]$manifest.AppendLine("    <item id=`"c$($i+1)`" href=`"c$($i+1).xhtml`" media-type=`"application/xhtml+xml`"/>")
  [void]$manifest.AppendLine("    <item id=`"i$($i+1)`" href=`"images/w$w.jpg`" media-type=`"image/jpeg`"/>")
  [void]$spine.AppendLine("    <itemref idref=`"c$($i+1)`"/>")
  [void]$navLis.AppendLine("      <li><a href=`"c$($i+1).xhtml`">W=$w</a></li>")
  [void]$navPts.AppendLine("    <navPoint id=`"n$($i+1)`" playOrder=`"$($i+1)`"><navLabel><text>W=$w</text></navLabel><content src=`"c$($i+1).xhtml`"/></navPoint>")
}

$opf = @"
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">urn:uuid:cal-0001</dc:identifier>
    <dc:title>页图标定 W1080/W1320/W1600</dc:title>
    <dc:creator>POC</dc:creator>
    <dc:language>zh-CN</dc:language>
    <meta property="dcterms:modified">2026-10-19T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="css" href="style.css" media-type="text/css"/>
$($manifest.ToString().TrimEnd())
  </manifest>
  <spine toc="ncx">
$($spine.ToString().TrimEnd())
  </spine>
</package>
"@
Set-Content -Path (Join-Path $oebps "content.opf") -Value $opf -Encoding utf8
$nav = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>目录</title></head><body><nav epub:type="toc" id="toc"><h1>目录</h1><ol>
$($navLis.ToString().TrimEnd())
</ol></nav></body></html>
"@
Set-Content -Path (Join-Path $oebps "nav.xhtml") -Value $nav -Encoding utf8
$ncx = @"
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="urn:uuid:cal-0001"/></head><docTitle><text>标定</text></docTitle><navMap>
$($navPts.ToString().TrimEnd())
  </navMap></ncx>
"@
Set-Content -Path (Join-Path $oebps "toc.ncx") -Value $ncx -Encoding utf8

if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$fs = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::CreateNew)
$zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
function Add-E($zip, $src, $name, $lvl) { $e=$zip.CreateEntry($name,$lvl); $s=$e.Open(); $b=[System.IO.File]::ReadAllBytes($src); $s.Write($b,0,$b.Length); $s.Close() }
Add-E $zip (Join-Path $work "mimetype") "mimetype" ([System.IO.Compression.CompressionLevel]::NoCompression)
Add-E $zip (Join-Path $work "META-INF/container.xml") "META-INF/container.xml" ([System.IO.Compression.CompressionLevel]::Optimal)
foreach ($f in @("content.opf","nav.xhtml","toc.ncx","style.css","c1.xhtml","c2.xhtml","c3.xhtml")) { Add-E $zip (Join-Path $oebps $f) "OEBPS/$f" ([System.IO.Compression.CompressionLevel]::Optimal) }
foreach ($w in @(1080,1320,1600)) { Add-E $zip (Join-Path $imgs "w$w.jpg") "OEBPS/images/w$w.jpg" ([System.IO.Compression.CompressionLevel]::Optimal) }
$zip.Dispose(); $fs.Close()
Get-Item $OutFile | Select-Object FullName, Length | Format-List
Remove-Item $work -Recurse -Force
