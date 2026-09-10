param (
    [Parameter(Mandatory=$False)] [string] $SqlIP = "",
    [Parameter(Mandatory=$False)] [string] $SqlPass = "",
    [Parameter(Mandatory = $true)]
    [string]
    $AzureUserName,

    [string]
    $AzurePassword,

    [string]
    $ODLID,

    [string]
    $InstallCloudLabsShadow,

    [string]
    $DeploymentID,
    
    [string]
    $AzureTenantID,
  
    [string]
    $AzureSubscriptionID,

    [string]
    $adminPassword,

    # Where the other lab scripts are published. Passed in by the ARM template so the
    # repo, branch and folder live in one place; the default keeps the script runnable
    # by hand. Change it in arm.json, not here.
    [string]
    $ScriptsBaseUri = "https://raw.githubusercontent.com/danish-spektra/labfiles/main/Guided-Labs/.net-app/scripts/"
)

Start-Transcript -Path C:\WindowsAzure\Logs\CloudLabsCustomScriptExtension.txt -Append

$vmAdminUsername="demouser"
$trainerUserName="trainer"
$trainerUserPassword="$adminPassword"

Install-WindowsFeature -name Web-Server -IncludeManagementTools

$branchName = "microsoft-app-modernization-v2"

# The lab deployment scripts live next to this one in the labfiles repo. Download the ones
# that run after this script to a stable path - the CustomScriptExtension Downloads folder
# is documented as not durable over the life of the VM, and these run after a reboot.
# Tolerate a trailing slash on the parameter (assigns back to the same variable -
# PowerShell variable names are case-insensitive).
$ScriptsBaseUri = $ScriptsBaseUri.TrimEnd('/')
$labScriptsPath = "C:\LabFiles\scripts"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Path $labScriptsPath -Force | Out-Null

foreach ($scriptName in @("webvm-logon-install.ps1", "sqlvm-logontask.ps1")) {
    Write-Host "Downloading $scriptName from $ScriptsBaseUri" -ForegroundColor Green
    Invoke-WebRequest -Uri "$ScriptsBaseUri/$scriptName" -OutFile "$labScriptsPath\$scriptName" -UseBasicParsing
}

# Download and extract the lab source code - the Parts Unlimited solution that exercises
# 5 and 6 open from C:\MCW. Only the source code comes from the repo; the scripts above
# come from the templates container.
#
# Use the archive/refs/heads endpoint, not zipball: it extracts straight to
# MCW-App-modernization-<branch>, which is the folder name the lab guide has hard-coded,
# so no rename is needed. Retry because the ZIP occasionally arrives corrupted, and
# verify against a file the later steps actually need.
$repoRoot = "C:\MCW\MCW-App-modernization-$branchName"
$repoCheckFile = "$repoRoot\Hands-on lab\lab-files\PartsUnlimitedWebsite.zip"

New-Item -ItemType Directory -Path C:\MCW -Force | Out-Null

for ($attempt = 1; $attempt -le 5 -and -not (Test-Path -Path $repoCheckFile -PathType Leaf); $attempt++) {
    Write-Host "Downloading MCW-App-modernization from GitHub (attempt $attempt)" -ForegroundColor Green
    (New-Object System.Net.WebClient).DownloadFile("https://github.com/CloudLabs-MCW/MCW-App-modernization/archive/refs/heads/$branchName.zip", 'C:\MCW.zip')
    Expand-Archive -LiteralPath 'C:\MCW.zip' -DestinationPath 'C:\MCW' -Force
}

if (Test-Path -Path $repoCheckFile -PathType Leaf) {
    Write-Host "Lab source code extracted to $repoRoot"
} else {
    Write-Error "Lab source code was not extracted to $repoRoot - exercises 5 and 6 will fail"
}

# Replace SQL Connection String
$item = $repoRoot
Write-Host "Server=$SqlIP;Database=PartsUnlimited;User Id=PUWebSite;Password=$SqlPass;"
# The config.release.json file is populated with configuration data during compile and release from VS.  config.json is used by the solution on the WebM.
((Get-Content -path "$item\Hands-on lab\lab-files\src\src\PartsUnlimitedWebsite\config.release.json" -Raw) -replace 'SETCONNECTIONSTRING',"Server=$SqlIP;Database=PartsUnlimited;User Id=PUWebSite;Password=$adminPassword;") | Set-Content -Path "$item\Hands-on lab\lab-files\src\src\PartsUnlimitedWebsite\config.json"

#Import Common Functions
$path = pwd
$path=$path.Path
$commonscriptpath = "$path" + "\cloudlabs-common\cloudlabs-windows-functions.ps1"
. $commonscriptpath


# Enable Embedded shadow
Enable-CloudLabsEmbeddedShadow $vmAdminUsername $trainerUserName $trainerUserPassword

CloudLabsManualAgent Install

CreateCredFile $AzureUserName $AzurePassword $AzureTenantID $AzureSubscriptionID $DeploymentID
az provider register --namespace "Microsoft.LoadTestService"

# Schedule Installs for first Logon
$argument = "-File `"$labScriptsPath\webvm-logon-install.ps1`""
$triggerAt = New-ScheduledTaskTrigger -AtLogOn -User demouser
$action = New-ScheduledTaskAction -Execute "powershell" -Argument $argument 
Register-ScheduledTask -TaskName "Install Lab Requirements" -Trigger $triggerAt -Action $action -User demouser

#Replace Path
# $path is this script's working directory, where the extension also placed
# cloudlabs-common\cloudlabs-windows-functions.ps1 for the logon script to dot-source.

(Get-Content "$labScriptsPath\webvm-logon-install.ps1") -replace "replacepath","$path" | Set-Content "$labScriptsPath\webvm-logon-install.ps1" -Verbose

#Autologin
$Username = "demouser"
$Pass = "$adminPassword"
$RegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $RegistryPath 'AutoAdminLogon' -Value "1" -Type String 
Set-ItemProperty $RegistryPath 'DefaultUsername' -Value "$Username" -type String 
Set-ItemProperty $RegistryPath 'DefaultPassword' -Value "$Pass" -type String


$Validstatus="Pending"  ##Failed or Successful at the last step
$Validmessage="Post Deployment is Pending"

#Set the final deployment status
CloudlabsManualAgent setStatus

Stop-Transcript  

Restart-Computer
