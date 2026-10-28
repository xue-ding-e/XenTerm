param([Parameter(Mandatory)][string]$WixBin)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/msi_properties.ps1"
# Regression for COM adapters which return status values on Execute/Close.
$record = [pscustomobject]@{}
$record | Add-Member ScriptMethod StringData { param($index) return '0.7.3' }
$view = [pscustomobject]@{Record=$record}
$view | Add-Member ScriptMethod Execute { return 17 }
$view | Add-Member ScriptMethod Close { return 23 }
$view | Add-Member ScriptMethod Fetch { return $this.Record }
$fakeDb = [pscustomobject]@{View=$view}
$fakeDb | Add-Member ScriptMethod OpenView { param($query) return $this.View }
$value = Get-MsiProperty $fakeDb 'ProductVersion'
if ($value -isnot [string] -or $value -ne '0.7.3') { throw 'COM status leaked into property pipeline' }
$work = Join-Path $env:RUNNER_TEMP ('msi-property-fixture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    @'
<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
<Product Id="12345678-1234-4234-8234-123456789ABC" Name="Synthetic fixture" Language="1033" Version="0.7.3" Manufacturer="Test" UpgradeCode="9D106BA7-8571-4925-81DE-71A792ED4CA1">
<Package InstallerVersion="200" Compressed="yes" InstallScope="perUser"/>
<MediaTemplate EmbedCab="yes"/>
<Directory Id="TARGETDIR" Name="SourceDir"><Directory Id="LocalAppDataFolder"><Directory Id="INSTALLFOLDER" Name="SyntheticMsiFixture"><Component Id="Fixture" Guid="*"><RemoveFolder Id="RemoveFixtureFolder" On="uninstall"/><RegistryValue Root="HKCU" Key="Software\SyntheticMsiFixture" Name="marker" Type="integer" Value="1" KeyPath="yes"/></Component></Directory></Directory></Directory>
<Feature Id="Main" Level="1"><ComponentRef Id="Fixture"/></Feature>
</Product></Wix>
'@ | Set-Content (Join-Path $work 'fixture.wxs') -Encoding utf8
    & (Join-Path $WixBin 'candle.exe') -nologo -out "$work/fixture.wixobj" "$work/fixture.wxs" | Write-Host
    if ($LASTEXITCODE -ne 0) { throw 'Fixture candle failed' }
    & (Join-Path $WixBin 'light.exe') -nologo -out "$work/fixture.msi" "$work/fixture.wixobj" | Write-Host
    if ($LASTEXITCODE -ne 0) { throw 'Fixture light failed' }
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $db = $installer.OpenDatabase("$work/fixture.msi", 0)
    $version = Get-MsiProperty $db 'ProductVersion'
    $code = Get-MsiProperty $db 'ProductCode'
    Write-Host "Fixture property types: $($version.GetType().FullName), $($code.GetType().FullName); values: $version / $code"
    if ($version -isnot [string] -or $version -ne '0.7.3') { throw 'Version must be one exact string' }
    if ($code -isnot [string] -or $code -ne '{12345678-1234-4234-8234-123456789ABC}') { throw 'Code must be one exact GUID string' }
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($db) | Out-Null
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer) | Out-Null
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}
