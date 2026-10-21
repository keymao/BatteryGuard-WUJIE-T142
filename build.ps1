# 编译 BatteryGuard.exe（单文件 WinForms，内嵌 InpOut 驱动 DLL）
$ErrorActionPreference = 'Stop'
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw "csc.exe not found: $csc" }

# 源文件 BOM（中文内容必须 UTF-8 BOM 才能被 csc 正确读取）
$srcFiles = Get-ChildItem "$PSScriptRoot\src\*.cs" | ForEach-Object { $_.FullName }
foreach ($f in $srcFiles) {
    $c = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($f, $c, (New-Object Text.UTF8Encoding $true))
}

$ico = "$PSScriptRoot\app.ico"
$out = Join-Path $PSScriptRoot "BatteryGuard.exe"

$argList = @(
    '/nologo', '/target:winexe', '/platform:anycpu',
    "/out:$out", "/win32icon:$ico",
    '/r:System.dll', '/r:System.Core.dll',
    '/r:System.Windows.Forms.dll', '/r:System.Drawing.dll',
    '/r:System.Web.Extensions.dll', '/r:System.ServiceProcess.dll',
    '/r:System.Management.dll',
    "/resource:$PSScriptRoot\driver\inpoutx64.dll,WJB.inpoutx64.dll"
) + $srcFiles

& $csc @argList 2>&1 | Out-String | Write-Host
"exit=$LASTEXITCODE"
if (Test-Path $out) { "EXE -> $out ($((Get-Item $out).Length) bytes)" }
