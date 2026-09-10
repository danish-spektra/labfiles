Param (
    [Parameter(Mandatory = $true)]
    [string]
    $AzureUserName,

    [string]
    $AzurePassword,

    [string]
    $AzureTenantID,

    [string]
    $AzureSubscriptionID,

    [string]
    $ODLID,

    [string]
    $InstallCloudLabsShadow,

    [string]
    $DeploymentID,

    [string]
    $vmAdminUsername,

    [string]
    $vmAdminPassword,

    [string]
    $trainerUserName,

    [string]
    $trainerUserPassword,

    [string]
    $SidecarEventID,

    [string]
    $SidecarEndpoint,

    [string]
    $SidecarKey
)

Start-Transcript -Path C:\WindowsAzure\Logs\CloudLabsCustomScriptExtension.txt -Append
[Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls
[Net.ServicePointManager]::SecurityProtocol = "tls12, tls11, tls" 

Start-Process -FilePath "C:\Program Files (x86)\Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe" `
    -ArgumentList "/silent /install appguid={56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}&appname=Microsoft%20Edge&needsadmin=True" `
    -Wait
    
Function CreateCredFile($AzureUserName, $AzurePassword, $AzureTenantID, $AzureSubscriptionID, $DeploymentID)
{
    $WebClient = New-Object System.Net.WebClient
    $WebClient.DownloadFile("https://experienceazure.blob.core.windows.net/templates/cloudlabs-common/AzureCreds.txt","C:\LabFiles\AzureCreds.txt")
    $WebClient.DownloadFile("https://experienceazure.blob.core.windows.net/templates/cloudlabs-common/AzureCreds.ps1","C:\LabFiles\AzureCreds.ps1")
    
    New-Item -ItemType directory -Path C:\LabFiles -force

    (Get-Content -Path "C:\LabFiles\AzureCreds.txt") | ForEach-Object {$_ -Replace "AzureUserNameValue", "$AzureUserName"} | Set-Content -Path "C:\LabFiles\AzureCreds.txt"
    (Get-Content -Path "C:\LabFiles\AzureCreds.txt") | ForEach-Object {$_ -Replace "AzurePasswordValue", "$AzurePassword"} | Set-Content -Path "C:\LabFiles\AzureCreds.txt"
    (Get-Content -Path "C:\LabFiles\AzureCreds.txt") | ForEach-Object {$_ -Replace "AzureTenantIDValue", "$AzureTenantID"} | Set-Content -Path "C:\LabFiles\AzureCreds.txt"
    (Get-Content -Path "C:\LabFiles\AzureCreds.txt") | ForEach-Object {$_ -Replace "AzureSubscriptionIDValue", "$AzureSubscriptionID"} | Set-Content -Path "C:\LabFiles\AzureCreds.txt"
    (Get-Content -Path "C:\LabFiles\AzureCreds.txt") | ForEach-Object {$_ -Replace "DeploymentIDValue", "$DeploymentID"} | Set-Content -Path "C:\LabFiles\AzureCreds.txt"
             
    (Get-Content -Path "C:\LabFiles\AzureCreds.ps1") | ForEach-Object {$_ -Replace "AzureUserNameValue", "$AzureUserName"} | Set-Content -Path "C:\LabFiles\AzureCreds.ps1"
    (Get-Content -Path "C:\LabFiles\AzureCreds.ps1") | ForEach-Object {$_ -Replace "AzurePasswordValue", "$AzurePassword"} | Set-Content -Path "C:\LabFiles\AzureCreds.ps1"
    (Get-Content -Path "C:\LabFiles\AzureCreds.ps1") | ForEach-Object {$_ -Replace "AzureTenantIDValue", "$AzureTenantID"} | Set-Content -Path "C:\LabFiles\AzureCreds.ps1"
    (Get-Content -Path "C:\LabFiles\AzureCreds.ps1") | ForEach-Object {$_ -Replace "AzureSubscriptionIDValue", "$AzureSubscriptionID"} | Set-Content -Path "C:\LabFiles\AzureCreds.ps1"
    (Get-Content -Path "C:\LabFiles\AzureCreds.ps1") | ForEach-Object {$_ -Replace "DeploymentIDValue", "$DeploymentID"} | Set-Content -Path "C:\LabFiles\AzureCreds.ps1"

    Copy-Item "C:\LabFiles\AzureCreds.txt" -Destination "C:\Users\Public\Desktop"
}

CreateCredFile $AzureUserName $AzurePassword $AzureTenantID $AzureSubscriptionID $DeploymentID

# Cloning GitHub repository

git clone --branch guided-labs https://github.com/CloudLabsAI-Azure/azureai-samples.git C:\Users\demouser\Downloads\ContosoTrek

# Installing python --version=3.11.9

choco uninstall python python3 python313 -y --force
Start-Sleep -Seconds 30
choco install python --version=3.11.9 -y --force

for ($i=0; $i -lt 3; $i++) {
    Start-Sleep -Seconds 10
    refreshenv
    try {
        $ver = python --version
        Write-Host "Python installed: $ver"
        break
    } catch {
        Write-Host "Waiting for Python to be available... Attempt $($i+1)/3"
    }
}

# Installing Node.js LTS (required for the Rayfin app in Exercise 4).
# Vite 7 needs Node.js 20.19+ or 22.12+; nodejs-lts installs the current 22.x LTS.

choco install nodejs-lts -y --force

for ($i=0; $i -lt 3; $i++) {
    Start-Sleep -Seconds 10
    refreshenv
    try {
        $nodeVer = node --version
        $npmVer = npm --version
        Write-Host "Node.js installed: $nodeVer (npm $npmVer)"
        break
    } catch {
        Write-Host "Waiting for Node.js to be available... Attempt $($i+1)/3"
    }
}

# Pre-install the Rayfin app dependencies so Exercise 4 is ready to deploy
# (users then only fill .env, run 'npx rayfin login', and 'npx rayfin up').

$backendPath = "C:\Users\demouser\Downloads\ContosoTrek\contoso-rag-backend"
if (Test-Path $backendPath) {
    refreshenv
    cmd.exe /c "cd /d `"$backendPath`" && npm install"
    Write-Host "Rayfin app dependencies installed at $backendPath"
} else {
    Write-Host "WARNING: $backendPath not found - skipping npm install. Confirm the 'guided-labs' branch ships contoso-rag-backend."
}

Function updateVMShadowFile
{
#Replace vmAdminUsernameValue with VM Admin UserName in script content 
$drivepath="C:\Users\Public\Documents"
(Get-Content -Path "$drivepath\Shadow.ps1") | ForEach-Object {$_ -Replace "vmAdminUsernameValue", "$vmAdminUsername"} | Set-Content -Path "$drivepath\Shadow.ps1"
#Update random password
net user $trainerUserName $trainerUserPassword
}
updateVMShadowFile

#Install Cloudlabs Modern VM (Windows Server 2012,2016,2019, Windows 10) Validator
Function InstallModernVmValidator
{   #dotnet core is pre-req for vmagent or validator
    choco install dotnetcore -y -force
    #Create C:\CloudLabs\Validator directory
    cmd.exe --% /c sc stop "Spektra CloudLabs VM Agent"
    cmd.exe --% /c sc delete "Spektra CloudLabs VM Agent" BinPath=C:\CloudLabs\Validator\VMAgent\Spektra.CloudLabs.VMAgent.exe start= auto
    Remove-Item -Path C:\CloudLabs\Validator -Recurse
    New-Item -ItemType directory -Path C:\CloudLabs\Validator -Force
    Invoke-WebRequest 'https://experienceazure.blob.core.windows.net/software/vm-validator/VMAgent.zip' -OutFile 'C:\CloudLabs\Validator\VMAgent.zip'
    Expand-Archive -LiteralPath 'C:\CloudLabs\Validator\VMAgent.zip' -DestinationPath 'C:\CloudLabs\Validator' -Force
    Set-ExecutionPolicy -ExecutionPolicy bypass -Force
    cmd.exe --% /c @echo off
    cmd.exe --% /c sc create "Spektra CloudLabs VM Agent" BinPath=C:\CloudLabs\Validator\VMAgent\Spektra.CloudLabs.VMAgent.exe start= auto
    cmd.exe --% /c sc start "Spektra CloudLabs VM Agent"
}
InstallModernVmValidator

# Upgrade PIP

$python = "C:\Python311\python.exe"
& $python -m pip install --upgrade pip

# Installing AzureCLI

Invoke-WebRequest -Uri https://aka.ms/installazurecliwindows -OutFile .\AzureCLI.msi; Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /quiet'; rm .\AzureCLI.msi

# Wait for 10 seconds to ensure installation is complete
Start-Sleep -Seconds 10

Write-Host "Azure cli installation completed"

Function InstallSidecarAgent
{
    Param (
        [Parameter(Mandatory = $true)][string]$SidecarEventID,
        [Parameter(Mandatory = $true)][string]$SidecarEndpoint,
        [Parameter(Mandatory = $true)][string]$SidecarKey,
        [string]$DeploymentID = $env:ComputerName
    )
    $dir = 'C:\CloudLabs\Sidecar'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    # 1. Fetch the agent from the orchestrator itself
    Invoke-WebRequest "$SidecarEndpoint/download/sidecar.zip" -OutFile "$dir\sidecar.zip" -UseBasicParsing
    Expand-Archive -LiteralPath "$dir\sidecar.zip" -DestinationPath $dir -Force

    # 2. Stamp per-event config
    @{
        endpoint      = $SidecarEndpoint
        event_id      = $SidecarEventID
        key           = $SidecarKey
        deployment_id = $DeploymentID
    } | ConvertTo-Json | Set-Content "$dir\config.json" -Encoding ascii

    # 3. Run at every logon
    $Action  = New-ScheduledTaskAction -Execute "$dir\sidecar.exe"
    $Trigger = New-ScheduledTaskTrigger -AtLogOn
    Register-ScheduledTask -TaskName 'CloudLabsLabAssistant' -Action $Action `
        -Trigger $Trigger -RunLevel Limited -Force
    Start-Process "$dir\sidecar.exe" -WindowStyle Hidden

    # 4. Desktop shortcut to the local UI
    Set-Content 'C:\Users\Public\Desktop\Lab Assistant.url' @'
[InternetShortcut]
URL=http://127.0.0.1:7788
'@
}

if ($SidecarEventID -and $SidecarEndpoint -and $SidecarKey) {
    InstallSidecarAgent -SidecarEventID $SidecarEventID -SidecarEndpoint $SidecarEndpoint -SidecarKey $SidecarKey -DeploymentID $DeploymentID
}
else {
    Write-Output "Sidecar values missing - Lab Assistant not installed. SidecarEventID='$SidecarEventID' SidecarEndpoint='$SidecarEndpoint'"
}

Stop-Transcript