param(
  [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$DevEcoHome = 'D:\Program Files\Huawei\DevEco Studio',
  [string]$Module = 'entry',
  [string]$BundleName = 'com.codex.router',
  [string]$AbilityName = 'EntryAbility',
  [string]$HapRelativePath = 'entry\build\default\outputs\default\entry-default-signed.hap',
  [string]$DeviceId = '',
  [string]$GatewayHost = '',
  [string]$GatewayHealthHost = '',
  [string]$GatewayHealthUrl = '',
  [int]$GatewayPort = 8443,
  [switch]$SkipBackendCheck,
  [switch]$SkipBuild,
  [switch]$EnsureHdcReverse
)

$ErrorActionPreference = 'Stop'

function Write-Step {
  param([string]$Message)
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Require-File {
  param(
    [string]$Path,
    [string]$Name
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Name not found: $Path"
  }
}

function Invoke-Checked {
  param(
    [string]$Label,
    [scriptblock]$Command
  )

  Write-Step $Label
  & $Command
  if ($LASTEXITCODE -ne 0) {
    throw "$Label failed with exit code $LASTEXITCODE"
  }
}

$sdkHome = Join-Path $DevEcoHome 'sdk'
$javaHome = Join-Path $DevEcoHome 'jbr'
$hvigorw = Join-Path $DevEcoHome 'tools\hvigor\bin\hvigorw.bat'
$hdc = Join-Path $sdkHome 'default\openharmony\toolchains\hdc.exe'
$hap = Join-Path $ProjectRoot $HapRelativePath

Require-File $hvigorw 'hvigorw.bat'
Require-File $hdc 'hdc.exe'

$env:DEVECO_SDK_HOME = $sdkHome
$env:JAVA_HOME = $javaHome
$env:Path = (Join-Path $javaHome 'bin') + ';' + $env:Path

Set-Location -LiteralPath $ProjectRoot

Write-Step 'Checking connected device'
$targets = & $hdc list targets
if ($LASTEXITCODE -ne 0) {
  throw "hdc list targets failed with exit code $LASTEXITCODE"
}
$connectedTargets = @($targets | Where-Object { $_.Trim().Length -gt 0 })
if ($connectedTargets.Count -eq 0) {
  throw 'No HarmonyOS device is connected. Unlock the phone and check USB debugging.'
}
if ($DeviceId.Length -eq 0) {
  $DeviceId = $connectedTargets[0].Trim()
}
Write-Host "Device: $DeviceId"

if (-not $SkipBackendCheck) {
  $startGateway = Join-Path $ProjectRoot 'scripts\start-gateway-windows.ps1'
  Require-File $startGateway 'Windows gateway starter'

  $gatewayArgs = @{
    ProjectRoot = $ProjectRoot
    GatewayPort = $GatewayPort
  }
  if ($GatewayHost.Length -gt 0) {
    $gatewayArgs.GatewayHost = $GatewayHost
  }
  if ($GatewayHealthHost.Length -gt 0) {
    $gatewayArgs.HealthHost = $GatewayHealthHost
  }

  Invoke-Checked 'Starting Windows gateway' {
    & $startGateway @gatewayArgs
  }

  if ($GatewayHealthUrl.Length -gt 0) {
    Write-Step 'Checking gateway health URL'
    $health = & curl.exe -k -s -o - -w "`nHTTP=%{http_code}`n" --max-time 10 $GatewayHealthUrl
    if ($LASTEXITCODE -ne 0 -or -not ($health | Select-String -SimpleMatch 'HTTP=200')) {
      $healthText = ($health -join "`n")
      throw "Gateway health check failed: $healthText"
    }
    $health | ForEach-Object { Write-Host $_ }
  }
}

if ($EnsureHdcReverse) {
  Write-Step 'Checking HDC reverse port'
  $fports = & $hdc -t $DeviceId fport ls
  if ($LASTEXITCODE -ne 0) {
    throw "hdc fport ls failed with exit code $LASTEXITCODE"
  }
  $reversePattern = "tcp:$GatewayPort tcp:$GatewayPort"
  if (-not ($fports | Select-String -SimpleMatch $reversePattern | Select-String -SimpleMatch '[Reverse]')) {
    Invoke-Checked "Creating HDC reverse tcp:$GatewayPort" {
      & $hdc -t $DeviceId rport "tcp:$GatewayPort" "tcp:$GatewayPort"
    }
    $fports = & $hdc -t $DeviceId fport ls
  }
  $fports | Where-Object { $_ -match "\[Reverse\]" } | ForEach-Object { Write-Host $_ }
}

if (-not $SkipBuild) {
  Invoke-Checked 'Building signed HAP' {
    & $hvigorw assembleHap --mode module -p "module=$Module" --no-daemon
  }
}

Require-File $hap 'signed HAP'

Invoke-Checked 'Installing HAP on device' {
  & $hdc -t $DeviceId install -r $hap
}

Invoke-Checked 'Stopping app' {
  & $hdc -t $DeviceId shell aa force-stop $BundleName
}

Invoke-Checked 'Starting app' {
  & $hdc -t $DeviceId shell aa start -a $AbilityName -b $BundleName -m $Module
}

Write-Step 'Verifying app process and artifact'
& $hdc -t $DeviceId shell "ps -ef | grep $BundleName"
$hapInfo = Get-Item -LiteralPath $hap
Write-Host "HAP: $($hapInfo.FullName)"
Write-Host "HAP time: $($hapInfo.LastWriteTime)"
Write-Host ""
Write-Host 'Deployment finished.' -ForegroundColor Green
