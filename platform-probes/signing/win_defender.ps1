# Windows: turn on Defender's cloud-delivered protection, automatic sample submission and PUA protection (as far as the runner's policy allows), scan and EXECUTE the unsigned and signed
# Cosmopolitan files (one that loads nothing, one that loads a library), record the verdicts; then SmartScreen / Smart App Control / WDAC (audit mode) facts.
# cwd = repository root; artifacts out\, signed\, pki\. SmartScreen's reputation service cannot be exercised from a CI job (no interactive shell launch, no download origin); that is stated in the results.
$ErrorActionPreference = 'Continue'
$Res = New-Object System.Collections.ArrayList
function Note([string]$m) { Write-Host $m; [void]$Res.Add($m) }
function Prefs([string]$when) {
  $p = Get-MpPreference; $s = Get-MpComputerStatus
  Note "RESULT [$when] MAPSReporting=$($p.MAPSReporting) SubmitSamplesConsent=$($p.SubmitSamplesConsent) CloudBlockLevel=$($p.CloudBlockLevel) CloudExtendedTimeout=$($p.CloudExtendedTimeout) PUAProtection=$($p.PUAProtection) DisableRealtimeMonitoring=$($p.DisableRealtimeMonitoring) DisableBehaviorMonitoring=$($p.DisableBehaviorMonitoring) DisableIOAVProtection=$($p.DisableIOAVProtection)"
  Note "RESULT [$when] RealTimeProtectionEnabled=$($s.RealTimeProtectionEnabled) OnAccessProtectionEnabled=$($s.OnAccessProtectionEnabled) IsTamperProtected=$($s.IsTamperProtected) AMProductVersion=$($s.AMProductVersion) signatures=$($s.AntivirusSignatureVersion) ($($s.AntivirusSignatureLastUpdated))"
}
$os = Get-CimInstance Win32_OperatingSystem; Note "RESULT host: $($os.Caption) $($os.Version) $env:PROCESSOR_ARCHITECTURE"
certutil -addstore -f Root pki\root.cer | Select-Object -Last 1
$mp = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
Prefs 'before'
try { Set-MpPreference -MAPSReporting Advanced -SubmitSamplesConsent SendAllSamples -CloudBlockLevel High -CloudExtendedTimeout 50 -PUAProtection Enabled -DisableRealtimeMonitoring $false -DisableBehaviorMonitoring $false -DisableIOAVProtection $false -ErrorAction Stop; Note "RESULT Set-MpPreference: accepted" } catch { Note "RESULT Set-MpPreference: $($_.Exception.Message)" }
Prefs 'after Set-MpPreference'
foreach ($try in 1, 2) {
  $o = & $mp -ValidateMapsConnection 2>&1 | Out-String; Note "RESULT cloud (MAPS) connection check #$try, exit $LASTEXITCODE : $((($o -split "`r?`n") | Where-Object { $_ -match 'MAPS|connection|error|0x' } | Select-Object -First 3) -join ' ')"
  if ($try -eq 1) { Start-Sleep 25; Prefs 'after 25 s' }
}
try { $s = Get-MpComputerStatus; Note "RESULT cloud-related status: IsVirtualMachine=$($s.IsVirtualMachine) NISEnabled=$($s.NISEnabled) BehaviorMonitorEnabled=$($s.BehaviorMonitorEnabled) IoavProtectionEnabled=$($s.IoavProtectionEnabled)" } catch {}

New-Item -ItemType Directory -Force scan | Out-Null
$e1 = 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-'; $e2 = 'ANTIVIRUS-TEST-FILE!$H+H*'; [IO.File]::WriteAllText("$PWD\scan\eicar-control.txt", $e1 + $e2)
$files = [ordered]@{
  'unsigned-hello (loads nothing)'       = 'out\hello.com'
  'unsigned-app (zip asset, loads nothing)' = 'out\app.com'
  'unsigned-dl (loads a library)'        = 'out\dl.com'
  'prepared-unsigned-app'                = 'signed\app-prep.exe'
  'signed-hello (test root trusted)'     = 'signed\hello-ossl.exe'
  'signed-app (test root trusted)'       = 'signed\app-ossl.exe'
  'signed-app-timestamped'               = 'signed\app-ossl-ts.exe'
  'signed-dl (loads a library)'          = 'signed\dl-ossl.exe'
}
$i = 0; $map = @{}
foreach ($k in @($files.Keys)) { $src = $files[$k]; if (-not $src -or -not (Test-Path $src)) { continue }; $i++; $dst = "scan\f$i.exe"; Copy-Item $src $dst; $map[$k] = $dst }
$map['EICAR control'] = 'scan\eicar-control.txt'

function Scan([string]$tag) {
  foreach ($k in $map.Keys) {
    $f = $map[$k]; $out = & $mp -Scan -ScanType 3 -File (Resolve-Path $f).Path -DisableRemediation 2>&1 | Out-String
    $verdict = if ($out -match 'found no threats') { 'no threats' } elseif ($out -match 'found (\d+) threats') { "THREAT: " + ((($out -split "`r?`n") | Where-Object { $_ -match '^Threat\s*:' } | Select-Object -First 1) -replace '\s+', ' ') } else { 'no verdict: ' + (($out -split "`r?`n" | Where-Object { $_ -match 'rror|0x' } | Select-Object -First 1)) }
    Note "RESULT [$tag] MpCmdRun scan $k ($((Get-Item $f).Length) bytes): exit $LASTEXITCODE, $verdict"
  }
}
Scan 'on-demand, cloud on'

function Run([string]$tag) {
  foreach ($k in $map.Keys) {
    if ($k -eq 'EICAR control') { continue }
    $f = $map[$k]
    try { $o = (& ".\$f" 2>&1 | Out-String).Trim() -replace "`r?`n", ' / '; Note "RESULT [$tag] execute $k : exit $LASTEXITCODE | $($o.Substring(0, [Math]::Min(120, $o.Length)))" } catch { Note "RESULT [$tag] execute $k : BLOCKED/ERROR $($_.Exception.Message)" }
  }
}
Run 'execute, cloud block level High'
Note "--- the same with the strictest cloud blocking (ZeroTolerance: block anything the cloud has no good reputation for)"
try { Set-MpPreference -CloudBlockLevel ZeroTolerance -ErrorAction Stop; Note "RESULT CloudBlockLevel now $((Get-MpPreference).CloudBlockLevel)" } catch { Note "RESULT could not set ZeroTolerance: $($_.Exception.Message)" }
Run 'execute, cloud block level ZeroTolerance'
Scan 'on-demand, ZeroTolerance'
try { $t = Get-MpThreatDetection | Select-Object -First 8 | ForEach-Object { "$($_.ThreatID):$($_.Resources -join ',')" }; Note "RESULT Get-MpThreatDetection: $($t -join ' | ')" } catch { Note "RESULT Get-MpThreatDetection: $($_.Exception.Message)" }
try { $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = 1116, 1117, 1121, 1122, 5007 } -MaxEvents 12 -ErrorAction Stop | ForEach-Object { "$($_.Id)@$($_.TimeCreated.ToString('HH:mm:ss'))" }; Note "RESULT Defender operational events (1116 detected, 1117 action, 1121/1122 ASR, 5007 config): $($ev -join ' ')" } catch { Note "RESULT Defender events: none or unreadable ($($_.Exception.Message))" }

Note "--- Mark of the Web: a copy with Zone.Identifier ZoneId=3 (what a browser download gets); started from a process (no Explorer, so no SmartScreen prompt is possible here)"
Copy-Item signed\app-ossl.exe scan\motw-signed.exe; Copy-Item out\app.com scan\motw-unsigned.exe
foreach ($f in 'scan\motw-signed.exe', 'scan\motw-unsigned.exe') { Set-Content -Path $f -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3`r`nReferrerUrl=https://example.invalid/`r`nHostUrl=https://example.invalid/app.exe"; $o = (& ".\$f" 2>&1 | Out-String).Trim() -replace "`r?`n", ' / '; Note "RESULT MOTW copy $f runs from a process: exit $LASTEXITCODE | $o" }

Note "--- SmartScreen / Smart App Control / WDAC state"
foreach ($q in @(@('HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy', 'VerifiedAndReputablePolicyState'), @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\System', 'EnableSmartScreen'), @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer', 'SmartScreenEnabled'), @('HKLM:\SOFTWARE\Microsoft\Windows Defender\Features', 'TamperProtection'))) {
  $v = (Get-ItemProperty -Path $q[0] -Name $q[1] -ErrorAction SilentlyContinue).($q[1]); Note "RESULT registry $($q[0]) $($q[1]) = $(if ($null -eq $v) { '(not present)' } else { $v })"
}
try { $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop; Note "RESULT DeviceGuard: CodeIntegrityPolicyEnforcementStatus=$($dg.CodeIntegrityPolicyEnforcementStatus) UsermodeCodeIntegrityPolicyEnforcementStatus=$($dg.UsermodeCodeIntegrityPolicyEnforcementStatus)" } catch { Note "RESULT DeviceGuard WMI: $($_.Exception.Message)" }
$citool = Get-Command CiTool.exe -ErrorAction SilentlyContinue; Note "RESULT CiTool.exe present: $([bool]$citool)"

Note "--- WDAC in AUDIT mode: policy = AllowMicrosoft + our test publisher; which of the files would a user-mode code-integrity policy have blocked?"
try {
  $base = 'C:\Windows\schemas\CodeIntegrity\ExamplePolicies\AllowMicrosoft.xml'; if (-not (Test-Path $base)) { throw "example policy $base not present on this image" }
  Copy-Item signed\app-st.exe scan\wdac-signed.exe -ErrorAction SilentlyContinue; if (-not (Test-Path scan\wdac-signed.exe)) { Copy-Item signed\app-ossl.exe scan\wdac-signed.exe }
  Copy-Item out\app.com scan\wdac-unsigned.exe; Copy-Item signed\app-ossl.exe scan\wdac-signed-ossl.exe
  $x = 'work-wdac.xml'; Copy-Item $base $x
  $drv = Get-SystemDriver -ScanPath (Resolve-Path scan\wdac-signed-ossl.exe).Path -UserPEs
  Note "RESULT [WDAC] Get-SystemDriver on the signed file: $(@($drv).Count) item(s); SignatureStatus=$(($drv | ForEach-Object { $_.SignatureStatus }) -join ',')"
  $rules = New-CIPolicyRule -DriverFiles $drv -Level Publisher -Fallback Hash
  Note "RESULT [WDAC] rules generated: $(@($rules).Count) ($(($rules | ForEach-Object { $_.GetType().Name }) -join ','))"
  Merge-CIPolicy -PolicyPaths $x -OutputFilePath $x -Rules $rules | Out-Null
  Set-RuleOption -FilePath $x -Option 3
  Set-CIPolicyIdInfo -FilePath $x -ResetPolicyID | Out-Null
  $id = ([xml](Get-Content $x)).SiPolicy.PolicyID; $cip = "$PWD\$id.cip"; ConvertFrom-CIPolicy -XmlFilePath $x -BinaryFilePath $cip | Out-Null
  if ($citool) { $o = & CiTool.exe --update-policy $cip 2>&1 | Out-String; Note "RESULT CiTool --update-policy: $($o.Trim() -replace "`r?`n",' ')" } else { throw 'CiTool.exe missing; cannot activate the policy without a reboot' }
  Start-Sleep 3
  $t0 = Get-Date
  foreach ($f in 'scan\wdac-unsigned.exe', 'scan\wdac-signed-ossl.exe') { $o = (& ".\$f" 2>&1 | Out-String).Trim() -replace "`r?`n", ' / '; Note "RESULT [WDAC audit] ran $f : exit $LASTEXITCODE | $o" }
  $o = (& whoami.exe 2>&1 | Out-String).Trim(); Note "RESULT [WDAC audit] control, a Microsoft-signed binary (whoami.exe): $o"
  Start-Sleep 3
  $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-CodeIntegrity/Operational'; StartTime = $t0.AddSeconds(-5) } -ErrorAction SilentlyContinue
  foreach ($e in $ev) { if ($e.Id -in 3076, 3077, 3033, 3034, 3089) { $x = ($e.ToXml() -replace '<[^>]*Name=.([A-Za-z0-9 ]+).[^>]*>', ' $1=' -replace '</Data>', ';' -replace '<[^>]+>', ' ' -replace '\s+', ' '); Note "RESULT [WDAC audit] event $($e.Id): $($x.Substring(0, [Math]::Min(900, $x.Length)))" } }
  Note "RESULT [WDAC audit] code-integrity events since the runs: $(@($ev).Count) (3076 = audit: would have been blocked, 3077 = blocked, 3089 = signature info)"
} catch { Note "RESULT WDAC audit test not possible: $($_.Exception.Message)" }
Note "=== SUMMARY ==="; $Res | Where-Object { $_ -like 'RESULT*' } | ForEach-Object { Write-Host $_ }
