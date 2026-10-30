# Windows: trust the test root, sign the prepared Cosmopolitan file with Microsoft's tools, verify every signed variant with Microsoft's verifiers, run each one, check the hash survives.
# cwd = repository root; artifacts: out\ (unsigned), signed\ (signed on Linux), pki\ (test PKI). Writes work\.
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force work | Out-Null
$Res = New-Object System.Collections.ArrayList
function Note([string]$m) { Write-Host $m; [void]$Res.Add($m) }
$os = Get-CimInstance Win32_OperatingSystem
Note "RESULT host: $($os.Caption) $($os.Version); PROCESSOR_ARCHITECTURE=$env:PROCESSOR_ARCHITECTURE, native=$env:PROCESSOR_ARCHITEW6432"
certutil -addstore -f Root pki\root.cer | Select-Object -Last 1
$st = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\x64\\' } | Sort-Object FullName | Select-Object -Last 1
$st = $st.FullName; Note "RESULT signtool: $st"
$pw = ConvertTo-SecureString -String 'pw' -Force -AsPlainText
Import-PfxCertificate -FilePath pki\leaf.pfx -CertStoreLocation Cert:\CurrentUser\My -Password $pw | Out-Null
$cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -match 'Test Software Publisher' } | Select-Object -First 1

function Check([string]$f, [string]$label) {
  $h0 = (Get-FileHash $f -Algorithm SHA256).Hash
  $v = Get-AuthenticodeSignature $f
  $ts = if ($v.TimeStamperCertificate) { $v.TimeStamperCertificate.Subject } else { 'none' }
  Note "RESULT [$label] Get-AuthenticodeSignature: $($v.Status) | signer=$($v.SignerCertificate.Subject) | timestamper=$ts | $($v.StatusMessage)"
  $o = & $st verify /pa /v $f 2>&1 | Out-String; $ec = $LASTEXITCODE
  Note ("RESULT [$label] signtool verify /pa: exit $ec | " + (($o -split "`r?`n" | Where-Object { $_ -match 'Successfully|Number of|Error|Timestamp|expired|not trusted' } | ForEach-Object { $_.Trim() } | Select-Object -First 4) -join ' ; '))
  $run = (& ".\$f" 2>&1 | Out-String).Trim() -replace "`r?`n", ' / '
  Note "RESULT [$label] run: exit $LASTEXITCODE | $run"
  try { Add-Type -AssemblyName System.IO.Compression.FileSystem; $z = [IO.Compression.ZipFile]::OpenRead((Resolve-Path $f)); $n = $z.Entries.Count; $z.Dispose(); Note "RESULT [$label] .NET ZipFile: $n entries" } catch { Note "RESULT [$label] .NET ZipFile: not readable ($($_.Exception.InnerException.Message))" }
  $v2 = Get-AuthenticodeSignature $f
  Note "RESULT [$label] after run: file hash unchanged=$($h0 -eq (Get-FileHash $f -Algorithm SHA256).Hash); Get-AuthenticodeSignature=$($v2.Status)"
}

Note "--- control: signing tools on the file as built (2 data directories)"
Copy-Item out\app.com work\unprep-ps.exe; Copy-Item out\app.com work\unprep-st.exe
$r = Set-AuthenticodeSignature -FilePath work\unprep-ps.exe -Certificate $cert -HashAlgorithm SHA256
Note "RESULT [as built] Set-AuthenticodeSignature: $($r.Status) / $($r.StatusMessage)"
$o = & $st sign /fd SHA256 /f pki\leaf.pfx /p pw work\unprep-st.exe 2>&1 | Out-String; Note "RESULT [as built] signtool sign: exit $LASTEXITCODE | $((($o -split "`r?`n") | Where-Object {$_ -match 'Error|Success'} | Select-Object -First 2) -join ' ')"

Note "--- the prepared file, unsigned"
Copy-Item signed\app-prep.exe work\app-prep.exe; Check work\app-prep.exe 'prepared, unsigned'

Note "--- signed on Linux with osslsigncode, verified here"
foreach ($n in 'app-ossl','app-ossl-ts','app-ossl-plain-slot','app-ossl-ts-slot','dl-ossl','hello-ossl') { Copy-Item "signed\$n.exe" "work\$n.exe"; Check "work\$n.exe" "osslsigncode: $n" }

Note "--- signed here with Microsoft's tools"
Copy-Item signed\app-prep.exe work\app-ps.exe
$r = Set-AuthenticodeSignature -FilePath work\app-ps.exe -Certificate $cert -HashAlgorithm SHA256 -IncludeChain All
Note "RESULT [PowerShell sign] Set-AuthenticodeSignature: $($r.Status) / $($r.StatusMessage)"; Check work\app-ps.exe 'Set-AuthenticodeSignature'
Copy-Item signed\app-prep.exe work\app-st.exe
$o = & $st sign /fd SHA256 /f pki\leaf.pfx /p pw work\app-st.exe 2>&1 | Out-String; Note "RESULT [signtool sign] exit $LASTEXITCODE | $((($o -split "`r?`n") | Where-Object {$_ -match 'Error|Success'} | Select-Object -First 2) -join ' ')"; Check work\app-st.exe 'signtool'
Note "--- Microsoft signtool + zip slot layout (reserve, sign, fill)"
$py = (Get-Command python -ErrorAction SilentlyContinue); if (-not $py) { $py = Get-Command py -ErrorAction SilentlyContinue }
if ($py) {
  & $py.Source platform-probes\ape_zip_slot.py reserve signed\app-prep.exe work\res.exe 16384
  $o = & $st sign /fd SHA256 /f pki\leaf.pfx /p pw work\res.exe 2>&1 | Out-String; Note "RESULT [signtool on reserved file] exit $LASTEXITCODE"
  & $py.Source platform-probes\ape_zip_slot.py fill work\res.exe work\app-st-slot.exe 16384
  Check work\app-st-slot.exe 'signtool + zip slot'
} else { Note "RESULT python not found on this runner; slot layout with signtool not tested" }

Note "--- re-sign: second signature (dual sign, /as) appended with signtool to the osslsigncode-signed file"
Copy-Item signed\app-ossl.exe work\app-dual.exe
$o = & $st sign /as /fd SHA384 /f pki\leaf.pfx /p pw work\app-dual.exe 2>&1 | Out-String; Note "RESULT [dual] signtool sign /as exit $LASTEXITCODE | $((($o -split "`r?`n") | Where-Object {$_ -match 'Error|Success'} | Select-Object -First 2) -join ' ')"; Check work\app-dual.exe 'osslsigncode + signtool /as'

Note "=== SUMMARY ==="; $Res | Where-Object { $_ -like 'RESULT*' } | ForEach-Object { Write-Host $_ }
