function Expand-Template {
  param($Template, $Vars)
  return [regex]::Replace($Template, '\{\{(.+?)\}\}', {
    param($Match)
    $Var = $Match.Groups[1].Value
    if ($Vars.ContainsKey($Var)) { $Vars[$Var] } else { $Match.Value }
  })
}

function Parse-XML {
  param($XMLFile)
  try {
    [xml]$XML = Get-Content -Path $XMLFile.FullName -Encoding utf8
  }
  catch {
    Write-Warning "Failed to parse $XMLFile"
    return
  }
  if (-not $XML) { return }
  $Entries = [Collections.Generic.List[object]]::new()
  foreach ($Node in $XML.SelectNodes("/LanguageData/*")) {
    if ($Node.Name -notmatch '^\w+\.label$') { continue }
    $prevSibling = $Node.PreviousSibling
    if (-not $prevSibling) { continue }
    if ($prevSibling.NodeType -ne 'Comment') { continue }
    if ($prevSibling.Value.Trim() -notmatch '^EN: (.*)$') { continue }
    $English = $Matches[1]
    $Translation = $Node.InnerText.Trim()
    if ($English -eq 'Mote' -or $Translation -eq 'TODO') { continue }
    $Entries.Add(@($English, $Translation))
  }
  return Write-Output -NoEnumerate $Entries
}

function Create-Row {
  $Fields = foreach ($Field in $args) { "<td>$Field</td>" }
  return "<tr>$Fields</tr>"
}

function Get-DLCs {
  param($Path)
  Get-ChildItem -Path $Path -Directory | ForEach-Object {
    $AboutPath = "$($_.FullName)\About\About.xml"
    if (Test-Path $AboutPath) {
      [xml]$AboutXml = Get-Content -Path $AboutPath -Raw -Encoding utf8
      $appId = [int]$AboutXml.ModMetaData.steamAppId
      $_ | Add-Member -NotePropertyName 'SteamAppId' -NotePropertyValue $appId -PassThru
    }
  } | Sort-Object SteamAppId
}

$Root = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
$NodeJSInstalled = Get-Command node -ErrorAction SilentlyContinue
winget install -e --id OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements
if (-not $NodeJSInstalled) { $env:Path = "C:\Program Files\nodejs;" + $env:Path }
npm install --prefix "$Root" --no-fund
$OutputDir = "$Root\website"
$SteamPath = (Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam").InstallPath
$GamePath = "$SteamPath\steamapps\common\RimWorld"
$GameVersion = Get-Content -Path "$GamePath\Version.txt"
$DLCs = Get-DLCs "$GamePath\Data"
$Timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ss 'UTC'")
$Glossaries = @{}
$TempPath = "$([System.IO.Path]::GetTempPath())\$([System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath))"
Remove-Item -Path $TempPath -Recurse -EA SilentlyContinue
$TempRoot = New-Item -ItemType Directory -Path $TempPath
Write-Host "Temp folder: $TempRoot"
foreach ($DLC in $DLCs) {
  $TempDLC = New-Item -ItemType Directory -Path "$TempRoot\$DLC"
  Write-Host ""
  Write-Host "$DLC"
  Write-Host "----------------------"
  $Languages = Get-ChildItem -Path "$($DLC.FullName)\Languages"
  $TempTar = "$TempDLC\temp.tar"
  foreach ($Language in $Languages) {
    if ($Language.BaseName -notmatch '^(.+?)\s*\((.+)\)$') { continue }
    # if ($Language.BaseName -ne 'German (Deutsch)') { continue }
    Write-Host "Processing $($Language.BaseName)..."
    if ($Language.Extension -eq '.tar') {
      Copy-Item -Path $Language.FullName -Destination $TempTar -Force
      $LanguageTemp = New-Item -ItemType Directory -Path "$TempDLC\$($Matches[1])"
      tar -xf $TempTar -C $LanguageTemp.FullName
      $Language = $LanguageTemp
    }
    if ($DLC.BaseName -eq 'Core') {
      $LangInfo = @{}
      $LangInfo.EnglishName = $Matches[1]
      $LangInfo.NativeName = $Matches[2]
      $LangInfo.BaseNameKebabCase = ($LangInfo.EnglishName -creplace '(?<!^)([A-Z])', '-$1').ToLower()
      $LanguageInfoPath = "$($Language.FullName)\LanguageInfo.xml"
      [xml]$LanguageInfoXml = Get-Content -Path $LanguageInfoPath -Raw -Encoding utf8
      $LangInfo.EnglishNameFriendly = $LanguageInfoXml.LanguageInfo.friendlyNameEnglish
      $LangInfo.NativeNameFriendly = $LanguageInfoXml.LanguageInfo.friendlyNameNative
      $LangInfo.Rows = @()
      $Glossaries[$Language.Name] = $LangInfo
    }
    $Glossary = $Glossaries[$Language.Name]
    $Defs = @(
      "Thing"
      "ResearchProject"
      "Stat"
      "Ability"
      "Incident"
      "Biome"
      "Skill"
      "Hediff"
      "Trait"
      "RoyalTitle"
      "WeaponTrait"
      "Meme"
      "Gene"
      "Xenotype"
      "PsychicRitual"
      "Landmark"
    )
    foreach ($Def in $Defs) {
      $Path = "$($Language.FullName)\DefInjected\$($Def)Def"
      $Def = ($Def -creplace '(?<!^)([A-Z])', '&nbsp;$1').ToLower()
      if (!(Test-Path $Path)) { continue }
      $XMLs = Get-ChildItem -Path $Path -Filter "*.xml" -Recurse
      foreach ($XML in $XMLs) {
        if ($XML.BaseName -eq 'ImpliedDefs') { continue }
        if ($XML.BaseName -like 'Ethereal_*') { continue }
        $Rows = foreach ($Fields in (Parse-XML $XML)) {
          $English, $Translation = $Fields
          $EnglishEncoded = [System.Uri]::EscapeDataString($English)
          $English = "<a href=""https://rimworldwiki.com/wiki/$EnglishEncoded"">$English</a>"
          Create-Row $English $Translation $Def $DLC
        }
        $Glossary.Rows += $Rows
      }
    }
  }
}
$GlossaryTemplate = Get-Content -Path "$Root\templates\glossaries\glossary.htm" -Raw
$GlossariesIndexTemplate = Get-Content -Path "$Root\templates\glossaries\index.htm" -Raw
$GlossariesIndexRows = @()
$Entries = $Glossaries.GetEnumerator() | Sort-Object -Property { $_.Value.EnglishNameFriendly }
foreach ($Entry in $Entries) {
  $Glossary = $Entry.Value
  if ($Glossary.Rows.Count -eq 0) { continue }
  $English = "<a href=""$($Glossary.BaseNameKebabCase).htm"">$($Glossary.EnglishNameFriendly)</a>"
  $GlossariesIndexRows += Create-Row $English $Glossary.NativeNameFriendly
  $Glossary.Rows = $Glossary.Rows | Sort-Object -Unique
  $Glossary.Timestamp = $Timestamp
  $Glossary.GameVersion = $GameVersion
  $Path = "$OutputDir\glossaries\$($Glossary.BaseNameKebabCase).htm"
  $Content = Expand-Template $GlossaryTemplate $Glossary
  Set-Content -Path $Path -Value $Content -Encoding utf8
}
$Path = "$OutputDir\glossaries\index.htm"
$Vars = @{Rows = $GlossariesIndexRows; Timestamp = $Timestamp; GameVersion = $GameVersion}
$Content = Expand-Template $GlossariesIndexTemplate $Vars
Set-Content -Path $Path -Value $Content -Encoding utf8
Write-Host ""
Write-Host "Formatting HTML files"
Write-Host "----------------------"
& npx prettier --write --cache --cache-strategy metadata --end-of-line auto "$OutputDir\glossaries\*.*"
Start-Process cmd -ArgumentList "/c rmdir /s /q ""$TempRoot""" -WindowStyle Hidden
