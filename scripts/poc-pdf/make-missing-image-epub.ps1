# POC 第三轮：验证「xhtml 引用的图片不在 zip 里」时，排版引擎会不会走 on('resourceRequest') 向应用要。
#   若会 → 可以做"虚拟 epub"（骨架里没有图，按需渲染/缓存后同步返回字节），不必往 zip 里塞几十 MB 图；
#   若不会 → 必须把页图打进 zip（需要自写 stored-only ZIP 写入器，或验证 zlib.compressFiles 产物能被 ReaderKit 接受）。
#   CH1: href=images/missing1.jpg（不在 zip、也不在 manifest）
#   CH2: href=images/missing2.jpg（在 manifest 里声明了，但 zip 里没有实体）
# 用法：pwsh -File scripts/poc-pdf/make-missing-image-epub.ps1
param([string]$OutFile = "")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $OutFile) { $OutFile = Join-Path $root "entry/src/main/resources/rawfile/poc_pages.epub" }

$work = Join-Path $env:TEMP ("poc_epub3_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$oebps = Join-Path $work "OEBPS"
New-Item -ItemType Directory -Force -Path $oebps, (Join-Path $work "META-INF") | Out-Null

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
img { width: 100%; height: auto; display: block; }
'@
Set-Content -Path (Join-Path $oebps "style.css") -Value $css -Encoding utf8

$ch1 = @'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第 1 章</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
<body><p>本章 3 张图都不在 zip 里（也不在 manifest）：看引擎是"一次性索取整章"还是"逐页索取"。</p>
<img src="images/missing1.jpg" alt="missing1"/><img src="images/missing2.jpg" alt="missing2"/><img src="images/missing3.jpg" alt="missing3"/></body></html>
'@
Set-Content -Path (Join-Path $oebps "ch1.xhtml") -Value $ch1 -Encoding utf8
$ch2 = @'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第 2 章</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
<body><p>本章图片在 manifest 里声明了，但 zip 里没有实体。</p>
<img src="images/missing2.jpg" alt="missing2"/></body></html>
'@
Set-Content -Path (Join-Path $oebps "ch2.xhtml") -Value $ch2 -Encoding utf8

$opf = @'
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">urn:uuid:poc-pages-0003</dc:identifier>
    <dc:title>虚拟 epub POC v3（缺图）</dc:title>
    <dc:creator>POC</dc:creator>
    <dc:language>zh-CN</dc:language>
    <meta property="dcterms:modified">2026-10-19T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="css" href="style.css" media-type="text/css"/>
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="m2" href="images/missing2.jpg" media-type="image/jpeg"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="c1"/>
    <itemref idref="c2"/>
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
  <li><a href="ch1.xhtml">第 1 章（缺图·未声明）</a></li>
  <li><a href="ch2.xhtml">第 2 章（缺图·已声明）</a></li>
</ol></nav></body></html>
'@
Set-Content -Path (Join-Path $oebps "nav.xhtml") -Value $nav -Encoding utf8

$ncx = @'
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="urn:uuid:poc-pages-0003"/></head>
  <docTitle><text>虚拟 epub POC v3</text></docTitle>
  <navMap>
    <navPoint id="n1" playOrder="1"><navLabel><text>第 1 章（缺图·未声明）</text></navLabel><content src="ch1.xhtml"/></navPoint>
    <navPoint id="n2" playOrder="2"><navLabel><text>第 2 章（缺图·已声明）</text></navLabel><content src="ch2.xhtml"/></navPoint>
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
  $bytes = [System.IO.File]::ReadAllBytes($srcPath); $es.Write($bytes, 0, $bytes.Length); $es.Close()
}
$opt = [System.IO.Compression.CompressionLevel]::Optimal
Add-Entry $zip (Join-Path $work "mimetype") "mimetype" ([System.IO.Compression.CompressionLevel]::NoCompression)
Add-Entry $zip (Join-Path $work "META-INF/container.xml") "META-INF/container.xml" $opt
foreach ($f in @("content.opf", "nav.xhtml", "toc.ncx", "style.css", "ch1.xhtml", "ch2.xhtml")) {
  Add-Entry $zip (Join-Path $oebps $f) "OEBPS/$f" $opt
}
$zip.Dispose(); $fs.Close()
Get-Item $OutFile | Select-Object FullName, Length | Format-List
Remove-Item $work -Recurse -Force
