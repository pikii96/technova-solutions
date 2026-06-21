# ==============================================================================
# PROJEKT: TechNova Solutions - CLEANUP
# Verzija:  2.2  |  Aligned with deploy v2.2.2 (VNet Flow Logs)
#
# Brise SVE resurse kreirane deployment skriptom v2.2.2:
#   - Resource Group TechNova-RG i sve unutra (ukljucujuci Workbook)
#   - AKS managed RG (MC_TechNova-RG_*)
#   - Entra ID grupe (tenant-level)
#   - Entra ID Diagnostic Settings
#   - VNet Flow Logs (v2.2 NEW - bivsi NSG Flow Logs)
#   - Orphaned RBAC role assignments
#   - NetworkWatcherRG (uz provjeru drugih regija)
#   - Lokalne log datoteke
#
# Napomena: Defender for Cloud Free tier OSTAJE - subscription level,
# besplatan je i daje korisne security recommendations i nakon brisanja.
# ==============================================================================

$subId    = "7610e582-f4f3-430b-b2c7-7837f0c3db7b"
$rgName   = "TechNova-RG"
$location = "polandcentral"
$aksName  = "technova-aks-prod"
$nsgName  = "technova-nsg-prod"
$lawName  = "technova-logs-prod"
$flowLogName = "technova-vnetflowlog-prod"   # v2.2: bivsi NSG Flow Log, sad VNet

# Entra ID grupe (tenant-level - RG brisanje ih ne dira!)
$entraGroups = @(
    "TechNova-Development",
    "TechNova-Sales",
    "TechNova-Support"
)

# v2.1 NEW: Entra ID Diagnostic Settings name (kreiran od strane v2.2 deploy)
$entraDiagName = "TechNova-EntraID-Audit"

# -----------------------------------------------------------------------------
# LOGGING
# -----------------------------------------------------------------------------
$logFile = "$HOME/TechNova-cleanup-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO", [System.ConsoleColor]$Color = "White")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][$Level] $Message"
    switch ($Level) {
        "OK"    { Write-Host $Message -ForegroundColor Green }
        "WARN"  { Write-Host $Message -ForegroundColor Yellow }
        "ERROR" { Write-Host $Message -ForegroundColor Red }
        "STEP"  { Write-Host "`n$Message" -ForegroundColor Cyan }
        default { Write-Host $Message -ForegroundColor $Color }
    }
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

Add-Content -Path $logFile -Value "================================================================" -Encoding UTF8
Add-Content -Path $logFile -Value "  TechNova Cleanup v2.1 - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Encoding UTF8
Add-Content -Path $logFile -Value "================================================================" -Encoding UTF8

Write-Host @"

+======================================================+
|      TECHNOVA SOLUTIONS - CLEANUP v2.1              |
|      Podrska za v2.2 deployment resurse              |
+======================================================+
"@ -ForegroundColor Red

# =============================================================================
# KORAK 0 - PROVJERA SESIJE
# =============================================================================
Write-Log "---------------------------------------------------------" "INFO"
Write-Log "[0] Provjera sesije" "STEP"

az account set --subscription $subId 2>$null
$currentSub = az account show --query name -o tsv 2>$null
if (!$currentSub) {
    Write-Log "Nisi logiran! Pokreni 'Connect-AzAccount' ili 'az login'." "ERROR"
    exit 1
}
Write-Log "  -> Pretplata: $currentSub" "OK"
Write-Log "  -> Log: $logFile" "INFO"

# =============================================================================
# KORAK 1 - POTVRDA
# =============================================================================
Write-Log "---------------------------------------------------------" "INFO"
Write-Log "[1] Potvrda brisanja" "STEP"

Write-Host ""
Write-Host "  Bit ce obrisano:" -ForegroundColor Yellow
Write-Host "    - Resource Group: $rgName (VMs, LB, VNet, NSG, Storage, AKS, App Service, Workbook...)" -ForegroundColor Yellow
Write-Host "    - AKS Managed RG: MC_${rgName}_${aksName}_${location}" -ForegroundColor Yellow
Write-Host "    - NSG Flow Logs: $flowLogName [v2.1]" -ForegroundColor Yellow
Write-Host "    - Entra ID grupe: $($entraGroups -join ', ')" -ForegroundColor Yellow
Write-Host "    - Entra ID Diagnostic Settings: $entraDiagName [v2.1]" -ForegroundColor Yellow
Write-Host "    - NetworkWatcherRG (uz provjeru)" -ForegroundColor Yellow
Write-Host "    - Lokalne log datoteke u `$HOME" -ForegroundColor Yellow
Write-Host ""
Write-Host "  ZADRZANO (svjesno):" -ForegroundColor Cyan
Write-Host "    - Defender for Cloud Free tier (besplatan, korisne preporuke)" -ForegroundColor Cyan
Write-Host ""
Write-Host "  OVA AKCIJA JE NEPOVRATNA!" -ForegroundColor Red
Write-Host ""

$confirm = Read-Host "  Upisi 'BRISI' za potvrdu (bilo sto drugo = odustani)"
if ($confirm -ne "BRISI") {
    Write-Log "  -> Korisnik odustao. Nista nije obrisano." "WARN"
    exit 0
}
Write-Log "  -> Potvrda primljena: '$confirm'" "INFO"

# =============================================================================
# KORAK 2 - VNet FLOW LOGS (mora se obrisati PRIJE NSG/RG-a)
# Network Watcher resurs ostaje "orphan" ako se ne obrise eksplicitno.
# Flow Log resurs zivi u Network Watcher-u (NetworkWatcherRG), ne u TechNova-RG.
# =============================================================================
Write-Log "---------------------------------------------------------" "INFO"
Write-Log "[2] VNet Flow Logs (prije NSG/VNet brisanja)" "STEP"

# v2.2: try VNet Flow Log first, then legacy NSG Flow Log (backward compat with v2.1 deploy)
$flowLogExists = az network watcher flow-log show --location $location --name $flowLogName --output none 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Log "  -> Brisem VNet Flow Log: $flowLogName..." "WARN"
    az network watcher flow-log delete --location $location --name $flowLogName --output none 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "  -> VNet Flow Log obrisan." "OK"
    } else {
        Write-Log "  -> VNet Flow Log brisanje nije potvrdjeno." "WARN"
    }
} else {
    Write-Log "  -> VNet Flow Log ne postoji: $flowLogName" "INFO"
}

# Backward compat: provjeri i obrisi legacy NSG Flow Log ako postoji (iz starijih deploya)
$legacyFlowLog = "technova-flowlog-prod"
$legacyExists = az network watcher flow-log show --location $location --name $legacyFlowLog --output none 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Log "  -> Brisem legacy NSG Flow Log: $legacyFlowLog (iz v2.1 deploya)..." "WARN"
    az network watcher flow-log delete --location $location --name $legacyFlowLog --output none 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "  -> Legacy NSG Flow Log obrisan." "OK"
    }
}

# =============================================================================
# KORAK 3 - v2.1 NEW: ENTRA ID DIAGNOSTIC SETTINGS (tenant-level)
# Ne brise se s RG-om - mora se brisati REST API-jem
# =============================================================================
Write-Log "---------------------------------------------------------" "INFO"
Write-Log "[3] Entra ID Diagnostic Settings (v2.1 NEW)" "STEP"

$url = "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/${entraDiagName}?api-version=2017-04-01-preview"
az rest --method DELETE --url $url --output none 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Log "  -> Entra ID Diagnostic Settings obrisan: $entraDiagName" "OK"
} else {
    Write-Log "  -> Entra ID Diagnostic Settings ne postoji ili nemas ovlasti" "INFO"
}

# =============================================================================
# KORAK 4 - AKS EXPLICIT STOP + DELETE
# =============================================================================
Write-Log "---------------------------------------------------------" "INFO"
Write-Log "[4] AKS cluster (eksplicitno brisanje)" "STEP"

$aksExists = az aks show --name $aksName --resource-group $rgName --output none 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Log "  -> Brisem AKS: $aksName (sinkrono - cekam da Azure pocisti MC_ grupu)..." "WARN"
    az aks delete --name $aksName --resource-group $rgName --yes 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "  -> AKS obrisan." "OK"
    } else {
        Write-Log "  -> AKS brisanje nije uspjelo - RG brisanje ce ga pocistiti." "WARN"
    }
} else {
    Write-Log "  -> AKS ne postoji ili je vec obrisan." "INFO"
}

$aksRg = "MC_${rgName}_${aksName}_${location}"
$aksRgExists = az group exists --name $aksRg 2>$null
if ($aksRgExists -eq "true") {
    Write-Log "  -> Brisem AKS Managed RG: $aksRg..." "WARN"
    az group delete --name $aksRg --yes --no-wait 2>$null
    Write-Log "  -> Zahtjev poslan za: $aksRg" "OK"
}

# =============================================================================
# KORAK 5 - RBAC ROLE ASSIGNMENTS
# =============================================================================
Write-Log "---------------------------------------------------------" "INFO"
Write-Log "[5] Orphaned RBAC role assignments" "STEP"

$rgScope = "/subscriptions/$subId/resourceGroups/$rgName"
$assignments = az role assignment list --scope $rgScope --query "[].id" -o tsv 2>$null
if ($assignments) {
    foreach ($assignId in $assignments) {
        az role assignment delete --ids $assignId 2>$null | Out-Null
    }
    Write-Log "  -> RBAC assignments s RG scope obrisani." "OK"
} else {
    Write-Log "  -> Nema RBAC assignments za cistiti." "INFO"
}

# =============================================================================
# KORAK 6 - BRISANJE GLAVNE RESOURCE GRUPE (sinkrono)
# Brise: VM, LB, VNet, NSG, Storage, App Service, App Insights, LAW, 
#        Workbook, Action Group, Availability Test, Web Test, alerts
# =============================================================================
Write-Log "---------------------------------------------------------" "INFO"
Write-Log "[6] Brisanje Resource Grupe: $rgName (sinkrono ~5-10 min)" "STEP"

$rgExists = az group exists --name $rgName 2>$null
if ($rgExists -eq "true") {
    Write-Log "  -> Pokrecem brisanje $rgName... (cekaj, ne prekidaj!)" "WARN"
    az group delete --name $rgName --yes 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "  -> $rgName uspjesno obrisan." "OK"
    } else {
        Write-Log "  -> Brisanje $rgName nije potvrdilo uspjeh - provjeri portal." "WARN"
    }
} else {
    Write-Log "  -> $rgName ne postoji." "INFO"
}

# =============================================================================
# KORAK 7 - ENTRA ID GRUPE
# =============================================================================
Write-Log "---------------------------------------------------------" "INFO"
Write-Log "[7] Entra ID grupe (tenant-level resursi)" "STEP"

foreach ($groupName in $entraGroups) {
    $groupId = az ad group show --group $groupName --query id -o tsv 2>$null
    if ($groupId) {
        az ad group delete --group $groupId 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "  -> Entra ID grupa obrisana: $groupName" "OK"
        } else {
            Write-Log "  -> Nije uspjelo brisanje grupe: $groupName (mozda nemas ovlasti)" "WARN"
        }
    } else {
        Write-Log "  -> Entra ID grupa ne postoji: $groupName" "INFO"
    }
}

# =============================================================================
# KORAK 8 - NETWORKWATCHERRG (uz provjeru ima li samo nasi resursi)
# =============================================================================
Write-Log "---------------------------------------------------------" "INFO"
Write-Log "[8] NetworkWatcherRG" "STEP"

$watcherRg     = "NetworkWatcherRG"
$watcherExists = az group exists --name $watcherRg 2>$null
if ($watcherExists -eq "true") {
    $allLocations = az resource list --resource-group $watcherRg --query "[].location" -o tsv 2>$null
    $otherRegions = $allLocations | Where-Object { $_ -ne $location } | Select-Object -Unique

    if ($otherRegions) {
        Write-Log "  -> NetworkWatcherRG sadrzi resurse u DRUGIM regijama: $($otherRegions -join ', ')" "WARN"
        Write-Log "  -> PRESKACEM brisanje - moras rucno obrisati samo polandcentral watcher:" "WARN"
        Write-Log "     az network watcher delete --location $location" "WARN"
    } else {
        Write-Log "  -> NetworkWatcherRG sadrzi samo $location resurse - brisem..." "WARN"
        az group delete --name $watcherRg --yes --no-wait 2>$null
        Write-Log "  -> Zahtjev za brisanje NetworkWatcherRG poslan." "OK"
    }
} else {
    Write-Log "  -> NetworkWatcherRG ne postoji." "INFO"
}

# =============================================================================
# KORAK 9 - LOKALNE DATOTEKE
# =============================================================================
Write-Log "---------------------------------------------------------" "INFO"
Write-Log "[9] Lokalne datoteke" "STEP"

$filesToClean = @(
    "$HOME/technova-debug.txt",
    "$HOME/TechNova-Student.ps1",
    "$HOME/TechNova-Student-v2.2.ps1",
    "$HOME/TechNova-Improved.ps1",
    "$HOME/entra-diag-body.json",
    "$HOME/webtest-template.json",
    "$HOME/workbook-template.json"
)
foreach ($f in $filesToClean) {
    if (Test-Path $f) {
        Remove-Item $f -Force
        Write-Log "  -> Obrisano: $f" "OK"
    }
}

$deployLogs = Get-ChildItem "$HOME/TechNova-deploy-*.log" -ErrorAction SilentlyContinue
if ($deployLogs) {
    Write-Host ""
    Write-Host "  Pronadjeno $($deployLogs.Count) deploy log datoteka:" -ForegroundColor Yellow
    $deployLogs | ForEach-Object { Write-Host "    $_" }
    $delLogs = Read-Host "  Obrisati deploy logove? (da/ne)"
    if ($delLogs -eq "da") {
        $deployLogs | Remove-Item -Force
        Write-Log "  -> Deploy logovi obrisani." "OK"
    } else {
        Write-Log "  -> Deploy logovi sacuvani (dobro za dokumentaciju!)." "INFO"
    }
}

# =============================================================================
# KORAK 10 - VERIFIKACIJA
# =============================================================================
Write-Log "---------------------------------------------------------" "INFO"
Write-Log "[10] Verifikacija" "STEP"

Write-Log "  -> Cekam 15 sekundi pa provjeravam..." "INFO"
Start-Sleep -Seconds 15

$checks = @(
    @{ Name = $rgName;    Label = "TechNova-RG" },
    @{ Name = "MC_${rgName}_${aksName}_${location}"; Label = "AKS Managed RG" },
    @{ Name = "NetworkWatcherRG"; Label = "NetworkWatcherRG" }
)

$allClean = $true
foreach ($check in $checks) {
    $stillExists = az group exists --name $check.Name 2>$null
    if ($stillExists -eq "true") {
        Write-Log "  -> STILL EXISTS: $($check.Label) - jos se brise ili je zapelo" "WARN"
        $allClean = $false
    } else {
        Write-Log "  -> Obrisano: $($check.Label)" "OK"
    }
}

# Provjeri VNet Flow Log + legacy NSG Flow Log
$flowLogStillExists = az network watcher flow-log show --location $location --name $flowLogName --output none 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Log "  -> STILL EXISTS VNet Flow Log: $flowLogName" "WARN"
    $allClean = $false
} else {
    Write-Log "  -> Obrisano: VNet Flow Log $flowLogName" "OK"
}

# Provjeri Entra ID grupe
foreach ($groupName in $entraGroups) {
    $gId = az ad group show --group $groupName --query id -o tsv 2>$null
    if ($gId) {
        Write-Log "  -> STILL EXISTS Entra grupa: $groupName" "WARN"
        $allClean = $false
    } else {
        Write-Log "  -> Obrisano: Entra grupa $groupName" "OK"
    }
}

# Provjeri Entra ID Diagnostic Settings (v2.1 NEW)
$diagCheck = az rest --method GET `
    --url "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/${entraDiagName}?api-version=2017-04-01-preview" `
    --output none 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Log "  -> STILL EXISTS Entra ID Diag: $entraDiagName" "WARN"
    $allClean = $false
} else {
    Write-Log "  -> Obrisano: Entra ID Diag $entraDiagName" "OK"
}

# =============================================================================
# ZAVRSETAK
# =============================================================================
Write-Host ""
if ($allClean) {
    Write-Host "+======================================================+" -ForegroundColor Green
    Write-Host "|         CISCENJE ZAVRSENO - SVE OBRISANO!           |" -ForegroundColor Green
    Write-Host "+======================================================+" -ForegroundColor Green
} else {
    Write-Host "+======================================================+" -ForegroundColor Yellow
    Write-Host "|    CISCENJE ZAVRSENO - PROVJERI UPOZORENJA!         |" -ForegroundColor Yellow
    Write-Host "+======================================================+" -ForegroundColor Yellow
    Write-Host "  Neki resursi se jos brisu ili su zapeli." -ForegroundColor Yellow
    Write-Host "  Provjeri za 5 min: az group list --output table" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  Provjeri troskove: portal.azure.com -> Cost Management" -ForegroundColor Cyan
Write-Host "  Provjeri preostale RG-ove: az group list --output table" -ForegroundColor Cyan
Write-Host "  Provjeri Entra ID grupe: az ad group list --display-name TechNova --output table" -ForegroundColor Cyan
Write-Host "  Provjeri Flow Logs: az network watcher flow-log list --location $location -o table" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Cleanup log: $logFile" -ForegroundColor Cyan

Add-Content -Path $logFile -Value "================================================================" -Encoding UTF8
Add-Content -Path $logFile -Value "  ZAVRSETAK: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Encoding UTF8
Add-Content -Path $logFile -Value "  STATUS: $(if ($allClean) { 'CISTO' } else { 'PROVJERI UPOZORENJA' })" -Encoding UTF8
Add-Content -Path $logFile -Value "================================================================" -Encoding UTF8
