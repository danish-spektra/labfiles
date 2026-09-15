Start-Transcript -Path C:\WindowsAzure\Logs\CloudLabsCustomScriptExtension1.txt -Append

$commonscriptpath = "replacepath\cloudlabs-common\cloudlabs-windows-functions.ps1"
. $commonscriptpath

# Both placeholders are substituted by configure-webvm.ps1 before this script is scheduled.
# $SqlPass is handed to sqlvm-logontask.ps1 at the bottom so it can make certain the
# PartsUnlimited database and the PUWebSite login exist on the SQL VM. Single quotes,
# so a password containing $ is not read as a PowerShell variable once substituted.
$SqlPass = 'replacesqlpass'


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
        # The module writes this log as the app pool identity, which only inherits read
        # from C:\inetpub\logs. Without this grant it logs
        #   Could not start stdout file redirection ... create_directories: Access is denied
        # and the app's own exceptions go nowhere - which is the one thing this redirect
        # exists to capture. IIS_IUSRS covers ApplicationPoolIdentity.
        icacls $stdoutDir /grant "IIS_IUSRS:(OI)(CI)M" | Out-Null
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

# configure-webvm.ps1 already deployed the site as SYSTEM, before the reboot. This is only
# here for the case where that did not happen - re-expanding over a working site buys
# nothing and risks locking its DLLs.
if (Test-Path -Path 'C:\inetpub\wwwroot\PartsUnlimitedWebsite.dll' -PathType Leaf) {
    Write-Host "Parts Unlimited site is already deployed - leaving it alone"
} else {
    Write-Warning "Parts Unlimited site is not deployed - deploying it now"
    Deploy-Website
}

# Exercise 5 drives git from a command window and Exercises 5 and 6 both open Visual Studio
# Code, so the lab cannot be completed without them. They are installed here rather than in
# configure-webvm.ps1 so that they do not add to the ARM deployment time - by the time this
# runs the deployment has already been reported complete and the learner is still reading
# the introduction.
InstallChocolatey
InstallGitTools
InstallVSCode

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

# Everything Azure-facing below is wrapped, and none of it decides the post-deployment
# status. The lab user's role assignments are still being applied while this script runs,
# and a failed ARM call used to be indistinguishable from a broken website - which is how
# a role-assignment problem ended up reported as "Post Deployment Failed".
try {
    Connect-AzAccount -Credential $cred -ErrorAction Stop | Out-Null
    Write-Host "Signed in to Azure as $AzureUserName"
}
catch {
    Write-Warning "Could not sign in to Azure: $($_.Exception.Message)"
    Write-Warning "The website check below does not need Azure, so this does not fail the deployment."
}

# Make the SQL VM lab-ready BEFORE judging the website, not after.
#
# This used to be the last thing in the script, running minutes after the verdict had
# already been written. So on a deployment where the database was missing, the site was
# marked failed for exactly the problem this call then went and fixed. The web app cannot
# render its home page without the database, so the repair has to come first.
try {
    Invoke-AzVMRunCommand -ResourceGroupName "hands-on-lab-$DeploymentID" -Name 'SqlServer2008' -CommandId 'RunPowerShellScript' -ScriptPath "C:\LabFiles\scripts\sqlvm-logontask.ps1" -Parameter @{ SqlPass = $SqlPass } -ErrorAction Stop
    Write-Host "sqlvm-logontask.ps1 ran on SqlServer2008"
}
catch {
    Write-Warning "Could not run sqlvm-logontask.ps1 on SqlServer2008: $($_.Exception.Message)"
    Write-Warning "configure-sqlvm.ps1 does the same work at deployment time - check its transcript on the SQL VM if the PartsUnlimited database or the Exercise 4 tools are missing."
}

# Say whether the app can reach its database, using the app's own connection string.
#
# An HTTP 500 from this site is almost always the database. Without this the transcript
# says "500" and nothing else, and the ASP.NET Core stdout log - the only other place the
# exception would appear - is not guaranteed to be there.
function Test-LabDatabase {
    $configPath = 'C:\inetpub\wwwroot\config.json'
    if (-not (Test-Path -Path $configPath -PathType Leaf)) {
        Write-Warning "  $configPath is missing - the site has no connection string"
        return
    }

    try {
        $connectionString = (Get-Content $configPath -Raw | ConvertFrom-Json).ConnectionStrings.DefaultConnectionString
    }
    catch {
        Write-Warning "  could not read the connection string from $configPath : $($_.Exception.Message)"
        return
    }

    $connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
    try {
        $connection.Open()
        Write-Host "  database reachable - the PartsUnlimited connection string works"
    }
    catch {
        Write-Warning "  DATABASE UNREACHABLE: $($_.Exception.Message)"
    }
    finally {
        $connection.Dispose()
    }
}

# Check the site on localhost, exactly as Exercise 1, Task 1 has the learner do it.
#
# This used to call Get-AzPublicIpAddress and then request the public IP. That made the
# health check depend on the lab user holding Microsoft.Network/publicIPAddresses/read at
# the moment it ran: when that read returned nothing, $vmip was empty, the URL became the
# bare string "http://", every attempt threw, and the environment was reported as failed
# while the website was in fact serving. Whether IIS is up has nothing to do with the
# learner's role assignments, so the check no longer asks Azure anything at all.
$url = "http://localhost"
$HTTP_Status = 0

# The SQL VM reboots at the end of its own setup script. Sleeping between attempts rather
# than racing through all seven in under a minute is what gives it room to come back.
Start-Sleep -Seconds 60

for ($i = 1; $i -le 7 -and $HTTP_Status -ne 200; $i++) {
    Write-Host "Checking the status of website in the attempt $i"

    $HTTP_Response = $null
    try {
        $HTTP_Request = [System.Net.WebRequest]::Create($url)
        $HTTP_Request.Timeout = 120000
        $HTTP_Response = $HTTP_Request.GetResponse()
        $HTTP_Status = [int]$HTTP_Response.StatusCode
    }
    catch {
        Write-Host "Website not responding yet on $url : $($_.Exception.Message)"
    }
    finally {
        if ($HTTP_Response) { $HTTP_Response.Close() }
    }

    if ($HTTP_Status -eq 200) { break }

    Test-LabDatabase

    $ancmEvents = Get-WinEvent -LogName Application -MaxEvents 200 -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -like '*AspNetCore*' -or $_.ProviderName -eq 'IIS AspNetCore Module V2' } | Select-Object -First 3
    if ($ancmEvents) {
        Write-Host "--- most recent ASP.NET Core module events ---"
        $ancmEvents | ForEach-Object { Write-Host "[$($_.TimeCreated)] $($_.Message)" }
        Write-Host "--- end ---"
    }

    $stdoutLog = Get-ChildItem 'C:\inetpub\logs\stdout\stdout*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($stdoutLog) {
        Write-Host "--- tail of $($stdoutLog.Name) ---"
        Get-Content $stdoutLog.FullName -Tail 25
        Write-Host "--- end ---"
    }

    Write-Host "Restarting IIS and re-checking"
    iisreset.exe /restart
    Start-Sleep -Seconds 60
}

if ($HTTP_Status -eq 200) {
    $Validstatus  = "Succeeded"
    $Validmessage = "Post Deployment is successful"
    Write-Host "Post Deployment is successful"
}
else {
    Write-Warning "Validation Failed - see log output"
    $Validstatus  = "Failed"
    $Validmessage = "Post Deployment Failed"
    Write-Host "Post Deployment Failed"
}

CloudlabsManualAgent setStatus

CloudLabsManualAgent Start

Stop-Transcript
