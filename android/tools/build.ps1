param([switch]$TestsOnly, [switch]$SkipTests, [string]$AndroidToolchain)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path $PSScriptRoot -Parent
$source = [System.IO.Path]::GetFullPath((Join-Path $root '../ios'))
$tools = Join-Path $env:LOCALAPPDATA 'BTBU/Godot-4.7.2'
$project = Join-Path $env:LOCALAPPDATA 'IdleCrystalCorpAndroid/project'
[System.IO.Directory]::CreateDirectory($tools) | Out-Null
[System.IO.Directory]::CreateDirectory($project) | Out-Null

function Download-Verified($Url, $Destination, $Digest) {
    if (!(Test-Path $Destination)) { Invoke-WebRequest -UseBasicParsing $Url -OutFile $Destination }
    if ((Get-FileHash $Destination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Digest) { throw "Archive invalide : $Destination" }
}

$godot = Join-Path $tools 'Godot_v4.7.2-stable_win64_console.exe'
if (!(Test-Path $godot)) {
    $archive = Join-Path $tools 'godot.zip'
    Download-Verified 'https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_win64.exe.zip' $archive '731980f9608d61333e5baf54a2ef17210acc7a538446c0cb9969f002aca1e953'
    Expand-Archive $archive $tools -Force
}
Copy-Item (Join-Path $PSScriptRoot '_sc_') (Join-Path $tools '_sc_') -Force

foreach ($entry in @('project.godot', 'icon.png', 'icon.png.import', 'assets', 'core_engine', 'data', 'scenes', 'tests', 'native', 'tools')) {
    Copy-Item (Join-Path $source $entry) $project -Recurse -Force
}

function Run-Godot($Arguments, $Label, $Deadline = 120000) {
    $stdout = Join-Path $tools "$Label.stdout.log"
    $stderr = Join-Path $tools "$Label.stderr.log"
    $process = Start-Process -FilePath $godot -ArgumentList $Arguments -NoNewWindow -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $null = $process.Handle
    if (!$process.WaitForExit($Deadline)) {
        $process.Kill()
        throw "Godot ne termine pas : $Label (limite $Deadline ms)."
    }
    $process.WaitForExit()
    $output = (Get-Content $stdout -Raw -ErrorAction SilentlyContinue) + (Get-Content $stderr -Raw -ErrorAction SilentlyContinue)
    Write-Output $output
    if ($process.ExitCode -ne 0 -or $output -match 'SCRIPT ERROR:|Parse Error:|ERROR:.*Failed') { throw "Echec Godot : $Label (code $($process.ExitCode))" }
}

Run-Godot @('--headless', '--editor', '--path', "`"$project`"", '--import') 'import'
if (!$SkipTests) {
    foreach ($test in @('test_bignum', 'test_game', 'test_offline_persistence', 'test_save_codec', 'test_ui_compile', 'test_ui_interaction', 'test_background', 'test_plugin_contract', 'test_notifications', 'test_ads_economy', 'test_native_load', 'test_safe_area')) {
        Run-Godot @('--headless', '--path', "`"$project`"", '--script', "res://tests/$test.gd") $test
    }
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        & $python.Source (Join-Path $project 'tests/check_native_contract.py')
        if ($LASTEXITCODE -ne 0) { throw 'Contrat natif iOS en echec.' }
    } else { Write-Warning 'Python absent : contrat natif iOS non execute.' }
}
if ($TestsOnly) { return }

if (!$AndroidToolchain) { $AndroidToolchain = [System.IO.Path]::GetFullPath((Join-Path $root '../../CashDraft/android/.toolchain')) }
$jdk = Get-ChildItem $AndroidToolchain -Directory -Filter 'jdk-*' | Select-Object -First 1
if (!$jdk) { throw 'JDK 17 absent : fournir -AndroidToolchain ou installer les outils Android via StockChef/android/tools/build.ps1.' }
$env:JAVA_HOME = $jdk.FullName
$env:ANDROID_HOME = Join-Path $AndroidToolchain 'android-sdk'
if (!(Test-Path (Join-Path $env:ANDROID_HOME 'build-tools/35.0.0/apksigner.bat'))) { throw 'SDK Android et Build Tools 35.0.0 requis.' }

$template = Join-Path $tools 'android_debug.apk'
if (!(Test-Path $template)) {
    $archive = Join-Path $tools 'export_templates.tpz'
    Download-Verified 'https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz' $archive 'f298490b8d44d934be425a5a65a51bf15f422428b229a06a6e11d9ffea248011'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq 'templates/android_debug.apk' } | Select-Object -First 1
        if (!$entry) { throw 'Modele Android absent de l archive officielle.' }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $template, $true)
    } finally { $zip.Dispose() }
}
$keystore = Join-Path $tools 'debug.keystore'
if (!(Test-Path $keystore)) {
    & (Join-Path $env:JAVA_HOME 'bin/keytool.exe') -genkeypair -keystore $keystore -alias androiddebugkey -storepass android -keypass android -keyalg RSA -keysize 2048 -validity 10000 -dname 'CN=Android Debug,O=Android,C=US'
    if ($LASTEXITCODE -ne 0) { throw 'Creation de cle de test en echec.' }
}
$editorData = Join-Path $tools 'editor_data'
[System.IO.Directory]::CreateDirectory($editorData) | Out-Null
$settings = Get-Content (Join-Path $PSScriptRoot 'editor_settings.tres') -Raw
$settings = $settings.Replace('@ANDROID_HOME@', (ConvertTo-Json $env:ANDROID_HOME.Replace('\', '/') -Compress)).Replace('@JAVA_HOME@', (ConvertTo-Json $env:JAVA_HOME.Replace('\', '/') -Compress)).Replace('@DEBUG_KEYSTORE@', (ConvertTo-Json $keystore.Replace('\', '/') -Compress))
[System.IO.File]::WriteAllText((Join-Path $editorData 'editor_settings-4.7.tres'), $settings, [System.Text.UTF8Encoding]::new($false))
$preset = (Get-Content (Join-Path $root 'export_presets.cfg') -Raw).Replace('@ANDROID_TEMPLATE@', $template.Replace('\', '/'))
[System.IO.File]::WriteAllText((Join-Path $project 'export_presets.cfg'), $preset, [System.Text.UTF8Encoding]::new($false))
$destination = Join-Path $tools 'IdleCrystalCorp-debug.apk'
Run-Godot @('--headless', '--path', "`"$project`"", '--export-debug', 'Android', "`"$destination`"") 'export' 300000
if (!(Test-Path $destination)) { throw 'Aucun APK Android produit.' }
$artifacts = Join-Path $root 'artifacts'
[System.IO.Directory]::CreateDirectory($artifacts) | Out-Null
Copy-Item $destination $artifacts -Force
Write-Output "APK : $artifacts/IdleCrystalCorp-debug.apk"