# 生成一个「页图版 epub」用于 POC：验证 ReaderKit 能否把 PDF 渲染出的页面图当书页排版。
# 结构：mimetype(首个且不压缩) + META-INF/container.xml + OEBPS/{content.opf,nav.xhtml,toc.ncx,style.css,p1..p3.xhtml,images/p1..p3.jpg}
# 用法：pwsh -File scripts/poc-pdf/make-image-epub.ps1 [-Pages 3] [-OutFile <path>]
param(
  [int]$Pages = 3,
  [string]$OutFile = "",
  [int]$ImgWidth = 1080,
  [int]$ImgRatioH = 1620
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $OutFile) { $OutFile = Join-Path $root "entry/src/main/resources/rawfile/poc_pages.epub" }

$work = Join-Path $env:TEMP ("poc_epub_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$oebps = Join-Path $work "OEBPS"
$imgs = Join-Path $oebps "images"
New-Item -ItemType Directory -Force -Path $oebps, $imgs, (Join-Path $work "META-INF") | Out-Null

# ---------- 1. 画页面图（白底黑字 + 红色边框，方便看"图像边界 vs 阅读器背景"） ----------
Add-Type -AssemblyName System.Drawing
for ($i = 1; $i -le $Pages; $i++) {
  $bmp = New-Object System.Drawing.Bitmap($ImgWidth, $ImgRatioH)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
  $g.Clear([System.Drawing.Color]::White)

  $red = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(220, 30, 30), 6)
  $g.DrawRectangle($red, 18, 18, ($ImgWidth - 37), ($ImgRatioH - 37))

  $fTitle = New-Object System.Drawing.Font("Microsoft YaHei", 64, [System.Drawing.FontStyle]::Bold)
  $fBody  = New-Object System.Drawing.Font("Microsoft YaHei", 30)
  $fSmall = New-Object System.Drawing.Font("Consolas", 22)
  $black = [System.Drawing.Brushes]::Black
  $blue  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(20, 60, 160))

  $g.DrawString("页图 POC — 第 $i 页", $fTitle, $blue, 60, 90)
  $g.DrawString("PAGE $i of $Pages", $fSmall, $black, 60, 210)
  $g.DrawString("这张图是「PDF 页面渲染结果」的替身：", $fBody, $black, 60, 300)
  $g.DrawString("宽 ${ImgWidth}px / 高 ${ImgRatioH}px，白底黑字 + 红色边框。", $fBody, $black, 60, 370)
  $g.DrawString("若阅读器把它整页放大/缩小铺满内容区，", $fBody, $black, 60, 440)
  $g.DrawString("说明「PDF 页图 → epub 页图」这条路成立。", $fBody, $black, 60, 510)
  $g.DrawString("检验点：", $fTitle, $blue, 60, 640)
  $g.DrawString("1) 红框是否完整可见（未被裁切）", $fBody, $black, 60, 760)
  $g.DrawString("2) 上图/下图有没有被跨页切开", $fBody, $black, 60, 830)
  $g.DrawString("3) 页边距是否由阅读器主题控制", $fBody, $black, 60, 900)
  $g.DrawString("4) 目录里是否有 3 条（第 1~3 页）", $fBody, $black, 60, 970)
  # 上下标尺：用于判断是否被裁切
  for ($y = 60; $y -lt $ImgRatioH - 40; $y += 120) {
    $g.DrawString(("y=" + $y), $fSmall, [System.Drawing.Brushes]::Gray, $ImgWidth - 190, $y)
  }
  $g.DrawString("本页结束 / END OF PAGE $i", $fBody, $black, 60, ($ImgRatioH - 130))
  $g.Dispose()
  $bmp.Save((Join-Path $imgs ("p$i.jpg")), [System.Drawing.Imaging.ImageFormat]::Jpeg)
  $bmp.Dispose()
}

# ---------- 2. 写 epub 结构 ----------
Set-Content -Path (Join-Path $work "mimetype") -Value "application/epub+zip" -NoNewline -Encoding utf8

$container = @'
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
'@
Set-Content -Path (Join-Path $work "META-INF/container.xml") -Value $container -Encoding utf8

$css = @'
html, body { margin: 0; padding: 0; background: #ffffff; }
.page { margin: 0; padding: 0; text-align: center; }
.page img { width: 100%; height: auto; display: block; }
'@
Set-Content -Path (Join-Path $oebps "style.css") -Value $css -Encoding utf8

$manifestItems = New-Object System.Text.StringBuilder
$spineItems = New-Object System.Text.StringBuilder
$navLis = New-Object System.Text.StringBuilder
$ncps = New-Object System.Text.StringBuilder
for ($i = 1; $i -le $Pages; $i++) {
  $xhtml = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>第 $i 页</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
<body><div class="page"><img src="images/p$i.jpg" alt="page $i"/></div></body>
</html>
"@
  Set-Content -Path (Join-Path $oebps "p$i.xhtml") -Value $xhtml -Encoding utf8
  [void]$manifestItems.AppendLine("    <item id=`"page$i`" href=`"p$i.xhtml`" media-type=`"application/xhtml+xml`"/>")
  [void]$manifestItems.AppendLine("    <item id=`"img$i`" href=`"images/p$i.jpg`" media-type=`"image/jpeg`"/>")
  [void]$spineItems.AppendLine("    <itemref idref=`"page$i`"/>")
  [void]$navLis.AppendLine("      <li><a href=`"p$i.xhtml`">第 $i 页</a></li>")
  [void]$ncps.AppendLine("    <navPoint id=`"np$i`" playOrder=`"$i`"><navLabel><text>第 $i 页</text></navLabel><content src=`"p$i.xhtml`"/></navPoint>")
}

$opf = @"
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">urn:uuid:poc-pages-0001</dc:identifier>
    <dc:title>页图 POC（PDF 页图替身）</dc:title>
    <dc:creator>POC</dc:creator>
    <dc:language>zh-CN</dc:language>
    <meta property="dcterms:modified">2026-10-19T00:00:00Z</meta>
    <meta name="cover" content="img1"/>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="css" href="style.css" media-type="text/css"/>
$($manifestItems.ToString().TrimEnd())
  </manifest>
  <spine toc="ncx">
$($spineItems.ToString().TrimEnd())
  </spine>
</package>
"@
Set-Content -Path (Join-Path $oebps "content.opf") -Value $opf -Encoding utf8

$nav = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>目录</title></head>
<body><nav epub:type="toc" id="toc"><h1>目录</h1><ol>
$($navLis.ToString().TrimEnd())
</ol></nav></body>
</html>
"@
Set-Content -Path (Join-Path $oebps "nav.xhtml") -Value $nav -Encoding utf8

$ncx = @"
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="urn:uuid:poc-pages-0001"/></head>
  <docTitle><text>页图 POC</text></docTitle>
  <navMap>
$($ncps.ToString().TrimEnd())
  </navMap>
</ncx>
"@
Set-Content -Path (Join-Path $oebps "toc.ncx") -Value $ncx -Encoding utf8

# ---------- 3. 打包：mimetype 必须第一个且不压缩 ----------
if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$fs = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::CreateNew)
$zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
function Add-Entry($zip, $srcPath, $entryName, $level) {
  $e = $zip.CreateEntry($entryName, $level)
  $es = $e.Open()
  $bytes = [System.IO.File]::ReadAllBytes($srcPath)
  $es.Write($bytes, 0, $bytes.Length)
  $es.Close()
}
Add-Entry $zip (Join-Path $work "mimetype") "mimetype" ([System.IO.Compression.CompressionLevel]::NoCompression)
Add-Entry $zip (Join-Path $work "META-INF/container.xml") "META-INF/container.xml" ([System.IO.Compression.CompressionLevel]::Optimal)
Add-Entry $zip (Join-Path $oebps "content.opf") "OEBPS/content.opf" ([System.IO.Compression.CompressionLevel]::Optimal)
Add-Entry $zip (Join-Path $oebps "nav.xhtml") "OEBPS/nav.xhtml" ([System.IO.Compression.CompressionLevel]::Optimal)
Add-Entry $zip (Join-Path $oebps "toc.ncx") "OEBPS/toc.ncx" ([System.IO.Compression.CompressionLevel]::Optimal)
Add-Entry $zip (Join-Path $oebps "style.css") "OEBPS/style.css" ([System.IO.Compression.CompressionLevel]::Optimal)
for ($i = 1; $i -le $Pages; $i++) {
  Add-Entry $zip (Join-Path $oebps "p$i.xhtml") "OEBPS/p$i.xhtml" ([System.IO.Compression.CompressionLevel]::Optimal)
  Add-Entry $zip (Join-Path $imgs "p$i.jpg") "OEBPS/images/p$i.jpg" ([System.IO.Compression.CompressionLevel]::Optimal)
}
$zip.Dispose(); $fs.Close()

# ---------- 4. 自检 ----------
Write-Output "=== 产物 ==="
Get-Item $OutFile | Select-Object FullName, Length | Format-List
$z2 = [System.IO.Compression.ZipFile]::OpenRead($OutFile)
Write-Output "=== 条目（顺序即写入顺序，mimetype 必须第一个且 CompressedLength=Length） ==="
$z2.Entries | Select-Object FullName, Length, CompressedLength | Format-Table -AutoSize
$z2.Dispose()
Remove-Item $work -Recurse -Force
