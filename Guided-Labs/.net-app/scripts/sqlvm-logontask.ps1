# Makes the SQL VM lab-ready, and is safe to run any number of times.
#
# configure-sqlvm.ps1 already does all of this at deployment time, minutes after the VM's
# first boot. This runs much later - webvm-logon-install.ps1 sends it over with
# Invoke-AzVMRunCommand once both VMs are up - so it is the last chance to fix anything that
# did not take the first time, and it is the reason the lab does not need anyone to RDP in
# and run a script by hand. Everything below no-ops when it is already in place.
param (
    # The demouser/SQL password, passed through by webvm-logon-install.ps1. Only needed if
    # the PUWebSite login still has to be created.
    [Parameter(Mandatory=$False)] [string] $SqlPass = ""
)

$ServerName   = 'SQLSERVER2008'
$DatabaseName = 'PartsUnlimited'

# --- The database and the login the web application connects with -----------------------
#
# Without these, http://localhost on the WebVM returns HTTP 500 ("Login failed for user
# 'PUWebSite'") and Exercise 1, Task 1 has no PartsUnlimited database to open in SSMS.
function Invoke-Sql {
    param([string] $Statement, [hashtable] $SqlArgs)
    try {
        Invoke-Sqlcmd $Statement @SqlArgs -ErrorAction Stop
    }
    catch {
        Write-Warning "Statement failed: $Statement"
        Write-Warning "  $($_.Exception.Message)"
    }
}

if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
    Write-Warning "Invoke-Sqlcmd is not available - cannot check the $DatabaseName database"
}
else {
    # SQL Server 2019 presents a self-signed certificate and recent SqlServer modules default
    # to Encrypt=True with certificate validation, so an unqualified call fails with "The
    # certificate chain was issued by an authority that is not trusted". Only pass the switch
    # when the installed module actually has it.
    $sqlArgs = @{ ServerInstance = $ServerName; QueryTimeout = 3600 }
    if ((Get-Command Invoke-Sqlcmd).Parameters.ContainsKey('TrustServerCertificate')) {
        $sqlArgs['TrustServerCertificate'] = $true
    }

    if ((Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue).Status -ne 'Running') {
        Start-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue
    }

    $db    = Invoke-Sqlcmd "SELECT name FROM sys.databases WHERE name = '$DatabaseName'" @sqlArgs -ErrorAction SilentlyContinue
    $login = Invoke-Sqlcmd "SELECT name FROM sys.sql_logins WHERE name = 'PUWebSite'" @sqlArgs -ErrorAction SilentlyContinue

    if ($db -and $login) {
        Write-Host "$DatabaseName database and PUWebSite login are already present"
    }
    elseif (-not $SqlPass) {
        Write-Error "$DatabaseName or the PUWebSite login is missing and no password was passed in - cannot repair. See C:\WindowsAzure\Logs\CloudLabsCustomScriptExtension.txt on this VM."
    }
    else {
        Write-Warning ("Repairing SQL setup - database present: {0}, PUWebSite login present: {1}" -f [bool]$db, [bool]$login)

        # Each statement is guarded with IF ... IS NULL so the set is safe to repeat, and each
        # runs on its own so one failure does not skip the rest. ALTER DATABASE ... SET
        # DISABLE_BROKER in particular needs exclusive access and can lose to another
        # connection; when it did, the CREATE LOGIN after it used to never run.
        $statements = @(
            "IF DB_ID('$DatabaseName') IS NULL CREATE DATABASE [$DatabaseName]"
            "ALTER DATABASE [$DatabaseName] SET DISABLE_BROKER;"
            "IF SUSER_ID('PUWebSite') IS NULL CREATE LOGIN PUWebSite WITH PASSWORD = '$SqlPass';"
            "USE [$DatabaseName];IF USER_ID('PUWebSite') IS NULL CREATE USER PUWebSite FOR LOGIN [PUWebSite];EXEC sp_addrolemember 'db_owner', 'PUWebSite';"
            "EXEC sp_addsrvrolemember @loginame = N'PUWebSite', @rolename = N'sysadmin';"
            # Mixed-mode auth. Without this, SQL logins are rejected with exactly "Login
            # failed for user" even when they exist. Needs the service restart below.
            "EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'LoginMode', REG_DWORD, 2"
        )
        foreach ($statement in $statements) { Invoke-Sql -Statement $statement -SqlArgs $sqlArgs }

        Restart-Service -Force MSSQLSERVER
        # In case the restart failed but the service was shut down.
        Start-Service -Name 'MSSQLSERVER'
        Start-Sleep -Seconds 20

        $db    = Invoke-Sqlcmd "SELECT name FROM sys.databases WHERE name = '$DatabaseName'" @sqlArgs -ErrorAction SilentlyContinue
        $login = Invoke-Sqlcmd "SELECT name FROM sys.sql_logins WHERE name = 'PUWebSite'" @sqlArgs -ErrorAction SilentlyContinue
        if ($db -and $login) {
            Write-Host "$DatabaseName database and PUWebSite login are now present"
        } else {
            Write-Error ("SQL setup still INCOMPLETE - database present: {0}, PUWebSite login present: {1}" -f [bool]$db, [bool]$login)
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
