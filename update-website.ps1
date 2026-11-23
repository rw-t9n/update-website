$ErrorActionPreference = "Stop"
function Expand-Template {
  param($Template, $Vars)
  return [regex]::Replace($Template, '\{\{(.+?)\}\}', {
    param($Match)
    $Var = $Match.Groups[1].Value
    if ($Vars.ContainsKey($Var)) { $Vars[$Var] } else { $Match.Value }
  })
}

function Parse-XML {
  param($XMLFile, $LabelRegEx)
  try {
    [xml]$XML = Get-Content -Path $XMLFile.FullName -Encoding utf8
  }
  catch {
    Write-Warning "Failed to parse $XMLFile"
    return
  }
  if (-not $XML) { return }
  foreach ($Node in $XML.SelectNodes("/LanguageData/*")) {
    if ($Node.Name -notmatch "^$($LabelRegEx)$") { continue }
    $prevSibling = $Node.PreviousSibling
    if (-not $prevSibling) { continue }
    if ($prevSibling.NodeType -ne 'Comment') { continue }
    if ($prevSibling.Value.Trim() -notmatch '^EN: (.*)$') { continue }
    $English = $Matches[1]
    $Translation = $Node.InnerText.Trim()
    [PSCustomObject]@{
      English = $English
      Translation = $Translation
    }
  }
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

function ConvertTo-WikiIdAttr { # Similar to MediaWiki's escapeIdInternal()
  param($Id, $Mode)
  switch ($Mode) {
    'html5' {
      return $Id -replace "[\t\n\f\r ]", "_"
    }
    'legacy' {
      $Id = [System.Uri]::EscapeDataString(($Id -replace ' ', '_'))
      return ($Id -replace '%3A', ':') -replace '%', '.'
    }
  }
}

function ConvertTo-WikiTitle {
  param($Label)
  $Label = $Label -replace ' ', '_'
  $Label = [System.Uri]::EscapeDataString($Label)
  $Label = $Label -replace '%2F', '/' -replace '%3A', ':'
  return $Label
}

git submodule update --init --remote --force
git -C website checkout -B main origin/main
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
$NodeJSInstalled = Get-Command node -ErrorAction SilentlyContinue
winget install -e --id OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements
if (-not $NodeJSInstalled) { $env:Path = "C:\Program Files\nodejs;" + $env:Path }
npm install --prefix "$Root" --no-fund
$OutputDir = "$Root\website"
$SteamPath = (Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam").InstallPath
$GamePath = "$SteamPath\steamapps\common\RimWorld"
$GameWikiUrl = "https://rimworldwiki.com"
$GameVersion = Get-Content -Path "$GamePath\Version.txt"
$DLCs = Get-DLCs "$GamePath\Data"
$Timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ss 'UTC'")
$Glossaries = @{}

$Defs = @(
  ("Thing", "\w+\.label"),
  ("ResearchProject", "\w+\.label", "Research"),
  ("Stat", "\w+\.label"),
  ("Ability", "\w+\.label"),
  ("Incident", "\w+\.label"),
  ("Biome", "\w+\.label", "Biomes"),
  ("Skill", "\w+\.label", "Skills"),
  ("Hediff", "\w+\.label", "Hediffs"),
  ("Trait", ".+\.label", "Traits"),
  ("RoyalTitle", "\w+\.label", "Titles"),
  ("WeaponTrait", "\w+\.label"),
  ("Meme", "\w+\.label", "Memes"),
  ("Gene", "\w+\.label", "Genes"),
  ("Xenotype", "\w+\.label"),
  ("PsychicRitual", "\w+\.label", "Psychic_rituals"),
  ("Landmark", "\w+\.label", "Landmarks"),
  ("WorkType", "\w+\.labelShort", "Work"),
  ("Faction", "\w+\.label")
)

$CacheFile = "wiki_titles.txt"
Write-Host "Retrieving RimWorld Wiki titles from $GameWikiUrl... " -NoNewline
$TitleMap = @{}
try {
  $Headers = @{"User-Agent" = "https://github.com/rw-t9n"}
  foreach ($apfilterredir in @("redirects", "nonredirects")) {
    $apcontinue = $null
    do {
      $uri = "$GameWikiUrl/api.php?action=query&list=allpages&apfilterredir=$apfilterredir&aplimit=max&format=json"
      if ($apcontinue) { $uri += "&apcontinue=$([System.Uri]::EscapeDataString($apcontinue))" }
      $Res = Invoke-RestMethod -Uri $uri -Headers $Headers
      foreach ($p in $Res.query.allpages) { $TitleMap[$p.title] = $p.title }
      $apcontinue = $Res.continue.apcontinue
    } while ($apcontinue)
  }
  Write-Host "$($TitleMap.PSBase.Count) retrieved and stored in $CacheFile"
  $TitleMap.Values | Set-Content $CacheFile -Encoding UTF8
}
catch {
  $TitleMap.Clear()
  Write-Host "failed"
  Write-Warning $_.Exception.Message
  Write-Host "Retrieving RimWorld Wiki titles from $CacheFile... " -NoNewline
  try {
    Get-Content $CacheFile -Encoding UTF8 | ForEach-Object { if ($_) { $TitleMap[$_] = $_ } }
    Write-Host "$($TitleMap.PSBase.Count) retrieved"
  }
  catch {
    Write-Host "failed"
    Write-Warning $_.Exception.Message
    if ((Read-Host "Continue? (y/n)") -eq "n") { exit 1 }
  }
}

$TempPath = "$([System.IO.Path]::GetTempPath())\$([System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath))"
Remove-Item -Path $TempPath -Recurse -EA SilentlyContinue
$TempRoot = New-Item -ItemType Directory -Path $TempPath
Write-Host "Temp folder: $TempRoot"

foreach ($Language in Get-ChildItem -Path "$GamePath\Data\Core\Languages") {
  if ($Language.BaseName -notmatch '^(.+?)\s*\((.+)\)$') { continue }
  # if ($Language.BaseName -ne 'German (Deutsch)') { continue }
  $Glossary = $Glossaries[$Language.Name] = @{}
  $Glossary.EnglishName = $Matches[1]
  $Glossary.NativeName = $Matches[2]
  $Glossary.Rows = @()
  $Glossary.BaseNameKebabCase = ($Glossary.EnglishName -creplace '(?<!^)([A-Z])', '-$1').ToLower()
  $TempLang = New-Item -ItemType Directory -Path "$TempRoot\$($Glossary.EnglishName)"
  Write-Host ""
  Write-Host "$Language"
  Write-Host "----------------------"
  $EntryId = 0
  $TempTar = "$TempLang\temp.tar"
  $GlossaryEntries = foreach ($DLC in $DLCs) {
    $TransFilePath = "$GamePath\Data\$DLC\Languages\$Language"
    if (!(Test-Path $TransFilePath)) { continue }
    $TransFile = Get-Item $TransFilePath
    Write-Host "Processing $DLC..."
    if ($TransFile.Extension -eq '.tar') {
      Copy-Item -Path $TransFile.FullName -Destination $TempTar -Force
      $TransFileTemp = New-Item -ItemType Directory -Path "$TempLang\$DLC"
      tar -xf $TempTar -C $TransFileTemp.FullName
      $TransFile = $TransFileTemp
    }
    if ($DLC.BaseName -eq 'Core') {
      $LanguageInfoPath = "$($TransFile.FullName)\LanguageInfo.xml"
      [xml]$LanguageInfoXml = Get-Content -Path $LanguageInfoPath -Raw -Encoding utf8
      $Glossary.EnglishNameFriendly = $LanguageInfoXml.LanguageInfo.friendlyNameEnglish
      $Glossary.NativeNameFriendly = $LanguageInfoXml.LanguageInfo.friendlyNameNative
    }
    # Collect glossary entries:
    foreach ($Def in $Defs) {
      $DefName, $DefLabelsRegEx, $DefWikiPage = $Def
      $Path = "$($TransFile.FullName)\DefInjected\$($DefName)Def"
      if (!(Test-Path $Path)) { continue }
      $XMLs = Get-ChildItem -Path $Path -Filter "*.xml" -Recurse
      foreach ($XML in $XMLs) {
        if ($XML.BaseName -eq 'ImpliedDefs') { continue }
        if ($XML.BaseName -like 'Ethereal_*') { continue }
        foreach ($Match in (Parse-XML $XML $DefLabelsRegEx)) {
          if ($Match.English -eq 'Mote') { continue }
          if ($Match.Translation -eq 'TODO') { continue }
          [PSCustomObject]@{
            Id = $EntryId++
            English = $Match.English
            Translation = $Match.Translation
            DefName = $DefName
            DLC = $DLC.BaseName
            WikiPage = $DefWikiPage
          }
        }
      }
    }
  }
  # Create table rows:
  $Rows = foreach ($Entry in ($GlossaryEntries | Sort-Object English, Id)) {
    $DefNameFriendly = ($Entry.DefName -creplace '(?<!^)([A-Z])', '&nbsp;$1').ToLower()
    if ($Entry.WikiPage) {
      $Fragment = $Entry.English.Substring(0, 1).ToUpper() + $Entry.English.Substring(1)
      $Fragment = ConvertTo-WikiIdAttr $Fragment 'legacy'
      $Page = "$($Entry.WikiPage)#$Fragment"
    }
    elseif ($TitleMap.ContainsKey($Entry.English)) {
      $Page = "$(ConvertTo-WikiTitle $TitleMap[$Entry.English])"
    }
    else {
      $Page = "Special:Search/$([System.Uri]::EscapeDataString($Entry.English))"
    }
    $EnglishLink = "<a href=""$GameWikiUrl/wiki/$Page"">$($Entry.English)</a>"
    Create-Row $EnglishLink $Entry.Translation $DefNameFriendly $Entry.DLC
  }
  $Glossary.Rows = $Rows | Select-Object -Unique
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
