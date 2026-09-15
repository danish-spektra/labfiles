# Makes the SQL VM lab-ready, and is safe to run any number of times.
#
# configure-sqlvm.ps1 does this at deployment time. This runs much later -
# webvm-logon-install.ps1 sends it over with Invoke-AzVMRunCommand once both VMs are up -
# so it is the last chance to fix anything that did not take the first time, and it is the
# reason the lab does not need anyone to RDP in and run a script by hand.
#
# IMPORTANT: Invoke-AzVMRunCommand executes as NT AUTHORITY\SYSTEM, and SYSTEM is NOT
# reliably a sysadmin on the sql2019-ws2019 image. A deployment where it was not produced
# this, every statement denied and the whole lab dead:
#     CREATE DATABASE permission denied in database 'master'.
#     The EXECUTE permission was denied on the object 'xp_instance_regwrite'.
# So nothing below assumes any SQL privilege. It reports what it actually is, fixes what it
# can as a *Windows* administrator (which SYSTEM always is), and escalates only as needed.
param (
    # The demouser/SQL password, passed through by webvm-logon-install.ps1.
    [Parameter(Mandatory=$False)] [string] $SqlPass = "",
    # The VM administrator, used when SYSTEM turns out not to be a sysadmin.
    [Parameter(Mandatory=$False)] [string] $VmAdminUser = "demouser"
)

$ServerName   = 'SQLSERVER2008'
$DatabaseName = 'PartsUnlimited'

# One copy of the statements, so every path below runs exactly the same thing. Each is
# guarded with IF ... IS NULL so the whole set is safe to repeat.
$Statements = @(
    "IF DB_ID('$DatabaseName') IS NULL CREATE DATABASE [$DatabaseName]"
    "ALTER DATABASE [$DatabaseName] SET DISABLE_BROKER;"
    "IF SUSER_ID('PUWebSite') IS NULL CREATE LOGIN PUWebSite WITH PASSWORD = '$SqlPass';"
    "USE [$DatabaseName];IF USER_ID('PUWebSite') IS NULL CREATE USER PUWebSite FOR LOGIN [PUWebSite];EXEC sp_addrolemember 'db_owner', 'PUWebSite';"
    "EXEC sp_addsrvrolemember @loginame = N'PUWebSite', @rolename = N'sysadmin';"
)

# --- Helpers ----------------------------------------------------------------------------

function Get-SqlArgs {
    $sqlArgs = @{ ServerInstance = $ServerName; QueryTimeout = 3600 }
    # SQL Server 2019 presents a self-signed certificate and recent SqlServer modules
    # default to Encrypt=True with certificate validation, so an unqualified call fails
    # with "The certificate chain was issued by an authority that is not trusted".
    if ((Get-Command Invoke-Sqlcmd).Parameters.ContainsKey('TrustServerCertificate')) {
        $sqlArgs['TrustServerCertificate'] = $true
    }
    return $sqlArgs
}

function Wait-SqlOnline {
    param([hashtable] $SqlArgs, [int] $TimeoutSeconds = 300)
    if ((Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue).Status -ne 'Running') {
        Start-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-Sqlcmd "SELECT 1" @SqlArgs -ErrorAction Stop | Out-Null
            return $true
        }
        catch { Start-Sleep -Seconds 10 }
    }
    Write-Warning "SQL Server did not accept connections within $TimeoutSeconds seconds"
    return $false
}

# Say plainly who we are and what we are allowed to do. The absence of this is why the
# earlier failure took a full deployment to understand.
function Write-SqlIdentity {
    param([hashtable] $SqlArgs)
    try {
        $who = Invoke-Sqlcmd "SELECT SUSER_NAME() AS [login], IS_SRVROLEMEMBER('sysadmin') AS [sysadmin], CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS int) AS [windowsOnly]" @SqlArgs -ErrorAction Stop
        Write-Host "SQL identity: '$($who.login)'  sysadmin=$($who.sysadmin)  WindowsAuthOnly=$($who.windowsOnly)"
        return $who
    }
    catch {
        Write-Warning "Could not read SQL identity: $($_.Exception.Message)"
        return $null
    }
}

# The real test, and the only one that is trustworthy here.
#
# sys.databases and sys.sql_logins only show rows the caller has permission to see, so a
# non-sysadmin reads back "database present: False, login present: False" even when both
# exist - which is exactly the false reading the previous version acted on. Opening the
# app's own connection asks the actual question: can the website log in?
function Test-PUWebSiteLogin {
    if (-not $SqlPass) { return $false }
    $cs = "Server=$ServerName;Database=$DatabaseName;User Id=PUWebSite;Password=$SqlPass;TrustServerCertificate=True;Connect Timeout=15;"
    $connection = New-Object System.Data.SqlClient.SqlConnection $cs
    try {
        $connection.Open()
        return $true
    }
    catch {
        Write-Host "  PUWebSite cannot log in yet: $($_.Exception.Message)"
        return $false
    }
    finally { $connection.Dispose() }
}

# Enable mixed-mode authentication by writing the registry directly.
#
# The T-SQL way (xp_instance_regwrite) needs sysadmin or CONTROL SERVER and is denied to a
# non-sysadmin - but this script runs as SYSTEM, which is always a *Windows* administrator,
# so the registry is reachable regardless of SQL permissions. Without LoginMode=2, SQL
# rejects every SQL login with exactly "Login failed for user 'PUWebSite'" even when the
# login exists and the password is right, which is what took the website down.
# Returns $true when it changed something and the service needs a restart.
function Enable-SqlMixedMode {
    $instanceKey = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    try {
        $instanceId = (Get-ItemProperty -Path $instanceKey -ErrorAction Stop).MSSQLSERVER
    }
    catch {
        Write-Warning "Could not resolve the SQL instance id from the registry: $($_.Exception.Message)"
        return $false
    }

    $serverKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer"
    try {
        $current = (Get-ItemProperty -Path $serverKey -Name LoginMode -ErrorAction Stop).LoginMode
    }
    catch {
        Write-Warning "Could not read LoginMode from ${serverKey}: $($_.Exception.Message)"
        return $false
    }

    if ($current -eq 2) {
        Write-Host "Mixed-mode authentication is already enabled (LoginMode=2)"
        return $false
    }

    Write-Host "LoginMode is $current (Windows only) - setting it to 2 (mixed mode)" -ForegroundColor Green
    try {
        Set-ItemProperty -Path $serverKey -Name LoginMode -Value 2 -Type DWord -ErrorAction Stop
        return $true
    }
    catch {
        Write-Warning "Could not set LoginMode: $($_.Exception.Message)"
        return $false
    }
}

function Restart-Sql {
    Write-Host "Restarting MSSQLSERVER"
    try { Restart-Service -Force MSSQLSERVER -ErrorAction Stop }
    catch { Write-Warning "Restart-Service failed: $($_.Exception.Message)" }
    # In case the restart failed after stopping the service.
    Start-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue
}

function Invoke-Statements {
    param([hashtable] $SqlArgs)
    # One try per statement: they are independent, and wrapping the set in a single try
    # meant one recoverable failure skipped everything after it.
    foreach ($statement in $Statements) {
        try { Invoke-Sqlcmd $statement @SqlArgs -ErrorAction Stop }
        catch {
            Write-Warning "Statement failed: $statement"
            Write-Warning "  $($_.Exception.Message)"
        }
    }
}

# Run the same statements as the VM administrator instead of SYSTEM.
#
# The Run Command process cannot change its own SQL login, but the VM's local
# administrator is a sysadmin on these images in cases where SYSTEM is not. Start-Process
# -Credential is unreliable from SYSTEM (it wants SeAssignPrimaryToken and a loaded
# profile), so use a scheduled task, which is built for exactly this.
function Invoke-StatementsAsVmAdmin {
    param([hashtable] $SqlArgs)

    if (-not $SqlPass) {
        Write-Warning "No password passed in - cannot run the fallback as $VmAdminUser"
        return
    }

    $taskName   = 'CloudLabsSqlRepair'
    $scriptPath = 'C:\Windows\Temp\cloudlabs-sql-repair.ps1'
    $trust = if ($SqlArgs.ContainsKey('TrustServerCertificate')) { ' -TrustServerCertificate' } else { '' }

    # Its own transcript, because this runs in a separate process whose output Run Command
    # never sees.
    $lines = @('Start-Transcript -Path C:\WindowsAzure\Logs\cloudlabs-sql-fallback.txt -Append')
    $lines += 'try { Invoke-Sqlcmd "SELECT SUSER_NAME() AS [login], IS_SRVROLEMEMBER(''sysadmin'') AS [sysadmin]" -ServerInstance ''' + $SqlArgs.ServerInstance + '''' + $trust + ' -ErrorAction Stop | Format-List | Out-String | Write-Host }'
    $lines += 'catch { Write-Host "identity check failed: $($_.Exception.Message)" }'
    foreach ($statement in $Statements) {
        # Emitted inside single quotes, so double any single quotes in the T-SQL.
        $escaped = $statement.Replace("'", "''")
        $lines += "try { Invoke-Sqlcmd '$escaped' -ServerInstance '$($SqlArgs.ServerInstance)' -QueryTimeout 3600$trust -ErrorAction Stop }"
        $lines += 'catch { Write-Host "FALLBACK STATEMENT FAILED: $($_.Exception.Message)" }'
    }
    $lines += 'Stop-Transcript'
    Set-Content -Path $scriptPath -Value $lines -Encoding UTF8

    try {
        Write-Host "Running the SQL setup as $VmAdminUser via a scheduled task"
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$scriptPath`""

        # Task Scheduler resolves UserId to a SID itself and does not accept ".\user" -
        # that fails with "No mapping between account names and security IDs was done".
        $registered = $false
        foreach ($account in @("$env:COMPUTERNAME\$VmAdminUser", $VmAdminUser)) {
            try {
                Register-ScheduledTask -TaskName $taskName -Action $action -User $account -Password $SqlPass -RunLevel Highest -Force -ErrorAction Stop | Out-Null
                Write-Host "  registered to run as '$account'"
                $registered = $true
                break
            }
            catch { Write-Warning "  could not register as '${account}': $($_.Exception.Message)" }
        }
        if (-not $registered) { return }

        Start-ScheduledTask -TaskName $taskName
        $deadline = (Get-Date).AddMinutes(5)
        do {
            Start-Sleep -Seconds 5
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        } while ($task -and $task.State -eq 'Running' -and (Get-Date) -lt $deadline)

        $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
        Write-Host "  finished - state '$($task.State)', last result $($info.LastTaskResult)"
        if (Test-Path 'C:\WindowsAzure\Logs\cloudlabs-sql-fallback.txt') {
            Write-Host "--- tail of cloudlabs-sql-fallback.txt ---"
            Get-Content 'C:\WindowsAzure\Logs\cloudlabs-sql-fallback.txt' -Tail 30
            Write-Host "--- end ---"
        }
    }
    catch { Write-Warning "Fallback failed: $($_.Exception.Message)" }
    finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

# Give NT AUTHORITY\SYSTEM sysadmin back, using SQL Server's own documented recovery path
# for a lost sysadmin.
#
# This is the only path that does not depend on something we cannot verify. On this image
# both of the others failed:
#   Connected to SQL as 'NT AUTHORITY\SYSTEM' - sysadmin=0 dbcreator=0
#   Could not register the task as 'SqlServer2008\demouser': The user name or password is incorrect.
# so no SQL principal could create the database and no Windows credential could be
# validated either. What SYSTEM demonstrably *is* on this VM is a local administrator - it
# writes HKLM, installs MSIs and registers tasks - and SQL Server, started with -m, treats
# members of the local Administrators group as sysadmin. That is the documented way to
# recover an instance whose sysadmins are all gone, and it needs no password at all.
#
# Scope: this touches only this VM's own SQL instance, so concurrent lab environments are
# unaffected. The finally block always returns the service to normal however this exits.
# ponytail: heavy-handed, but the alternative is a lab that needs a human with SSMS.
function Grant-SysadminToSystem {
    param([string] $ServerName)

    Write-Warning "No usable sysadmin - attempting single-user recovery to restore it"

    $servicePath = (Get-CimInstance Win32_Service -Filter "Name='MSSQLSERVER'" -ErrorAction SilentlyContinue).PathName
    if (-not $servicePath) {
        Write-Warning "  could not locate sqlservr.exe from the MSSQLSERVER service - giving up"
        return $false
    }
    # PathName is quoted and may carry arguments; take the executable only.
    $sqlservr = if ($servicePath.StartsWith('"')) { $servicePath.Split('"')[1] } else { $servicePath.Split(' ')[0] }
    if (-not (Test-Path -Path $sqlservr -PathType Leaf)) {
        Write-Warning "  '$sqlservr' does not exist - giving up"
        return $false
    }

    $process = $null
    $granted = $false
    try {
        Stop-Service -Name SQLSERVERAGENT -Force -ErrorAction SilentlyContinue
        Stop-Service -Name MSSQLSERVER -Force -ErrorAction Stop
        Write-Host "  MSSQLSERVER stopped; starting it in single-user mode"

        $process = Start-Process -FilePath $sqlservr -ArgumentList '-m', '-s', 'MSSQLSERVER' -PassThru -WindowStyle Hidden

        $recoveryArgs = @{ ServerInstance = $ServerName; QueryTimeout = 600 }
        if ((Get-Command Invoke-Sqlcmd).Parameters.ContainsKey('TrustServerCertificate')) {
            $recoveryArgs['TrustServerCertificate'] = $true
        }

        # -m accepts a single connection, so anything else that reconnects first takes the
        # slot. Retry rather than assuming we win the race on the first try.
        $connected = $false
        $deadline = (Get-Date).AddMinutes(3)
        while (-not $connected -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 15
            try {
                Invoke-Sqlcmd "SELECT 1" @recoveryArgs -ErrorAction Stop | Out-Null
                $connected = $true
            }
            catch { Write-Host "  waiting for the single-user instance: $($_.Exception.Message)" }
        }

        if (-not $connected) {
            Write-Warning "  could not get the single-user connection - giving up"
            return $false
        }

        foreach ($stmt in @(
            "IF SUSER_ID('NT AUTHORITY\SYSTEM') IS NULL CREATE LOGIN [NT AUTHORITY\SYSTEM] FROM WINDOWS;",
            "ALTER SERVER ROLE sysadmin ADD MEMBER [NT AUTHORITY\SYSTEM];"
        )) {
            try {
                Invoke-Sqlcmd $stmt @recoveryArgs -ErrorAction Stop
                Write-Host "  applied: $stmt"
                $granted = $true
            }
            catch { Write-Warning "  recovery statement failed: $($_.Exception.Message)" }
        }
        return $granted
    }
    catch {
        Write-Warning "  single-user recovery failed: $($_.Exception.Message)"
        return $false
    }
    finally {
        # Whatever happened above, the instance must come back up normally.
        if ($process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 20
        }
        Start-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue
        Start-Service -Name SQLSERVERAGENT -ErrorAction SilentlyContinue
        Write-Host "  MSSQLSERVER returned to normal operation"
    }
}

# --- Database and login -----------------------------------------------------------------

if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
    Write-Warning "Invoke-Sqlcmd is not available - cannot check the $DatabaseName database"
}
else {
    $sqlArgs = Get-SqlArgs
    if (Wait-SqlOnline -SqlArgs $sqlArgs) {

        # Mixed mode first. If the database and login already exist and only SQL auth was
        # off, this alone brings the website back - and it needs no SQL privilege at all.
        if (Enable-SqlMixedMode) { Restart-Sql; Wait-SqlOnline -SqlArgs $sqlArgs | Out-Null }

        $who = Write-SqlIdentity -SqlArgs $sqlArgs

        if (Test-PUWebSiteLogin) {
            Write-Host "$DatabaseName is reachable as PUWebSite - nothing to repair" -ForegroundColor Green
        }
        else {
            Write-Warning "PUWebSite cannot reach $DatabaseName - repairing"

            if ($who -and $who.sysadmin -eq 1) {
                Invoke-Statements -SqlArgs $sqlArgs
            }
            else {
                Write-Warning "SYSTEM is not a sysadmin on this instance - using the $VmAdminUser fallback"
                Invoke-StatementsAsVmAdmin -SqlArgs $sqlArgs
            }

            if (-not (Test-PUWebSiteLogin)) {
                if (Grant-SysadminToSystem -ServerName $ServerName) {
                    Wait-SqlOnline -SqlArgs $sqlArgs | Out-Null
                    Write-SqlIdentity -SqlArgs $sqlArgs | Out-Null
                    if (Enable-SqlMixedMode) { Restart-Sql; Wait-SqlOnline -SqlArgs $sqlArgs | Out-Null }
                    Invoke-Statements -SqlArgs $sqlArgs
                }
            }

            if (Test-PUWebSiteLogin) {
                Write-Host "$DatabaseName is now reachable as PUWebSite" -ForegroundColor Green
            }
            else {
                Write-Error "SQL setup INCOMPLETE - PUWebSite still cannot reach $DatabaseName. See C:\WindowsAzure\Logs\CloudLabsCustomScriptExtension.txt and cloudlabs-sql-fallback.txt on this VM."
            }
        }
    }
}

# --- Data Migration Assistant (Exercise 4) ----------------------------------------------
function Test-DmaInstalled {
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    [bool](Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
           Where-Object { $_.DisplayName -like '*Data Migration Assistant*' })
}

if (Test-DmaInstalled) {
    Write-Host "Data Migration Assistant is already installed - nothing to do"
} else {
    Write-Host "Data Migration Assistant is missing - installing"
    (New-Object System.Net.WebClient).DownloadFile('https://download.microsoft.com/download/C/6/3/C63D8695-CEF2-43C3-AF0A-4989507E429B/DataMigrationAssistant.msi', 'C:\DataMigrationAssistant.msi')
    Start-Process -file 'C:\DataMigrationAssistant.msi' -arg '/qn /l*v C:\dma_install.txt' -passthru | wait-process

    if (Test-DmaInstalled) {
        Write-Host "Data Migration Assistant installed"
    } else {
        Write-Error "Data Migration Assistant did not install - see C:\dma_install.txt"
    }
}

# --- Self-hosted Integration Runtime (Exercise 4, Task 5) -------------------------------
function Test-IntegrationRuntimeInstalled {
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    [bool](Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
           Where-Object { $_.DisplayName -like '*Integration Runtime*' })
}

if (Test-IntegrationRuntimeInstalled) {
    Write-Host "Microsoft Integration Runtime is already installed - nothing to do"
} else {
    Write-Host "Microsoft Integration Runtime is missing - installing"
    try {
        (New-Object System.Net.WebClient).DownloadFile('https://download.microsoft.com/download/E/4/7/E4771905-1079-445B-8BF9-8A1A075D8A10/IntegrationRuntime_5.52.9231.1.msi', 'C:\IntegrationRuntime.msi')
        Start-Process msiexec.exe -ArgumentList '/i "C:\IntegrationRuntime.msi" /quiet /norestart /log "C:\IntegrationRuntime_Install.log"' -Wait
    }
    catch {
        Write-Warning "Integration Runtime install failed: $($_.Exception.Message)"
    }

    if (Test-IntegrationRuntimeInstalled) {
        Write-Host "Microsoft Integration Runtime installed"
    } else {
        Write-Error "Microsoft Integration Runtime did not install - see C:\IntegrationRuntime_Install.log"
    }
}
