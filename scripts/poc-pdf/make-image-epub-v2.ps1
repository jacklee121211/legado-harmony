# POC 第二轮：验证「一个 xhtml 放多张页图」与「超长页图」的排版行为。
#   CH1: 3 张 A4 比例（1080x1527）图放在**同一个** xhtml → 期望被拆成 3 个阅读页（真实实现靠这个省目录条数）
#   CH2: 1 张超长图（1080x2600）→ 观察是被缩放还是被跨页切开
#   CH3: 1 张 A4 单图 → 对照组
# 用法：pwsh -File scripts/poc-pdf/make-image-epub-v2.ps1
param(
  [string]$OutFile = ""
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $OutFile) { $OutFile = Join-Path $root "entry/src/main/resources/rawfile/poc_pages.epub" }

$work = Join-Path $env:TEMP ("poc_epub2_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$oebps = Join-Path $work "OEBPS"
$imgs = Join-Path $oebps "images"
New-Item -ItemType Directory -Force -Path $oebps, $imgs, (Join-Path $work "META-INF") | Out-Null

Add-Type -AssemblyName System.Drawing
function New-PageImage($path, $w, $h, $label, $sub) {
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
  $g.Clear([System.Drawing.Color]::White)
  $red = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(210, 20, 20), 6)
  $g.DrawRectangle($red, 14, 14, ($w - 29), ($h - 29))
  $fBig = New-Object System.Drawing.Font("Microsoft YaHei", 58, [System.Drawing.FontStyle]::Bold)
  $fMid = New-Object System.Drawing.Font("Microsoft YaHei", 34)
  $fSm  = New-Object System.Drawing.Font("Consolas", 24)
  $blue = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(10, 70, 170))
  $g.DrawString($label, $fBig, $blue, 60, 70)
  $g.DrawString($sub, $fSm, [System.Drawing.Brushes]::Black, 60, 170)
  $g.DrawString("顶部标记 TOP-$label", $fMid, [System.Drawing.Brushes]::Black, 60, 260)
  # 每隔 200px 一条横向刻度，用来判断是否被切开/是否完整
  $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(180, 180, 180), 2)
  for ($y = 400; $y -lt ($h - 200); $y += 200) {
    $g.DrawLine($pen, 40, $y, ($w - 40), $y)
    $g.DrawString("y=$y", $fSm, [System.Drawing.Brushes]::Gray, ($w - 200), ($y - 34))
  }
  $g.DrawString("底部标记 BOTTOM-$label", $fMid, [System.Drawing.Brushes]::Black, 60, ($h - 170))
  $g.Dispose()
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Jpeg)
  $bmp.Dispose()
}

# CH1: 同一 xhtml 里 3 张 A4 比例图
for ($i = 1; $i -le 3; $i++) {
  New-PageImage (Join-Path $imgs "c1_$i.jpg") 1080 1527 "CH1-图$i" "A4 比例 1080x1527 · 同一 xhtml 的第 $i 张"
}
# CH2: 超长图
New-PageImage (Join-Path $imgs "c2_1.jpg") 1080 2600 "CH2-超长图" "1080x2600 · 观察是否被跨页切开"
# CH3: A4 单图
New-PageImage (Join-Path $imgs "c3_1.jpg") 1080 1527 "CH3-A4单图" "A4 比例 1080x1527 · 对照"

Set-Content -Path (Join-Path $work "mimetype") -Value "application/epub+zip" -NoNewline -Encoding utf8
$container = @'
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
'@
Set-Content -Path (Join-Path $work "META-INF/container.xml") -Value $container -Encoding utf8

$css = @'
html, body { margin: 0; padding: 0; background: #ffffff; }
img { width: 100%; height: auto; display: block; margin: 0; padding: 0; }
'@
Set-Content -Path (Join-Path $oebps "style.css") -Value $css -Encoding utf8

$ch1 = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第 1 章</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
<body><img src="images/c1_1.jpg" alt="c1_1"/><img src="images/c1_2.jpg" alt="c1_2"/><img src="images/c1_3.jpg" alt="c1_3"/></body></html>
"@
Set-Content -Path (Join-Path $oebps "ch1.xhtml") -Value $ch1 -Encoding utf8
$ch2 = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第 2 章</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
<body><img src="images/c2_1.jpg" alt="c2_1"/></body></html>
"@
Set-Content -Path (Join-Path $oebps "ch2.xhtml") -Value $ch2 -Encoding utf8
$ch3 = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第 3 章</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
<body><img src="images/c3_1.jpg" alt="c3_1"/></body></html>
"@
Set-Content -Path (Join-Path $oebps "ch3.xhtml") -Value $ch3 -Encoding utf8

$opf = @'
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">urn:uuid:poc-pages-0002</dc:identifier>
    <dc:title>页图 POC v2（多图/超长图）</dc:title>
    <dc:creator>POC</dc:creator>
    <dc:language>zh-CN</dc:language>
    <meta property="dcterms:modified">2026-10-19T00:00:00Z</meta>
    <meta name="cover" content="c1_1"/>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="css" href="style.css" media-type="text/css"/>
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="c3" href="ch3.xhtml" media-type="application/xhtml+xml"/>
    <item id="c1_1" href="images/c1_1.jpg" media-type="image/jpeg"/>
    <item id="c1_2" href="images/c1_2.jpg" media-type="image/jpeg"/>
    <item id="c1_3" href="images/c1_3.jpg" media-type="image/jpeg"/>
    <item id="c2_1" href="images/c2_1.jpg" media-type="image/jpeg"/>
    <item id="c3_1" href="images/c3_1.jpg" media-type="image/jpeg"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="c1"/>
    <itemref idref="c2"/>
    <itemref idref="c3"/>
  </spine>
</package>
'@
Set-Content -Path (Join-Path $oebps "content.opf") -Value $opf -Encoding utf8

$nav = @'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>目录</title></head>
<body><nav epub:type="toc" id="toc"><h1>目录</h1><ol>
  <li><a href="ch1.xhtml">第 1 章（3 张 A4 图）</a></li>
  <li><a href="ch2.xhtml">第 2 章（超长图）</a></li>
  <li><a href="ch3.xhtml">第 3 章（A4 单图）</a></li>
</ol></nav></body></html>
'@
Set-Content -Path (Join-Path $oebps "nav.xhtml") -Value $nav -Encoding utf8

$ncx = @'
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="urn:uuid:poc-pages-0002"/></head>
  <docTitle><text>页图 POC v2</text></docTitle>
  <navMap>
    <navPoint id="n1" playOrder="1"><navLabel><text>第 1 章（3 张 A4 图）</text></navLabel><content src="ch1.xhtml"/></navPoint>
    <navPoint id="n2" playOrder="2"><navLabel><text>第 2 章（超长图）</text></navLabel><content src="ch2.xhtml"/></navPoint>
    <navPoint id="n3" playOrder="3"><navLabel><text>第 3 章（A4 单图）</text></navLabel><content src="ch3.xhtml"/></navPoint>
  </navMap>
</ncx>
'@
Set-Content -Path (Join-Path $oebps "toc.ncx") -Value $ncx -Encoding utf8

if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$fs = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::CreateNew)
$zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
function Add-Entry($zip, $srcPath, $entryName, $level) {
  $e = $zip.CreateEntry($entryName, $level); $es = $e.Open()
  $bytes = [System.IO.File]::ReadAllBytes($srcPath)
  $es.Write($bytes, 0, $bytes.Length); $es.Close()
}
$opt = [System.IO.Compression.CompressionLevel]::Optimal
Add-Entry $zip (Join-Path $work "mimetype") "mimetype" ([System.IO.Compression.CompressionLevel]::NoCompression)
foreach ($f in @("META-INF/container.xml")) { Add-Entry $zip (Join-Path $work $f) $f $opt }
foreach ($f in @("content.opf", "nav.xhtml", "toc.ncx", "style.css", "ch1.xhtml", "ch2.xhtml", "ch3.xhtml")) {
  Add-Entry $zip (Join-Path $oebps $f) "OEBPS/$f" $opt
}
foreach ($f in @("c1_1.jpg", "c1_2.jpg", "c1_3.jpg", "c2_1.jpg", "c3_1.jpg")) {
  Add-Entry $zip (Join-Path $imgs $f) "OEBPS/images/$f" $opt
}
$zip.Dispose(); $fs.Close()

Get-Item $OutFile | Select-Object FullName, Length | Format-List
Remove-Item $work -Recurse -Force
