Start-Transcript -Path C:\WindowsAzure\Logs\CloudLabsCustomScriptExtension1.txt -Append

$commonscriptpath = "replacepath\cloudlabs-common\cloudlabs-windows-functions.ps1"
. $commonscriptpath


function Wait-Install {
    $msiRunning = 1
    $msiMessage = ""
    while($msiRunning -ne 0)
    {
        try
        {
            $Mutex = [System.Threading.Mutex]::OpenExisting("Global\_MSIExecute");
            $Mutex.Dispose();
            $DST = Get-Date
            $msiMessage = "An installer is currently running. Please wait...$DST"
            Write-Host $msiMessage 
            $msiRunning = 1
        }
        catch
        {
            $msiRunning = 0
        }
        Start-Sleep -Seconds 1
    }
}
$branchName = "microsoft-app-modernization-v2"
# Install App Service Migration Assistant (exercises 1 and 3 both need it).
# Only run the staged installer if it is actually there - the same missing-installer
# error the Edge MSI produced. The check below still downloads it if this leaves it
# uninstalled, so a missing staged MSI self-heals.
$asmaInstaller = 'C:\AppServiceMigrationAssistant.msi'
if (Test-Path -Path $asmaInstaller -PathType Leaf) {
    Wait-Install
    Write-Host "Installing App Service Migration Assistant..."
    Start-Process -file $asmaInstaller -arg '/qn /l*v C:\asma_install.txt' -passthru | wait-process
} else {
    Write-Host "$asmaInstaller not staged on the image - will download it below"
}

# checking AppServiceMigrationAssistant installation
$Testpath = 'C:\Users\demouser\AppData\Local\Programs\azure-appService-migrationAssistant'

Write-Host "Checking for App serviceMigrationassistant installation"
if (Test-Path -Path $Testpath) {
    Write-Host "App service Migration assistant installation is succeeded"
}
else
{
    (New-Object System.Net.WebClient).DownloadFile('https://appmigration.microsoft.com/api/download/windows/AppServiceMigrationAssistant.msi', $asmaInstaller)
    Start-Sleep -s 15
    Wait-Install
    Write-Host "Installing App Service Migration Assistant..."
    Start-Process -file $asmaInstaller -arg '/qn /l*v C:\asma_install.txt' -passthru | wait-process
}

# Install Edge, if the installer was staged on the image. The download URL used during
# image prep now 404s, so the MSI is often absent - and Edge ships with the base image
# anyway, so a missing MSI is not a problem. Only the failed Start-Process was.
$edgeInstaller = 'C:\MicrosoftEdgeEnterpriseX64.msi'
if (Test-Path -Path $edgeInstaller -PathType Leaf) {
    Wait-Install
    Write-Host "Installing Edge..."
    Start-Process -file $edgeInstaller -arg '/qn /l*v C:\edge_install.txt' -passthru | wait-process
} else {
    Write-Host "$edgeInstaller not present - Edge is already on the base image, skipping"
}

# .NET Core 3.1 and the ASP.NET Core hosting bundle are installed by configure-webvm.ps1
# before the reboot, so there is nothing to install here - just confirm they landed,
# because a missing hosting bundle is what makes IIS return 500.19 on this site.
$dotnetExe = "$env:ProgramFiles\dotnet\dotnet.exe"
if (Test-Path -Path $dotnetExe -PathType Leaf) {
    Write-Host "Installed .NET runtimes:"
    & $dotnetExe --list-runtimes
} else {
    Write-Warning "$dotnetExe not found - the site will not start. Check the hosting bundle install in the configure-webvm.ps1 transcript."
}

if (Test-Path "$env:windir\System32\inetsrv\config\schema\aspnetcore_schema_v2.xml") {
    Write-Host "ASP.NET Core module is registered with IIS"
} else {
    Write-Warning "AspNetCoreModuleV2 is NOT registered with IIS - expect HTTP 500.19 (0x8007000d) on the site."
}

# Copy Web Site Files
Wait-Install
Write-Host "Copying default website files..."
Expand-Archive -LiteralPath "C:\MCW\MCW-App-modernization-$branchName\Hands-on lab\lab-files\PartsUnlimitedWebsite.zip" -DestinationPath 'C:\inetpub\wwwroot' -Force

# Copy the database connection string to the web app.
Write-Host "Updating config.json with the SQL IP Address and connection string information."
Copy-Item "C:\MCW\MCW-App-modernization-$branchName\Hands-on lab\lab-files\src\src\PartsUnlimitedWebsite\config.json" -Destination 'C:\inetpub\wwwroot' -Force

Unregister-ScheduledTask -TaskName "Install Lab Requirements" -Confirm:$false

# Restart the app for the startup to pick up the database connection string.
Write-Host "Restarting IIS"
iisreset.exe /restart

CD C:\LabFiles
$credsfilepath = ".\AzureCreds.txt"
$creds = Get-Content $credsfilepath | Out-String | ConvertFrom-StringData
$AzureUserName = "$($creds.AzureUserName)"
$AzurePassword = "$($creds.AzurePassword)"
$DeploymentID = "$($creds.DeploymentID)"
$SubscriptionId = "$($creds.AzureSubscriptionID)"
$passwd = ConvertTo-SecureString $AzurePassword -AsPlainText -Force
$cred = new-object -typename System.Management.Automation.PSCredential -argumentlist $AzureUserName, $passwd

# The image carries stale AzureRM modules alongside Az. If AzureRM's assemblies load
# first, Az.Compute fails to auto-load with "Unable to load one or more of the requested
# types", which would take out Invoke-AzVMRunCommand below. Import the Az modules
# explicitly, in dependency order, so the Az assemblies are the ones bound in this session.
foreach ($azModule in @('Az.Accounts', 'Az.Network', 'Az.Compute')) {
    try {
        Import-Module $azModule -ErrorAction Stop
        Write-Host "Loaded $azModule"
    }
    catch {
        Write-Warning "Could not pre-load $azModule : $($_.Exception.Message)"
    }
}

Connect-AzAccount -Credential $cred

Start-Sleep 200
$k = 0 
for ($i=1; ($i + $k) -le 7; $i++)
{
    $vmipdetails=Get-AzPublicIpAddress -ResourceGroupName "hands-on-lab-$DeploymentID" -Name "WebVM-ip" 

    $vmip=$vmipdetails.IpAddress
 
    $url="http://"+$vmip

    $HTTP_Request = [System.Net.WebRequest]::Create($url)

    $HTTP_Request.timeout = 120000; #2 Minutes

    # Reset per attempt so a previous result cannot be mistaken for this one, and catch
    # the connection failure that getResponse throws while IIS is still starting - it
    # used to surface as an unhandled error in the transcript.
    $HTTP_Status = 0
    $HTTP_Response = $null

    try {
        $HTTP_Response = $HTTP_Request.getResponse()
        $HTTP_Status = [int]$HTTP_Response.StatusCode
    }
    catch {
        Write-Host "Website not responding yet on $url : $($_.Exception.Message)"
    }
    finally {
        if ($HTTP_Response) { $HTTP_Response.Close() }
    }

    Write-Host "Checking the status of website in the attempt $i"
    
if ($HTTP_Status -eq 200) {
     $k = 8
     $Validstatus="Succeeded"  ##Failed or Successful at the last step
     $Validmessage="Post Deployment is successful"
     Write-Host "Post Deployment is successful"
    }
else{
    # Re-deploying the site files is the only thing worth retrying here. Reinstalling the
    # SDK on every attempt (as this used to) cost minutes and never fixed anything - if
    # the site is down because the hosting bundle is missing, no amount of retrying helps.
    $branchName = "microsoft-app-modernization-v2"

    # Copy Web Site Files
    Wait-Install
    Write-Host "Copying default website files..."
    Expand-Archive -LiteralPath "C:\MCW\MCW-App-modernization-$branchName\Hands-on lab\lab-files\PartsUnlimitedWebsite.zip" -DestinationPath 'C:\inetpub\wwwroot' -Force

    # Copy the database connection string to the web app.
    Write-Host "Updating config.json with the SQL IP Address and connection string information."
    Copy-Item "C:\MCW\MCW-App-modernization-$branchName\Hands-on lab\lab-files\src\src\PartsUnlimitedWebsite\config.json" -Destination 'C:\inetpub\wwwroot' -Force

    # Restart the app for the startup to pick up the database connection string.
    Write-Host "Restarting IIS"
    iisreset.exe /restart
} 
}

sleep 120

if ($HTTP_Status -eq 200) {
     $k = 8
     $Validstatus="Succeeded"  ##Failed or Successful at the last step
     $Validmessage="Post Deployment is successful"
     Write-Host "Post Deployment is successful"
    }
else{
    Write-Warning "Validation Failed - see log output"
    $Validstatus="Failed"  ##Failed or Successful at the last step
    $Validmessage="Post Deployment Failed"
     Write-Host "Post Deployment Failed"
} 

Sleep 50

# Safety net only: configure-sqlvm.ps1 already installs the Data Migration Assistant and
# verifies it, and sqlvm-logontask.ps1 no-ops when it is present. So this must not be able
# to fail the post-deployment status - Az.Compute is the module most likely to break on
# this image, and losing a no-op is not worth reporting the deployment as failed.
try {
    Invoke-AzVMRunCommand -ResourceGroupName "hands-on-lab-$DeploymentID" -Name 'SqlServer2008' -CommandId 'RunPowerShellScript' -ScriptPath "C:\LabFiles\scripts\sqlvm-logontask.ps1" -ErrorAction Stop
    Write-Host "sqlvm-logontask.ps1 ran on SqlServer2008"
}
catch {
    Write-Warning "Could not run sqlvm-logontask.ps1 on SqlServer2008: $($_.Exception.Message)"
    Write-Warning "The Data Migration Assistant is installed by configure-sqlvm.ps1 - verify it on the SQL VM if Exercise 4 cannot find it."
}

CloudlabsManualAgent setStatus

CloudLabsManualAgent Start

Stop-Transcript
