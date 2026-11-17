# Stages the Rust release build and makes the Windows zip and the setup program (sq-installer with the stage folder as its
# payload: SequenceStudio-Setup-<version>-<stamp>.exe). -Inno builds the old Inno Setup installer instead.
# Usage (on the PC): powershell -File packaging\windows\build-installer.ps1 [-Version x.y.z] [-Sign] [-Release] [-Inno] [-Installer <sq-installer.exe>]
# Without -Version the workspace version from Cargo.toml is used, the same number the app shows.
# Nothing here signs unless -Sign is given, and the certificate comes from
# the environment (SQ_WIN_CERT_PFX path, SQ_WIN_CERT_PASSWORD), never from the repository.
param(
    [string]$Version = '',
    [switch]$Sign,
    [string]$FfmpegDir = "$env:USERPROFILE\ffmpeg\ffmpeg-master-latest-win64-lgpl-shared",
    [string]$OnnxDir = $env:SQ_ONNXRUNTIME,
    [string]$ModelsDir = $env:SQ_SUBJECT_MASK_MODELS,
    # A release exe that was cross-built elsewhere (cargo xwin on Linux); without it the script runs cargo build here.
    [string]$Exe,
    # A release sq-installer.exe that was cross-built elsewhere; without it the script runs cargo build here.
    [string]$Installer,
    # The old Inno Setup installer (needs iscc) instead of the new setup program, until the new one is checked in the VM.
    [switch]$Inno,
    # Part of the output file names, so every run is unique and reproducible by its inputs: yyyyMMdd-HHmm.
    [string]$Stamp = (Get-Date -Format 'yyyyMMdd-HHmm'),
    # A public release: the output files carry only the version (SequenceStudio-Setup-<version>.exe), no build stamp.
    [switch]$Release
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$stage = Join-Path $root 'target\package\windows\stage'
$out = Join-Path $root 'target\package\windows'
if (-not $Version) {
    $m = Select-String -Path (Join-Path $root 'Cargo.toml') -Pattern '^version = "([^"]+)"' | Select-Object -First 1
    if (-not $m) { throw 'no version in Cargo.toml' }
    $Version = $m.Matches[0].Groups[1].Value
}
$tag = if ($Release) { $Version } else { "$Version-$Stamp" }

# ONNX Runtime 1.24.4 (MIT, docs/THIRD_PARTY.md): the pinned DirectML nuget, downloaded once into the cache and checked
# against its sha256; nothing is installed. SQ_ONNXRUNTIME (a folder with onnxruntime.dll) replaces the download.
$OrtVersion = '1.24.4'
$OrtSha256 = '57e9f11b73437bef7a309496135d4c1f96b1a8e9ddba60013fa27bfc1d788681'
function Get-OnnxRuntime {
    $dir = Join-Path $env:LOCALAPPDATA "SequenceStudio\build-cache\onnxruntime\$OrtVersion"
    $dll = Join-Path $dir 'x\runtimes\win-x64\native\onnxruntime.dll'
    if (Test-Path $dll) { return Split-Path $dll }
    New-Item -ItemType Directory -Force $dir | Out-Null
    $zip = Join-Path $dir 'ort.zip'
    Invoke-WebRequest "https://www.nuget.org/api/v2/package/Microsoft.ML.OnnxRuntime.DirectML/$OrtVersion" -OutFile $zip
    $got = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $OrtSha256) { Remove-Item $zip; throw "ONNX Runtime sha256 $got is not the pinned $OrtSha256" }
    Expand-Archive -Force $zip (Join-Path $dir 'x')
    return Split-Path $dll
}

# The files a package may hold: packaging\stage-allowlist.txt (extensions, and =Name for an exact file name), the list the Mac
# and Linux packages read too (crates/xtask/src/stage.rs). Returns the entries of the named sections.
function Get-StageAllow([string[]]$Sections) {
    $allow = @{ Ext = @(); Name = @() }
    $current = ''
    foreach ($line in Get-Content (Join-Path $root 'packaging\stage-allowlist.txt')) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        if ($t -match '^\[(.+)\]$') { $current = $Matches[1]; continue }
        if ($Sections -notcontains $current) { continue }
        if ($t.StartsWith('=')) { $allow.Name += $t.Substring(1).ToLower() } else { $allow.Ext += $t.ToLower() }
    }
    return $allow
}
function Test-StageFile($file, $allow) {
    return ($allow.Name -contains $file.Name.ToLower()) -or ($allow.Ext -contains $file.Extension.TrimStart('.').ToLower())
}

Push-Location $root
try {
    $env:PATH += ";$FfmpegDir\bin"
    if ($Exe) { $built = (Resolve-Path $Exe).Path }
    else {
        # The exe must delay-load the FFmpeg DLLs (sq-media-ffmpeg/build.rs): a missing tool fails the build.
        $env:SQ_REQUIRE_DELAYLOAD = '1'
        cargo build --release -p sequence-studio
        if ($LASTEXITCODE) { throw 'release build failed' }
        $built = Join-Path $root 'target\release\sequence-studio.exe'
    }

    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $stage | Out-Null
    Copy-Item $built (Join-Path $stage 'SequenceStudio.exe')
    Copy-Item "$FfmpegDir\bin\*.dll" $stage                          # FFmpeg (LGPL shared build)
    if (-not $OnnxDir) { $OnnxDir = Get-OnnxRuntime }
    Copy-Item "$OnnxDir\onnxruntime*.dll" $stage                    # ONNX runtime, loaded at run time by sq-onnx (next to the exe)
    Copy-Item 'crates\sq-onnx\vendor\ORT-LICENSE-MIT.txt' $stage
    # EdgeTAM ONNX parts (not in the repo, Apache-2.0): the Magic Mask finds them in <exe folder>\SubjectMask.
    # Folder: SQ_SUBJECT_MASK_MODELS, else the first existing of the PC folders below. Every part is checked against its pin.
    $parts = [ordered]@{
        'edgetam_encoder.onnx'       = '9c3607434154f86589df0cd625496e064867bfbf0f1b6102e7a8a289b9afe6a4'
        'edgetam_decoder.onnx'       = '97ec09e63dde9dd43f7fa99de571ecd9dbf0ff5449eee06e613d731a81af285a'
        'edgetam_decoder_box.onnx'   = 'f505728919400e3822d853439d2883357605b7bfd0ad67cdc94a13ef5f810374'
        'edgetam_mem_encoder.onnx'   = 'aa12fd604a7439b07d1b18a08d95fc938cbd652435988c07d9983042640d1add'
        'edgetam_mem_attention.onnx' = 'e87fd2364bb8be889cfd20b9a2a4a35058cbd6570852560b6900f3a62d2b870c'
    }
    if (-not $ModelsDir) {
        $ModelsDir = @("$env:USERPROFILE\sqmodels", "$env:USERPROFILE\sqonnx\models", 'Tools\SubjectMaskSpike\work\models-onnx') |
            Where-Object { Test-Path "$_\edgetam_encoder.onnx" } | Select-Object -First 1
    }
    if ($ModelsDir -and (Test-Path "$ModelsDir\edgetam_encoder.onnx")) {
        $sm = Join-Path $stage 'SubjectMask'
        New-Item -ItemType Directory -Force $sm | Out-Null
        foreach ($name in $parts.Keys) {
            $src = Join-Path $ModelsDir $name
            if (-not (Test-Path $src)) { throw "$name is missing in $ModelsDir" }
            $got = (Get-FileHash $src -Algorithm SHA256).Hash.ToLower()
            if ($got -ne $parts[$name]) { throw "$name sha256 $got is not the pinned $($parts[$name])" }
            Copy-Item $src $sm
        }
        Write-Host "EdgeTAM models: 5 parts from $ModelsDir (sha256 ok)"
    } else { Write-Host "no EdgeTAM ONNX parts found (set SQ_SUBJECT_MASK_MODELS): Magic Mask will report them missing" }
    # Only font files and their license texts: a folder copied wholesale once carried a sync tool's .sync-state.json into the setup.
    $fontAllow = Get-StageAllow @('fonts')
    $fontSrc = (Resolve-Path 'Packages\SQText\Sources\SQText\Resources\Fonts').Path
    $fontsOut = Join-Path $stage 'Fonts'
    $skipped = @()
    foreach ($f in Get-ChildItem $fontSrc -Recurse -File -Force) {
        if (-not (Test-StageFile $f $fontAllow)) { $skipped += $f.FullName; continue }
        $dest = Join-Path $fontsOut $f.FullName.Substring($fontSrc.Length).TrimStart('\')
        New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
        Copy-Item -LiteralPath $f.FullName $dest
    }
    if ($skipped) { Write-Host "Fonts: left out $($skipped.Count) file(s) that are not fonts or license texts: $($skipped -join ', ')" }
    foreach ($f in 'LICENSE', 'LICENSE-ADDITIONAL-TERMS.md', 'SUPPORTERS.md') { Copy-Item $f $stage }
    # LGPL FFmpeg: refuse a GPL or nonfree build (libavcodec embeds its configure line), then ship the notices.
    $avc = Get-ChildItem $stage -Filter 'avcodec-*.dll' | Select-Object -First 1
    if ($avc) {
        $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($avc.FullName))
        foreach ($flag in '--enable-gpl', '--enable-nonfree') { if ($text.Contains($flag)) { throw "$($avc.Name) was configured with ${flag}: a release needs an LGPL FFmpeg" } }
    }
    $lic = Join-Path $stage 'Licenses'
    New-Item -ItemType Directory -Force $lic | Out-Null
    foreach ($f in 'packaging\licenses\FFMPEG-LICENSE.txt', 'packaging\licenses\FFMPEG-NOTICE.txt', 'packaging\licenses\APACHE-2.0.txt', 'docs\THIRD_PARTY.md', 'docs\THIRD_PARTY-CRATES.md') { Copy-Item $f $lic }
    Copy-Item 'packaging\windows\SequenceStudio.ico' $stage                                # the exe carries it too (build.rs)
    foreach ($f in 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll') { Copy-Item "$env:SystemRoot\System32\$f" $stage -ErrorAction SilentlyContinue }  # app-local VC++ runtime

    # Nothing else may be in the stage (packaging\stage-allowlist.txt, the list the Mac and Linux packages use too).
    $stageAllow = Get-StageAllow @('common', 'windows')
    $stray = @(Get-ChildItem $stage -Recurse -File -Force | Where-Object { -not (Test-StageFile $_ $stageAllow) } |
        ForEach-Object { $_.FullName.Substring($stage.Length + 1) })
    if ($stray) { throw "the stage holds $($stray.Count) file(s) that are not on packaging\stage-allowlist.txt: $($stray -join ', ')" }

    if ($Sign) {
        if (-not $env:SQ_WIN_CERT_PFX) { throw 'SQ_WIN_CERT_PFX is not set' }
        Get-ChildItem $stage -Include *.exe, *.dll -Recurse | ForEach-Object {
            signtool sign /f $env:SQ_WIN_CERT_PFX /p $env:SQ_WIN_CERT_PASSWORD /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 $_.FullName
            if ($LASTEXITCODE) { throw "signtool failed on $($_.Name)" }
        }
    }

    New-Item -ItemType Directory -Force $out | Out-Null
    $zip = Join-Path $out "SequenceStudio-$tag-win64.zip"
    Remove-Item $zip -ErrorAction SilentlyContinue
    Compress-Archive -Path "$stage\*" -DestinationPath $zip
    Write-Host "zip: $zip"

    if ($Inno) {
        $iscc = (Get-Command iscc -ErrorAction SilentlyContinue).Source
        if (-not $iscc) { $iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1 }
        if (-not $iscc) { throw 'Inno Setup (iscc) not found' }
        & $iscc "/DAppVersion=$Version" "/DStamp=$Stamp" "/DStageDir=$stage" "/DOutDir=$out" (Join-Path $root 'packaging\windows\SequenceStudio.iss')
        if ($LASTEXITCODE) { throw 'iscc failed' }
    } else {
        # The setup program: sq-installer with the stage folder appended as its payload (sq-installer --pack). A signature goes
        # on the program before the payload is appended; the payload sits after the certificate, where Windows ignores it.
        if ($Installer) { $stub = (Resolve-Path $Installer).Path }
        else {
            cargo build --release -p sq-installer
            if ($LASTEXITCODE) { throw 'sq-installer build failed' }
            $stub = Join-Path $root 'target\release\sq-installer.exe'
        }
        if ($Sign) {
            $signed = Join-Path $out 'sq-installer-signed.exe'
            Copy-Item $stub $signed -Force
            signtool sign /f $env:SQ_WIN_CERT_PFX /p $env:SQ_WIN_CERT_PASSWORD /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 $signed
            if ($LASTEXITCODE) { throw 'signtool failed on the setup program' }
            $stub = $signed
        }
        $setup = Join-Path $out "SequenceStudio-Setup-$tag.exe"
        # sq-installer is a GUI-subsystem program: `&` would not wait for it and `$LASTEXITCODE` would not be its exit code.
        # Start-Process joins the arguments without quoting them, so each path carries its own quotes.
        $pack = Start-Process -FilePath $stub -ArgumentList @('--pack', "`"$stage`"", '--out', "`"$setup`"") -Wait -PassThru -NoNewWindow
        if ($pack.ExitCode -ne 0) { throw "packing the setup program failed (exit code $($pack.ExitCode))" }
        if (-not (Test-Path $setup)) { throw 'packing the setup program wrote no file' }
        Write-Host "setup: $setup"
    }
} finally { Pop-Location }
