param([Parameter(Mandatory)][string]$Msi, [Parameter(Mandatory)][string]$Evidence)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows') { throw 'Disposable Windows CI runner required' }
$Msi = (Resolve-Path -LiteralPath $Msi).Path
$Evidence = (Resolve-Path -LiteralPath $Evidence).Path
$installer = New-Object -ComObject WindowsInstaller.Installer
$db = $installer.OpenDatabase($Msi, 0)
function Get-Property([string]$Name) {
    $view = $db.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$Name'")
    $view.Execute()
    $row = $view.Fetch()
    if (-not $row) { throw "Missing MSI property $Name" }
    $value = $row.StringData(1)
    $view.Close()
    return $value
}
$name = Get-Property 'ProductName'
$upgrade = Get-Property 'UpgradeCode'
$product = Get-Property 'ProductCode'
$version = Get-Property 'ProductVersion'
if ($version -ne '0.7.3' -or $product -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { throw 'Unexpected MSI version or ProductCode' }
if ($name -ne 'XenTerm Flutter Next' -or $upgrade -ne '{83238181-7F80-480F-9D10-82FF0FCD16F5}') { throw 'Wrong MSI identity' }
[Runtime.InteropServices.Marshal]::FinalReleaseComObject($db) | Out-Null
[Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer) | Out-Null
$work = Join-Path $env:RUNNER_TEMP ('flutter-msi-' + [guid]::NewGuid().ToString('N'))
$destination = Join-Path $env:ProgramFiles 'XenTerm Flutter Next'
if (Test-Path $destination) { throw 'Unexpected preexisting installation on disposable runner' }
$profile = Join-Path $work 'profile'
New-Item -ItemType Directory -Path $profile -Force | Out-Null
$sentinel = Join-Path $profile 'keep.txt'
Set-Content -LiteralPath $sentinel -Value 'synthetic existing Flutter profile' -NoNewline
$before = (Get-FileHash $sentinel).Hash
$env:XENTERM_DATA_DIR = $profile
$installed = $false
function Invoke-Msi([string]$Arguments, [string]$Stage) {
    $log = Join-Path $Evidence "msi-$Stage.log"
    $p = Start-Process msiexec.exe -ArgumentList "$Arguments /qn /norestart /l*v `"$log`"" -PassThru
    if (-not $p.WaitForExit(180000)) { $p.Kill(); throw "msiexec $Stage timed out" }
    if ($p.ExitCode -ne 0) { throw "msiexec $Stage exit $($p.ExitCode) (reboot-required is not accepted)" }
}
function Assert-Installed {
    foreach ($file in @('xenterm.exe', 'xenterm_bridge.dll', 'LICENSE', 'THIRD_PARTY_NOTICES.md')) {
        if (-not (Test-Path (Join-Path $destination $file))) { throw "Missing installed $file" }
    }
    foreach ($file in @('xenterm.exe', 'xenterm_bridge.dll')) {
        $source = Join-Path (Get-Location) "apps/xenterm/build/windows/x64/runner/Release/$file"
        if ((Get-FileHash $source).Hash -ne (Get-FileHash (Join-Path $destination $file)).Hash) { throw "Installed $file differs from validated bundle" }
    }
    if ((Get-FileHash $sentinel).Hash -ne $before) { throw 'Installer changed existing profile' }
}
try {
    $installed = $true # Also attempt cleanup after a partial/failed install.
    Invoke-Msi "/i `"$Msi`"" 'install'
    Assert-Installed
    $app = Start-Process (Join-Path $destination 'xenterm.exe') -WorkingDirectory $destination -PassThru
    try {
        Start-Sleep -Seconds 8
        if ($app.HasExited) { throw "Installed application exited early: $($app.ExitCode)" }
    } finally {
        if (-not $app.HasExited) { $app.Kill(); $app.WaitForExit() }
    }
    Invoke-Msi "/fa `"$Msi`"" 'repair'
    Assert-Installed
    Invoke-Msi "/x $product" 'uninstall'
    $installed = $false
    if (Test-Path (Join-Path $destination 'xenterm.exe')) { throw 'Uninstall left executable' }
    if ((Get-FileHash $sentinel).Hash -ne $before) { throw 'Uninstall changed existing profile' }
    $hash = (Get-FileHash $Msi -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([IO.Path]::GetFileName($Msi))" | Set-Content (Join-Path $Evidence 'MSI-SHA256SUMS.txt')
    @{source_sha=$env:SOURCE_SHA; control_sha=$env:GITHUB_SHA; product_code=$product; upgrade_code=$upgrade; product_name=$name; signing='unsigned'; install=$true; repair=$true; uninstall=$true; startup_seconds=8; profile_sentinel_preserved=$true; interactive_ui_verified=$false; sha256=$hash} | ConvertTo-Json | Set-Content (Join-Path $Evidence 'MSI-VERIFICATION.json')
} finally {
    if ($installed) {
        try { Invoke-Msi "/x $product" 'cleanup-uninstall' }
        catch { Write-Warning "Cleanup uninstall: $_" }
    }
    # Only this invocation's generated disposable profile/install directory.
    if (Test-Path $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
