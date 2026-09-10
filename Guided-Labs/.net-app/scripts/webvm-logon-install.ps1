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

# Deploy the site files, with IIS stopped.
#
# IIS must be stopped first. Now that the ASP.NET Core module is installed, w3wp actually
# loads the app and holds its DLLs open, and Expand-Archive -Force deletes each existing
# file before rewriting it. Against a running app pool that fails with:
#   Remove-Item : Cannot remove item C:\inetpub\wwwroot\Microsoft.EntityFrameworkCore.*.dll
#   Access to the path '...' is denied.  (UnauthorizedAccessException)
# This never showed up before because the app could not start at all, so nothing was locked.
function Deploy-Website {
    $siteZip = "C:\MCW\MCW-App-modernization-$branchName\Hands-on lab\lab-files\PartsUnlimitedWebsite.zip"
    $configJson = "C:\MCW\MCW-App-modernization-$branchName\Hands-on lab\lab-files\src\src\PartsUnlimitedWebsite\config.json"
    $webRoot = 'C:\inetpub\wwwroot'

    Wait-Install
    Write-Host "Stopping IIS so the site files are not locked"
    iisreset.exe /stop

    try {
        Write-Host "Copying default website files..."
        Expand-Archive -LiteralPath $siteZip -DestinationPath $webRoot -Force

        Write-Host "Updating config.json with the SQL IP Address and connection string information."
        Copy-Item $configJson -Destination $webRoot -Force

        # The shipped web.config sends stdout to '\\?\%home%\LogFiles\stdout', which is an
        # App Service path - %home% does not exist on IIS, so the module logs
        # "Could not start stdout file redirection ... The system cannot find the path
        # specified" and the app's own exceptions go nowhere. Repoint it at a real folder so
        # a request-time 500 (a bad connection string, an unreachable database) is
        # diagnosable from the VM instead of needing another deployment.
        $webConfig = Join-Path $webRoot 'web.config'
        $stdoutDir = 'C:\inetpub\logs\stdout'
        New-Item -ItemType Directory -Path $stdoutDir -Force | Out-Null
        if (Test-Path $webConfig) {
            (Get-Content $webConfig -Raw).Replace('\\?\%home%\LogFiles\stdout', "$stdoutDir\stdout") |
                Set-Content -Path $webConfig -Encoding UTF8
            Write-Host "  app stdout log -> $stdoutDir\stdout*.log"
        }
    }
    finally {
        Write-Host "Starting IIS"
        iisreset.exe /start
    }

    # The app cannot start without these two, so fail loudly rather than at the HTTP check.
    foreach ($required in 'PartsUnlimitedWebsite.dll', 'web.config', 'config.json') {
        if (Test-Path (Join-Path $webRoot $required)) {
            Write-Host "  $required deployed"
        } else {
            Write-Error "  $required is MISSING from $webRoot"
        }
    }
}

Deploy-Website

Unregister-ScheduledTask -TaskName "Install Lab Requirements" -Confirm:$false

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
    # Do NOT re-expand the site files here. Deploy-Website already placed them with IIS
    # stopped, and re-expanding over a running app pool is what produced
    # "Access to the path ... is denied" on the EntityFrameworkCore DLLs. Re-extracting the
    # same zip up to seven times has never fixed a 500 anyway - the causes seen so far were
    # a missing ASP.NET Core module and a missing database, neither fixed by copying files.
    # Restart the app and report why it is failing instead.
    Write-Host "Restarting IIS and re-checking"
    iisreset.exe /restart

    # Whatever is making the app return 500 is recorded by the ASP.NET Core module, so
    # surface it in this transcript rather than needing another deployment to find it.
    $ancmEvents = Get-WinEvent -LogName Application -MaxEvents 200 -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -like '*AspNetCore*' -or $_.ProviderName -eq 'IIS AspNetCore Module V2' } |
        Select-Object -First 3
    if ($ancmEvents) {
        Write-Host "--- most recent ASP.NET Core module events ---"
        $ancmEvents | ForEach-Object { Write-Host "[$($_.TimeCreated)] $($_.Message)" }
        Write-Host "--- end ---"
    }

    # If the module reports the app started but requests still 500, the exception is the
    # app's own - and it is almost always the database. This is where it says so.
    $stdoutLog = Get-ChildItem 'C:\inetpub\logs\stdout\stdout*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($stdoutLog) {
        Write-Host "--- tail of $($stdoutLog.Name) ---"
        Get-Content $stdoutLog.FullName -Tail 25
        Write-Host "--- end ---"
    }
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
