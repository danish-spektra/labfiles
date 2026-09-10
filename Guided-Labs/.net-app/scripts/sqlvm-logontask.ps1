# Safety net for the Data Migration Assistant that Exercise 4 needs. configure-sqlvm.ps1
# already installs it before rebooting; this catches the case where that was interrupted.
# Sent to the SqlServer2008 VM by webvm-logon-install.ps1 via Invoke-AzVMRunCommand, so it
# has to stand alone - and it runs on the path to "lab ready", so it must not reinstall
# what is already there.
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
