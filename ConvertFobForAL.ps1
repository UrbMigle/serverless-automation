[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string] $licenseFile,
    [Parameter(Mandatory = $true)]
    [string] $fobFolder,
    [Parameter(Mandatory = $true)]
    [string] $sourceArtifactVersion,
    [Parameter(Mandatory = $true)]
    [string] $extensionArtifactVersion,
    [ValidateLength(1, 10)]    
    [Parameter(Mandatory = $true)]
    [string] $projectName,
    [Parameter()]
    [int] $startId = 50000,
    [Parameter(Mandatory = $true)]
    [String] $newPrefix,
    [ValidateLength(2, 2)]
    [string] $baseSourceCountry = 'w1',
    [ValidateLength(2, 2)]
    [string] $targetSourceCountry = $baseSourceCountry,
    [Parameter()]
    [int] $incrementByNumber = 1,
    [Parameter()]
    [string] $addinFolder = "",
    [Parameter()]
    [string] $basefobFolder = "",
    [Parameter()]
    [string] $customLocale = "",
    [Parameter()]
    [string] $addonAppsFolder = "",
    [switch] $useAsSuffix,
    [String] $publisher = $projectName
)
write-Host "baseSourceCountry: $baseSourceCountry, targetSourceCountry: $targetSourceCountry, type: OnPrem, startId: $startId, incrementByNumber: $incrementByNumber" -ForegroundColor Green
#region Install BcContainerHelper
$module = Get-InstalledModule -Name bccontainerhelper
if ($module) {
    $versionStr = $module.Version.ToString()
    Write-Host "BcContainerHelper $VersionStr is installed"
    Write-Host "Determine latest BcContainerHelper version"
    $latestVersion = (Find-Module -Name bccontainerhelper).Version
    $bcContainerHelperVersion = $latestVersion.ToString()
    Write-Host "BcContainerHelper $bcContainerHelperVersion is the latest version"
    if ($bcContainerHelperVersion -ne $module.Version) {
        Write-Host "Updating BcContainerHelper to $bcContainerHelperVersion"
        Uninstall-Module bccontainerhelper -Force -AllVersions -ErrorAction SilentlyContinue
        Install-Module -Name bccontainerhelper -Force -RequiredVersion $bcContainerHelperVersion
        Write-Host "BcContainerHelper updated"
    }
}
Get-InstalledModule -Name bccontainerhelper | Out-Null
#endregion

$currentLocation = Get-Location

#region Variable Declarations
$password = 'P@ssword1' | ConvertTo-SecureString -asPlainText -Force
$username = 'admin'
$credential = New-Object System.Management.Automation.PSCredential($username, $password)
$sourceContainerName = "$projectName-base"
$extensionContainerName = "$projectName-ext"
#endregion

#region Check target version
$extensionartifactUrl = Get-BCArtifactUrl -type OnPrem -version $extensionArtifactVersion -country $targetSourceCountry -select Latest
if ([string]::IsNullOrEmpty($extensionartifactUrl)) {
    Write-Host "Version $extensionArtifactVersion with country $targetSourceCountry does not exist as OnPrem" -ForegroundColor Green
    throw
}
#endregion

#region Read Settings
# $settings = Get-Content 'Settings.json' | ConvertFrom-Json
# $sourceContainerName = $settings.Source.Name
# $extensionContainerName = $settings.target.Name
#endregion

#region Create source container and generate deltas
$artifactUrl = Get-BCArtifactUrl -type OnPrem -version $sourceArtifactVersion -country $baseSourceCountry -select Latest
Write-Host $artifactUrl -ForegroundColor Green

if (!([string]::IsNullOrEmpty($customLocale))) {
    New-BcContainer `
        -containerName $sourceContainerName `
        -accept_outdated `
        -accept_eula `
        -alwaysPull `
        -auth NavUserPassword `
        -Credential $credential `
        -artifactUrl $artifactUrl `
        -updateHosts `
        -shortcuts None `
        -EnableTaskScheduler:$false `
        -doNotCheckHealth `
        -licenseFile $licenseFile `
        -includeCSide `
        -locale $customLocale `
        -setServiceTierUserLocale `
        -doNotExportObjectsToText
}
else {
    New-BcContainer `
        -containerName $sourceContainerName `
        -accept_outdated `
        -accept_eula `
        -alwaysPull `
        -auth NavUserPassword `
        -Credential $credential `
        -artifactUrl $artifactUrl `
        -updateHosts `
        -shortcuts None `
        -EnableTaskScheduler:$false `
        -doNotCheckHealth `
        -licenseFile $licenseFile `
        -includeCSide `
        -doNotExportObjectsToText
}    

$installedApps = Get-BcContainerAppInfo -containerName $sourceContainerName -tenantSpecificProperties -sort DependenciesLast | Where-Object { $_.Name -ne "System Application" }
$installedApps | % {
    $app = $_
    UnPublish-BcContainerApp -name $app.Name -containerName $sourceContainerName -doNotSaveData -doNotSaveSchema -unInstall -force
}

if (!([string]::IsNullOrEmpty($addinFolder))) {
    Copy-Item -Path $addinFolder -Destination "C:\ProgramData\BcContainerHelper\Extensions\$sourceContainerName\my\CustomAddins\" -Recurse
    Copy-Item -Path $addinFolder -Destination (Get-Item "C:\ProgramData\BcContainerHelper\Extensions\$sourceContainerName\Program Files\*\RoleTailored Client\Add-ins\").FullName -Recurse
    Invoke-ScriptInBCContainer -containerName $sourceContainerName -scriptblock {
        Copy-Item -Path "C:\Run\my\CustomAddins\" -Destination (Get-Item "C:\Program Files\Microsoft Dynamics NAV\*\Service\Add-ins\").FullName -Recurse
    }
}
Invoke-ScriptInBCContainer -containerName $sourceContainerName -scriptblock {
    $customConfigFile = Join-Path (Get-Item "C:\Program Files\Microsoft Dynamics NAV\*\Service").FullName "CustomSettings.config"
    [xml]$customConfig = [System.IO.File]::ReadAllText($customConfigFile)
    $serverInstance = $customConfig.SelectSingleNode("//appSettings/add[@key='ServerInstance']").Value
    Set-NAVServerinstance $serverInstance -restart
}

#region requires 2.0.6
if (!([string]::IsNullOrEmpty($basefobFolder))) {
    foreach ($objectsFile in Get-ChildItem $basefobFolder -Filter '*.fob') {
        Import-ObjectsToNavContainer `
            -containerName $sourceContainerName `
            -objectsFile $objectsFile.FullName `
            -SynchronizeSchemaChanges No
    }

    try {
        Compile-ObjectsInNavContainer `
            -containerName $sourceContainerName `
            -filter 'id=1..'
    }    
    catch {
        # Write-Host "Compilation failed: $PSItem.Exception.InnerException"
    }
}
$baseFolder = "C:\ProgramData\BcContainerHelper\Extensions\$sourceContainerName\my\base-newsyntax\"
Export-NavContainerObjects `
    -containerName $sourceContainerName `
    -objectsFolder $baseFolder `
    -filter 'id=1..1999999999' `
    -exportTo 'txt folder (new syntax)'
#endregion

foreach ($objectsFile in Get-ChildItem $fobFolder -Filter '*.fob') {
    Import-ObjectsToNavContainer `
        -containerName $sourceContainerName `
        -objectsFile $objectsFile.FullName `
        -SynchronizeSchemaChanges No
}

try {
    Compile-ObjectsInNavContainer `
        -containerName $sourceContainerName `
        -filter 'id=1..'
}
catch {
    # Write-Host "Compilation failed: $PSItem.Exception.InnerException"
}

Export-ModifiedObjectsAsDeltas `
    -containerName $sourceContainerName `
    -filter 'id=1..1999999999' `
    -useNewSyntax `
    -originalFolder $baseFolder

New-Item -Path "C:\ProgramData\BcContainerHelper\Extensions\$sourceContainerName\my\bc14tablesonly\" -ItemType Directory | Out-Null
Export-NavContainerObjects -objectsFolder "C:\ProgramData\BcContainerHelper\Extensions\$sourceContainerName\my\bc14tablesonly\" -containerName $sourceContainerName -exportTo "txt file (new syntax)" -filter 'Type=Table;Id=1..1999999999'

$ContainerInformation = docker inspect $sourceContainerName | ConvertFrom-Json
foreach ($Mount in $ContainerInformation[0].Mounts) {
    if ($Mount.Destination -eq 'c:\run\my') {
        $SourceContainerFolder = (get-item $Mount.Source).Parent
        break
    }
}
Stop-BcContainer -containerName $sourceContainerName
#endregion

$artifactUrl = Get-BCArtifactUrl -country $baseSourceCountry -select Latest -type OnPrem -version 14
Write-Host $artifactUrl -ForegroundColor Green
$version = ($artifactUrl -split "/")[4]

$tempPath = ([System.IO.Path]::GetTempPath())
Download-Artifacts -artifactUrl $artifactUrl -basePath $tempPath -includePlatform -force -forceRedirection
Copy-Item -Path "$tempPath\OnPrem\$version\platform\RoleTailoredClient\program files\Microsoft Dynamics NAV\140\RoleTailored Client" -Destination (Join-Path $SourceContainerFolder.FullName 'txt2al') -Recurse
Remove-Item -Path (Join-Path $tempPath 'OnPrem') -Recurse -Force

.\ConvertDeltaToAL.ps1 -txt2al (Join-Path $SourceContainerFolder.FullName 'txt2al') -deltaFolder (Join-Path $SourceContainerFolder.FullName 'delta-newsyntax') -alFolder (Join-Path $SourceContainerFolder.FullName 'al') -startId $startId
Set-Location $currentLocation
.\RenameALObjects.ps1 -alObjectFolder (Join-Path $SourceContainerFolder.FullName 'al') -newPrefix $newPrefix -objectRangeStart $startId -incrementByNumber $incrementByNumber -useAsSuffix $useAsSuffix
Set-Location $currentLocation
.\RemoveUnsupportedFeatures.ps1 -Src (Join-Path $SourceContainerFolder.FullName 'al')
Set-Location $currentLocation
.\ConvertDeltaToAL.ps1 -txt2al (Join-Path $SourceContainerFolder.FullName 'txt2al') -startId $startId -deltaFolder (Join-Path $SourceContainerFolder.FullName 'my\base-newsyntax') -alFolder (Join-Path $SourceContainerFolder.FullName 'BC140_AL')
Set-Location $currentLocation    
.\ConvertDeltaToAL.ps1 -txt2al (Join-Path $SourceContainerFolder.FullName 'txt2al') -startId $startId -deltaFolder (Join-Path $SourceContainerFolder.FullName 'modified-newsyntax') -alFolder (Join-Path $SourceContainerFolder.FullName 'BC140_CUSTOM_AL')
Set-Location $currentLocation    
Compress-Archive -Path (Join-Path $SourceContainerFolder.FullName 'BC140_AL') -DestinationPath (Join-Path $SourceContainerFolder.FullName 'BC140_AL.zip')
Compress-Archive -Path (Join-Path $SourceContainerFolder.FullName 'BC140_CUSTOM_AL') -DestinationPath (Join-Path $SourceContainerFolder.FullName 'BC140_CUSTOM_AL.zip')

$txt2al = (Join-Path $SourceContainerFolder.FullName 'txt2al\txt2al.exe')
$txt2alParameters = @()
$txt2alParameters += @("--source=C:\ProgramData\BcContainerHelper\Extensions\$sourceContainerName\my\bc14tablesonly")
$txt2alParameters += @("--target=C:\ProgramData\BcContainerHelper\Extensions\$sourceContainerName\MigrationAppV1\Src")
$txt2alParameters += @("--tableDataOnly")
Write-Host "txt2al.exe $([string]::Join(' ', $txt2alParameters))"
& $txt2al $txt2alParameters

Write-Host $extensionartifactUrl -ForegroundColor Green

if (!([string]::IsNullOrEmpty($customLocale))) {
    New-BcContainer `
        -containerName $extensionContainerName `
        -accept_eula `
        -alwaysPull `
        -auth NavUserPassword `
        -Credential $credential `
        -artifactUrl $extensionartifactUrl `
        -memoryLimit 6G `
        -licenseFile $licenseFile `
        -updateHosts `
        -shortcuts Desktop `
        -includeAL `
        -doNotExportObjectsToText `
        -locale $customLocale `
        -setServiceTierUserLocale
}
else {
New-BcContainer `
        -containerName $extensionContainerName `
        -accept_eula `
        -alwaysPull `
        -auth NavUserPassword `
        -Credential $credential `
        -artifactUrl $extensionartifactUrl `
        -memoryLimit 6G `
        -licenseFile $licenseFile `
        -updateHosts `
        -shortcuts Desktop `
        -includeAL `
        -doNotExportObjectsToText    
}    

$ContainerInformation = docker inspect $extensionContainerName | ConvertFrom-Json
foreach ($Mount in $ContainerInformation[0].Mounts) {
    if ($Mount.Destination -eq 'c:\run\my') {
        $extensionContainerFolder = (get-item $Mount.Source).Parent
        break
    }
}    

Copy-Item -Path (Join-Path $SourceContainerFolder.FullName 'delta-newsyntax') -Destination (Join-Path $extensionContainerFolder.FullName 'delta-newsyntax') -Recurse 
Copy-Item -Path (Join-Path $SourceContainerFolder.FullName 'al') -Destination (Join-Path $extensionContainerFolder.FullName 'al') -Recurse 
Copy-Item (Join-Path $SourceContainerFolder.FullName 'BC140_AL.zip') -Destination $extensionContainerFolder.FullName
Copy-Item (Join-Path $SourceContainerFolder.FullName 'BC140_CUSTOM_AL.zip') -Destination $extensionContainerFolder.FullName
Copy-Item -Path (Join-Path $SourceContainerFolder.FullName 'MigrationAppV1') -Destination (Join-Path $extensionContainerFolder.FullName 'MigrationAppV1') -Recurse 
Remove-BcContainer -containerName $sourceContainerName

#region Extension
$symbolPath = (Join-Path $extensionContainerFolder.FullName 'al\.alpackages')
$apps = Get-BcContainerAppInfo -containerName $extensionContainerName

$appInfo = $apps | Where-Object { ($_.Publisher -eq 'Microsoft') -and ($_.Name -eq 'Base Application') }
$appVersion = $appInfo.Version
$appName = $appInfo.Publisher + '_' + $appInfo.Name + '_' + $appInfo.Version + ".app"
Get-BcContainerApp -appFile (Join-Path $symbolPath $appName) -appName 'Base Application' -containerName $extensionContainerName -credential $credential -publisher 'Microsoft'

$appInfo = $apps | Where-Object { ($_.Publisher -eq 'Microsoft') -and ($_.Name -eq 'System Application') }
$appName = $appInfo.Publisher + '_' + $appInfo.Name + '_' + $appInfo.Version + ".app"
Get-BcContainerApp -appFile (Join-Path $symbolPath $appName) -appName 'System Application' -containerName $extensionContainerName -credential $credential -publisher 'Microsoft'

$appInfo = $apps | Where-Object { ($_.Publisher -eq 'Microsoft') -and ($_.Name -eq 'Application') }
$appName = $appInfo.Publisher + '_' + $appInfo.Name + '_' + $appInfo.Version + ".app"
Get-BcContainerApp -appFile (Join-Path $symbolPath $appName) -appName 'Application' -containerName $extensionContainerName -credential $credential -publisher 'Microsoft'

$apps = Get-BcContainerAppInfo -containerName $extensionContainerName -symbolsOnly
$appInfo = $apps | Where-Object { ($_.Publisher -eq 'Microsoft') -and ($_.Name -eq 'System') }
$appName = $appInfo.Publisher + '_' + $appInfo.Name + '_' + $appInfo.Version + ".app"
Get-BcContainerApp -appFile (Join-Path $symbolPath $appName) -appName 'System' -containerName $extensionContainerName -credential $credential -publisher 'Microsoft'

$extensionAppGUID = [guid]::NewGuid().ToString()
Set-Location $currentLocation
.\CreateAppJson.ps1 -appPath (Join-Path $extensionContainerFolder.FullName 'my') -platform (Get-NavContainerPlatformVersion -containerOrImageName $extensionContainerName) -publisher $publisher -version $appVersion -id $extensionAppGUID -forExtension
.\CreateSettingsJson.ps1 -appPath (Join-Path $extensionContainerFolder.FullName 'al\.vscode') -netPackagesPath (Join-Path $extensionContainerFolder.FullName '.netpackages')
#endregion

#region MigrationAppV1
Set-Location $currentLocation
.\CleanUpTables.ps1 -alFolder (Join-Path $extensionContainerFolder.FullName 'MigrationAppV1')
$migrationAppGUID = [guid]::NewGuid().ToString()
Set-Location $currentLocation
.\CreateAppJson.ps1 -appPath (Join-Path $extensionContainerFolder.FullName 'MigrationAppV1') -platform (Get-NavContainerPlatformVersion -containerOrImageName $extensionContainerName) -publisher $publisher -version 1.0.0.0 -id $migrationAppGUID
try {
    Compile-AppInBcContainer -containerName $extensionContainerName -credential $credential -appProjectFolder (Join-Path $extensionContainerFolder.FullName 'MigrationAppV1') -appOutputFolder (Join-Path $extensionContainerFolder.FullName 'MigrationAppV1')
}
catch {
}
#endregion

#region MigrationAppV2
New-Item -Path (Join-Path $extensionContainerFolder.FullName 'MigrationAppV2') -ItemType Directory | Out-Null
Set-Location $currentLocation
.\CreateAppJson.ps1 -appPath (Join-Path $extensionContainerFolder.FullName 'MigrationAppV2') -platform (Get-NavContainerPlatformVersion -containerOrImageName $extensionContainerName) -publisher $publisher -version 2.0.0.0 -id $migrationAppGUID
Set-Location $currentLocation
.\CreateMigrationJson.ps1 -appPath (Join-Path $extensionContainerFolder.FullName 'MigrationAppV2') -extensionGUID $extensionAppGUID
Set-Location $currentLocation
.\CopyALFiles.ps1 -copyFrom (Join-Path $extensionContainerFolder.FullName 'MigrationAppV1\Src') -copyTo (Join-Path $extensionContainerFolder.FullName 'MigrationAppV2') -platform (Get-NavContainerPlatformVersion -containerOrImageName $extensionContainerName)
try {
    Compile-AppInBcContainer -containerName $extensionContainerName -credential $credential -appProjectFolder (Join-Path $extensionContainerFolder.FullName 'MigrationAppV2') -appOutputFolder (Join-Path $extensionContainerFolder.FullName 'MigrationAppV2')
}
catch {
}
#endregion

#region Dependencies
if (!([string]::IsNullOrEmpty($addonAppsFolder))) {
    New-Item -Path (Join-Path $extensionContainerFolder.FullName 'my\AddonAppsFolder') -ItemType Directory | Out-Null
    foreach ($appFile in Get-ChildItem $addonAppsFolder -Filter '*.app') {
        Copy-Item ($appFile.FullName) -Destination (Join-Path $extensionContainerFolder.FullName 'my\AddonAppsFolder')
        Copy-Item ($appFile.FullName) -Destination (Join-Path $extensionContainerFolder.FullName 'al\.alpackages')
    }
    Invoke-ScriptInBCContainer -containerName $extensionContainerName -scriptblock {
        $jsonfile = Get-Content "C:\Run\my\app.json" -Encoding UTF8 -raw | ConvertFrom-Json
    
        foreach ($appFile in Get-ChildItem 'C:\Run\my\AddonAppsFolder' -Filter '*.app') {
            $appinfo = Get-NAVAppInfo -Path $appFile.FullName
            $dependency = @()
            $dependency += [PSCustomObject]@{
                'id'        = $appinfo.AppId
                'name'      = $appinfo.Name
                'publisher' = $appinfo.Publisher
                'version'   = $appinfo.Version           
            }
            $jsonfile.dependencies += $dependency
        }
        $jsonfile | ConvertTo-Json | Set-Content -Path 'C:\Run\my\app.json' -Encoding UTF8    
    }    
}
Copy-Item (Join-Path $extensionContainerFolder.FullName 'my\app.json') -Destination (Join-Path $extensionContainerFolder.FullName 'al')
#endregion

Stop-BcContainer -containerName $extensionContainerName