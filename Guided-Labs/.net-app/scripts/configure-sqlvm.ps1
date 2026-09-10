param (
    [Parameter(Mandatory=$False)] [string] $SqlPass = "",
    # The VM administrator from the ARM template. Used only as a fallback SQL identity when
    # NT AUTHORITY\SYSTEM turns out not to be a sysadmin on this instance.
    [Parameter(Mandatory=$False)] [string] $VmAdminUser = "demouser"
)

# This script had no transcript, so when the PartsUnlimited database failed to appear
# there was nothing to diagnose it with. Everything below is now captured on the SQL VM.
Start-Transcript -Path C:\WindowsAzure\Logs\CloudLabsCustomScriptExtension.txt -Append

# Disable Internet Explorer Enhanced Security Configuration
function Disable-InternetExplorerESC {
    $AdminKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
    $UserKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"
    Set-ItemProperty -Path $AdminKey -Name "IsInstalled" -Value 0 -Force
    Set-ItemProperty -Path $UserKey -Name "IsInstalled" -Value 0 -Force
    # Explorer is normally not running yet under the SYSTEM context this script runs in;
    # only restart it if it is, rather than logging a "process not found" error.
    Stop-Process -Name Explorer -Force -ErrorAction SilentlyContinue
    Write-Host "IE Enhanced Security Configuration (ESC) has been disabled." -ForegroundColor Green
}

# Disable IE ESC
Disable-InternetExplorerESC

#Enable TLS 1.2
function enable-tls-1.2
{
    If (-Not (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319'))
{
    New-Item 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319' -Force | Out-Null
}
New-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319' -Name 'SystemDefaultTlsVersions' -Value '1' -PropertyType 'DWord' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319' -Name 'SchUseStrongCrypto' -Value '1' -PropertyType 'DWord' -Force | Out-Null

If (-Not (Test-Path 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319'))
{
    New-Item 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319' -Force | Out-Null
}
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319' -Name 'SystemDefaultTlsVersions' -Value '1' -PropertyType 'DWord' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319' -Name 'SchUseStrongCrypto' -Value '1' -PropertyType 'DWord' -Force | Out-Null

If (-Not (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server'))
{
    New-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server' -Force | Out-Null
}
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server' -Name 'Enabled' -Value '1' -PropertyType 'DWord' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server' -Name 'DisabledByDefault' -Value '0' -PropertyType 'DWord' -Force | Out-Null

If (-Not (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client'))
{
    New-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client' -Force | Out-Null
}
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client' -Name 'Enabled' -Value '1' -PropertyType 'DWord' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client' -Name 'DisabledByDefault' -Value '0' -PropertyType 'DWord' -Force | Out-Null

Write-Host 'TLS 1.2 has been enabled. You must restart the Windows Server for the changes to take affect.' -ForegroundColor Cyan
}

enable-tls-1.2

# Enable SQL Server ports on the Windows firewall
function Add-SqlFirewallRule {
    $fwPolicy = $null
    $fwPolicy = New-Object -ComObject HNetCfg.FWPolicy2

    $NewRule = $null
    $NewRule = New-Object -ComObject HNetCfg.FWRule

    $NewRule.Name = "SqlServer"
    # TCP
    $NewRule.Protocol = 6
    $NewRule.LocalPorts = 1433
    $NewRule.Enabled = $True
    $NewRule.Grouping = "SQL Server"
    # ALL
    $NewRule.Profiles = 7
    # ALLOW
    $NewRule.Action = 1
    # Add the new rule
    $fwPolicy.Rules.Add($NewRule)
}

Add-SqlFirewallRule

# Set to $true only when the database and login are verified present. Nothing about this
# lab works without them, so it gates the exit code at the bottom of this script.
$script:SqlSetupOk = $false

# Block until the SQL instance answers a query, or give up after $TimeoutSeconds.
function Wait-SqlOnline {
    param(
        [hashtable] $SqlArgs,
        [int] $TimeoutSeconds = 300
    )
    if ((Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue).Status -ne 'Running') {
        Write-Host "MSSQLSERVER is not running yet - starting it"
        Start-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-Sqlcmd "SELECT 1" @SqlArgs -ErrorAction Stop | Out-Null
            Write-Host "SQL Server is accepting connections"
            return $true
        }
        catch {
            Write-Host "Waiting for SQL Server: $($_.Exception.Message)"
            Start-Sleep -Seconds 10
        }
    }
    Write-Error "SQL Server did not accept connections within $TimeoutSeconds seconds"
    return $false
}

# True only when both the database and the login the web app needs actually exist.
function Test-SqlObjects {
    param([hashtable] $SqlArgs, [string] $DatabaseName)
    $db    = Invoke-Sqlcmd "SELECT name FROM sys.databases WHERE name = '$DatabaseName'" @SqlArgs -ErrorAction SilentlyContinue
    $login = Invoke-Sqlcmd "SELECT name FROM sys.sql_logins WHERE name = 'PUWebSite'" @SqlArgs -ErrorAction SilentlyContinue
    return ([bool]$db -and [bool]$login)
}

# Run the same T-SQL as the VM administrator instead of NT AUTHORITY\SYSTEM.
#
# The extension runs as SYSTEM and cannot change its own SQL login. On Azure SQL Server
# images the VM's local administrator is a sysadmin even where SYSTEM is not, so the only
# way to use it is to launch a process as that user. Start-Process -Credential is
# unreliable from SYSTEM (it wants SeAssignPrimaryToken and a loaded profile), so use a
# scheduled task, which is built for exactly this.
function Invoke-SqlAsVmAdmin {
    param(
        [string[]]  $Statements,
        [string]    $UserName,
        [string]    $Password,
        [hashtable] $SqlArgs
    )

    $taskName   = 'CloudLabsSqlSetup'
    $scriptPath = 'C:\Windows\Temp\cloudlabs-sql-setup.ps1'
    $trust = if ($SqlArgs.ContainsKey('TrustServerCertificate')) { ' -TrustServerCertificate' } else { '' }

    $lines = @('$ErrorActionPreference = ''Stop''')
    foreach ($statement in $Statements) {
        # Emitted inside single quotes, so double any single quotes in the T-SQL.
        $escaped = $statement.Replace("'", "''")
        $lines += "Invoke-Sqlcmd '$escaped' -ServerInstance '$($SqlArgs.ServerInstance)' -QueryTimeout 3600$trust"
    }
    Set-Content -Path $scriptPath -Value $lines -Encoding UTF8

    try {
        Write-Host "Running SQL setup as $UserName via a scheduled task"
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$scriptPath`""
        Register-ScheduledTask -TaskName $taskName -Action $action -User ".\$UserName" -Password $Password -RunLevel Highest -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName

        $deadline = (Get-Date).AddMinutes(5)
        do {
            Start-Sleep -Seconds 5
            $state = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
        } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)
        Write-Host "Scheduled task finished in state '$state'"
    }
    catch {
        Write-Warning "Could not run SQL setup as ${UserName}: $($_.Exception.Message)"
    }
    finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

# Create the PartsUnlimited database and the PUWebSite login the web app connects with.
function Setup-Sql {
    #Add snap-in
    Add-PSSnapin SqlServerCmdletSnapin* -ErrorAction SilentlyContinue

    $ServerName = 'SQLSERVER2008'
    $DatabaseName = 'PartsUnlimited'

    if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
        Write-Error "Invoke-Sqlcmd is not available - the SqlServer/SQLPS module is missing, so $DatabaseName cannot be created."
        return
    }

    # SQL Server 2019 presents a self-signed certificate. Recent SqlServer modules use
    # Microsoft.Data.SqlClient, which defaults to Encrypt=True *with* certificate
    # validation, so an unqualified Invoke-Sqlcmd fails with "The certificate chain was
    # issued by an authority that is not trusted" and the database is never created.
    # Only pass -TrustServerCertificate when the installed module supports it, so this
    # keeps working on older modules where it is not a valid parameter.
    $sqlArgs = @{ ServerInstance = $ServerName; QueryTimeout = 3600 }
    if ((Get-Command Invoke-Sqlcmd).Parameters.ContainsKey('TrustServerCertificate')) {
        $sqlArgs['TrustServerCertificate'] = $true
        Write-Host "Using -TrustServerCertificate for Invoke-Sqlcmd"
    }

    # This extension runs minutes after the VM's first boot, and MSSQLSERVER is often still
    # starting - Invoke-Sqlcmd then fails, nothing is created, and it surfaces much later as
    # "Login failed for user 'PUWebSite'" from the web app. Wait for the instance to
    # actually accept a query before touching it.
    if (-not (Wait-SqlOnline -SqlArgs $sqlArgs)) { return }

    # Who are we, and may we actually create a database?
    # A working connection proves nothing: SELECT 1 needs no privilege, while CREATE
    # DATABASE needs sysadmin or dbcreator. This extension runs as NT AUTHORITY\SYSTEM,
    # which is not a sysadmin on every SQL Server image - and that is the difference
    # between "SQL is not ready yet" and "SQL will not let us", which look identical from
    # the outside and is why this took several deployments to pin down.
    $canCreate = $false
    try {
        $who = Invoke-Sqlcmd "SELECT SUSER_NAME() AS [login], IS_SRVROLEMEMBER('sysadmin') AS [sysadmin], IS_SRVROLEMEMBER('dbcreator') AS [dbcreator]" @sqlArgs -ErrorAction Stop
        Write-Host "Connected to SQL as '$($who.login)' - sysadmin=$($who.sysadmin) dbcreator=$($who.dbcreator)"
        $canCreate = ($who.sysadmin -eq 1 -or $who.dbcreator -eq 1)
    }
    catch {
        Write-Warning "Could not read SQL identity: $($_.Exception.Message)"
    }

    # One copy of the statements, so the direct path and the fallback run the same thing.
    # Each is guarded with IF ... IS NULL, so the whole set is safe to repeat.
    $statements = @(
        "IF DB_ID('$DatabaseName') IS NULL CREATE DATABASE [$DatabaseName]"
        "ALTER DATABASE [$DatabaseName] SET DISABLE_BROKER;"
        "IF SUSER_ID('PUWebSite') IS NULL CREATE LOGIN PUWebSite WITH PASSWORD = '$SqlPass';"
        "USE [$DatabaseName];IF USER_ID('PUWebSite') IS NULL CREATE USER PUWebSite FOR LOGIN [PUWebSite];EXEC sp_addrolemember 'db_owner', 'PUWebSite';"
        "EXEC sp_addsrvrolemember @loginame = N'PUWebSite', @rolename = N'sysadmin';"
        # Mixed-mode auth. Without this, SQL logins are rejected with exactly
        # "Login failed for user" even when they exist. Needs the service restart below.
        "EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'LoginMode', REG_DWORD, 2"
    )

    if ($canCreate) {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Write-Host "Configuring $DatabaseName (attempt $attempt)"
                foreach ($statement in $statements) { Invoke-Sqlcmd $statement @sqlArgs -ErrorAction Stop }
                break
            }
            catch {
                Write-Warning "Attempt $attempt failed: $($_.Exception.Message)"
                Start-Sleep -Seconds 15
            }
        }
    }
    else {
        Write-Warning "NT AUTHORITY\SYSTEM cannot create databases on this instance."
    }

    # This fallback is why the lab no longer needs a human with SSMS: if the objects still
    # are not there, run the identical statements as the VM administrator, which is a
    # sysadmin on these images even when SYSTEM is not.
    if (-not (Test-SqlObjects -SqlArgs $sqlArgs -DatabaseName $DatabaseName)) {
        Invoke-SqlAsVmAdmin -Statements $statements -UserName $VmAdminUser -Password $SqlPass -SqlArgs $sqlArgs
    }

    Restart-Service -Force MSSQLSERVER
    #In case restart failed but service was shut down.
    Start-Service -Name 'MSSQLSERVER'
    Wait-SqlOnline -SqlArgs $sqlArgs | Out-Null

    # Exercise 1 has the learner open this database in SSMS, and the web app connects to it,
    # so verify both objects rather than trusting the statements above. $script:SqlSetupOk
    # is what decides whether this deployment is allowed to be reported as successful.
    $dbOk = Invoke-Sqlcmd "SELECT name FROM sys.databases WHERE name = '$DatabaseName'" @sqlArgs -ErrorAction SilentlyContinue
    $loginOk = Invoke-Sqlcmd "SELECT name FROM sys.sql_logins WHERE name = 'PUWebSite'" @sqlArgs -ErrorAction SilentlyContinue

    if ($dbOk -and $loginOk) {
        Write-Host "$DatabaseName database and PUWebSite login are present" -ForegroundColor Green
        $script:SqlSetupOk = $true
    } else {
        Write-Error ("SQL setup INCOMPLETE - database present: {0}, PUWebSite login present: {1}. Exercise 1 and the web app will both fail." -f [bool]$dbOk, [bool]$loginOk)
    }
}

Setup-Sql


$env:chocolateyUseWindowsCompression = 'true'
$env:chocolateyIgnoreRebootDetected = 'true'
$env:chocolateyVersion = '1.4.0'
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
choco feature enable -n allowGlobalConfirmation
choco install dotnetfx -y -force

# Download and install the Data Migration Assistant. Exercise 4 depends on this being
# present, so it is retried until the installed-programs registry confirms it - but only
# retried when it is actually missing, rather than installing twice every deployment.
function Test-DmaInstalled {
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    [bool](Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
           Where-Object { $_.DisplayName -like '*Data Migration Assistant*' })
}

for ($attempt = 1; $attempt -le 3 -and -not (Test-DmaInstalled); $attempt++) {
    Write-Host "Installing Data Migration Assistant (attempt $attempt)" -ForegroundColor Green
    (New-Object System.Net.WebClient).DownloadFile('https://download.microsoft.com/download/C/6/3/C63D8695-CEF2-43C3-AF0A-4989507E429B/DataMigrationAssistant.msi', 'C:\DataMigrationAssistant.msi')
    Start-Process -file 'C:\DataMigrationAssistant.msi' -arg '/qn /l*v C:\dma_install.txt' -passthru | wait-process
}

if (Test-DmaInstalled) {
    Write-Host "Data Migration Assistant is installed"
} else {
    Write-Error "Data Migration Assistant did not install - see C:\dma_install.txt"
}

Stop-Transcript

# Fail the extension rather than hand over a broken lab.
#
# Previously this script could fail to create the database and still exit 0, so the ARM
# deployment reported "status":"success" and the learner got an environment where
# Exercise 1 and localhost were both dead - recoverable only by someone running SQL by
# hand. A non-zero exit makes CloudLabs see the deployment fail so it can reprovision.
#
# This is the one deliberate behaviour change here: a deployment that used to "succeed"
# broken will now fail. Delete this block to go back to the old behaviour.
if (-not $script:SqlSetupOk) {
    Write-Error "SQL configuration did not complete - failing this extension deliberately."
    exit 1
}

Restart-Computer
