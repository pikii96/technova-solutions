# ==============================================================================
# PROJEKT: TechNova Solutions - STUDENT EDITION
# Verzija:  2.2.2  |  Production-ready - svi poznati bugovi rijeseni
#
# PROMJENA v2.2.1 -> v2.2.2:
#   [Step 2]  Entra ID role assignment retry logic za AAD replication delay
#             (Sleep 10s nakon kreiranja + 3 retry s 15s delay na PrincipalNotFound)
#   [Step 10] NSG Flow Logs -> VNet Flow Logs (Microsoft je 30.6.2025 deprecated
#             NSG Flow Logs; VNet Flow Logs su nasljednik s istom funkcionalnoscu)
#   [Step 12] Availability Alert popravak: scope samo na App Insights (ne i webtest),
#             agregacija "avg" umjesto "max" (max nikad ne padne ispod thresholda)
#
# PROMJENA v2.2 -> v2.2.1:
#   [Step 0]  Hard-fail ako Az PS context nema vezanu pretplatu (umjesto trap continue)
#   [Step 0]  Sinkroniziraj az CLI s istom pretplatom + verify oba
#
# CORE FEATURES (sve verzije v2.2+):
#   [Ishod 1] Entra ID grupe + RBAC + Diagnostic Settings -> Log Analytics audit
#   [Ishod 2] Storage Account + lifecycle Hot/Cool/Delete, VNet s 3 subneta
#   [Ishod 3] 2x VM s Managed Identity + AKS cluster
#   [Ishod 4] LB, NSG, Defender for Cloud Free, VNet Flow Logs + Traffic Analytics
#   [Ishod 5] LAW, App Insights, Workbook, Web App, Availability Test, Alerti
#   [Govern.] Tag propagation - svi resursi dobiju Project/Env/Owner/CostCenter
# ==============================================================================

# -----------------------------------------------------------------------------
# GLOBALNE POSTAVKE
# -----------------------------------------------------------------------------
$subId      = "7610e582-f4f3-430b-b2c7-7837f0c3db7b"
$location   = "polandcentral"
$rgName     = "TechNova-RG"
$rand       = Get-Random -Minimum 1000 -Maximum 9999

# Nazivi resursa (konvencija: <tvrtka>-<resurs>-<okruzenje>)
$vnetName        = "technova-vnet-prod"
$saName          = "technovastorage$rand"
$lbName          = "technova-lb-prod"
$avSetName       = "technova-avset-prod"
$appSvcPlan      = "technova-plan-prod"
$webAppName      = "technova-web-prod-$rand"
$nsgName         = "technova-nsg-prod"
$aksName         = "technova-aks-prod"
$lawName         = "technova-logs-prod"
$appInsightsName = "technova-appinsights-prod"
$actionGroupName = "technova-ag-prod"

# v2.2 NEW: Centralni tagovi za sve resurse (governance + cost tracking)
$globalTags = @{
    Project    = "TechNova"
    Env        = "prod"
    Owner      = "student"
    CostCenter = "Algebra-Projekt-2025"
    ManagedBy  = "PowerShell-IaC-v2.2"
}

# Promijeni u svoju e-mail adresu za primanje alerta
$alertEmail = "student@algebra.hr"

$ErrorActionPreference = "Continue"

# -----------------------------------------------------------------------------
# LOGGING INFRASTRUKTURA
# -----------------------------------------------------------------------------
$logTimestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile      = "$HOME/TechNova-deploy-$logTimestamp.log"
$script:stepErrors = @()
$script:currentStep = "Init"

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [System.ConsoleColor]$Color = [System.ConsoleColor]::White
    )
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"

    switch ($Level) {
        "STEP"  { Write-Host $Message -ForegroundColor Cyan }
        "OK"    { Write-Host $Message -ForegroundColor Green }
        "WARN"  { Write-Host $Message -ForegroundColor Yellow }
        "ERROR" { Write-Host $Message -ForegroundColor Red }
        default { Write-Host $Message -ForegroundColor $Color }
    }
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

function Write-LogError {
    param([string]$Message, [string]$Exception = "")
    $script:stepErrors += "[$script:currentStep] $Message"
    Write-Log "  !! GRESKA: $Message" -Level "ERROR"
    if ($Exception) {
        $shortEx = ($Exception -split "`n")[0].Trim()
        Write-Log "     Detalj: $shortEx" -Level "ERROR"
        Add-Content -Path $logFile -Value "     StackTrace: $Exception" -Encoding UTF8
    }
}

function Write-LogStep {
    param([string]$Message)
    $script:currentStep = $Message
    $separator = "-" * 60
    Write-Log "" -Level "INFO"
    Write-Log $separator -Level "INFO"
    Write-Log $Message -Level "STEP"
    Add-Content -Path $logFile -Value $separator -Encoding UTF8
}

Add-Content -Path $logFile -Value "================================================================" -Encoding UTF8
Add-Content -Path $logFile -Value "  TechNova Solutions - Deployment Log v2.2" -Encoding UTF8
Add-Content -Path $logFile -Value "  Pokrenuto: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Encoding UTF8
Add-Content -Path $logFile -Value "  Log datoteka: $logFile" -Encoding UTF8
Add-Content -Path $logFile -Value "================================================================" -Encoding UTF8

trap {
    $trapMsg = "NEOCEKIVANA GRESKA u koraku [$script:currentStep]: $($_.Exception.Message)"
    Write-Log "" -Level "ERROR"
    Write-Log "!! $trapMsg" -Level "ERROR"
    Add-Content -Path $logFile -Value "[TRAP] $trapMsg" -Encoding UTF8
    Add-Content -Path $logFile -Value "[TRAP] Lokacija: $($_.InvocationInfo.ScriptLineNumber). redak" -Encoding UTF8
    $script:stepErrors += "[$script:currentStep] TRAP: $($_.Exception.Message) (redak $($_.InvocationInfo.ScriptLineNumber))"
    continue
}

Write-Host "`n+======================================================+" -ForegroundColor Cyan
Write-Host "|  TECHNOVA SOLUTIONS - STUDENT EDITION v2.2          |" -ForegroundColor Cyan
Write-Host "|  Azure for Students | Senior architect dorade        |" -ForegroundColor Cyan
Write-Host "+======================================================+`n" -ForegroundColor Cyan
Write-Log "Log datoteka: $logFile" -Level "INFO" -Color Cyan

# =============================================================================
# 0. PROVJERA SESIJE + PROVIDERI + DEFENDER FOR CLOUD  (v2.2.1: HARDENED)
# =============================================================================
Write-LogStep "[0/13] Provjera sesije, vCPU kvote + Defender for Cloud Free"

# v2.2.1 FIX: Step 0 mora HARD-FAILAT ako session nije OK.
# Stari kod je puknuo na Set-AzContext, trap ga je uhvatio i continue-ao,
# pa je cijela skripta nastavila s nepotpunim kontekstom -> cascade failure.

function Stop-WithSessionHelp {
    param([string]$Reason, [string]$Detail = "")
    Write-Host ""
    Write-Host "FATAL: $Reason" -ForegroundColor Red
    if ($Detail) { Write-Host "  Detalj: $Detail" -ForegroundColor Red }
    Write-Host ""
    Write-Host "RJESENJE (popravak Azure session-a):" -ForegroundColor Yellow
    Write-Host "  Get-AzTenant   # zapamti tenantId za projektnu pretplatu" -ForegroundColor Yellow
    Write-Host "  Disconnect-AzAccount" -ForegroundColor Yellow
    Write-Host "  az logout" -ForegroundColor Yellow
    Write-Host "  Connect-AzAccount -TenantId '<tenant-id>' -Subscription '$subId'" -ForegroundColor Yellow
    Write-Host "  az login --tenant '<tenant-id>'" -ForegroundColor Yellow
    Write-Host "  az account set --subscription '$subId'" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Verifikacija prije ponovnog pokretanja:" -ForegroundColor Yellow
    Write-Host "  Get-AzContext | Select-Object Subscription" -ForegroundColor Yellow
    Write-Host "  az account show --query id -o tsv" -ForegroundColor Yellow
    Write-Host "  # Oba MORAJU vratiti $subId" -ForegroundColor Yellow
    Write-Host ""
    Add-Content -Path $logFile -Value "[FATAL] $Reason | $Detail" -Encoding UTF8
    exit 1
}

# 1) Provjera Az PowerShell konteksta
try {
    $ctx = Get-AzContext -ErrorAction Stop
} catch {
    Stop-WithSessionHelp "Get-AzContext baca exception (Az PS nije inicijaliziran)." $_.Exception.Message
}

if (!$ctx -or !$ctx.Subscription -or [string]::IsNullOrEmpty($ctx.Subscription.Id)) {
    Stop-WithSessionHelp "Az PowerShell session nema vezanu pretplatu (Subscription.Id je prazan)."
}

Write-Log "  -> Get-AzContext OK: $($ctx.Subscription.Name) / $($ctx.Subscription.Id)" -Level "OK"

# 2) Provjera da je TRAZENA pretplata aktivna (ili switch + verify)
if ($ctx.Subscription.Id -ne $subId) {
    Write-Host "  -> Trenutna pretplata: $($ctx.Subscription.Id)" -ForegroundColor Yellow
    Write-Host "  -> Trazena pretplata:  $subId" -ForegroundColor Yellow
    Write-Host "  -> Prebacujem..." -ForegroundColor Yellow
    try {
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
        $ctx = Get-AzContext  # re-fetch nakon switcha
        if (!$ctx -or $ctx.Subscription.Id -ne $subId) {
            throw "Set-AzContext je 'uspio' ali Get-AzContext jos ne vraca $subId"
        }
    } catch {
        Stop-WithSessionHelp "Ne mogu se prebaciti na pretplatu $subId" $_.Exception.Message
    }
    Write-Log "  -> Switch OK na: $($ctx.Subscription.Name)" -Level "OK"
}

# 3) Sinkronizacija az CLI s istom pretplatom
az account set --subscription $subId 2>$null | Out-Null
$cliSub = az account show --query id -o tsv 2>$null
if ([string]::IsNullOrEmpty($cliSub)) {
    Stop-WithSessionHelp "az CLI nije logiran (az account show vraca prazno)."
}
if ($cliSub -ne $subId) {
    Stop-WithSessionHelp "az CLI je na drugoj pretplati: $cliSub (trebamo $subId)"
}
Write-Log "  -> az CLI OK: sinkroniziran na $subId" -Level "OK"

Write-Log "  -> SESSION CHECK PASS - Az PS + az CLI vezani na $($ctx.Subscription.Name)" -Level "OK"

# Registracija providera
Write-Log "  -> Provjeravam i registriram potrebne Azure providere..." -Level "INFO"
$requiredProviders = @(
    "Microsoft.ContainerService",
    "microsoft.insights",
    "Microsoft.AlertsManagement",
    "Microsoft.Web",
    "Microsoft.Storage",
    "Microsoft.Network",
    "Microsoft.Compute",
    "Microsoft.Security",        # v2.2 NEW: Defender for Cloud
    "Microsoft.OperationalInsights"
)
foreach ($ns in $requiredProviders) {
    $state = az provider show --namespace $ns --query "registrationState" -o tsv 2>$null
    if ($state -ne "Registered") {
        Write-Log "  -> Registriram provider: $ns (~1-2 min)..." -Level "INFO"
        az provider register --namespace $ns --wait 2>$null | Out-Null
        Write-Log "  -> $ns registriran." -Level "OK"
    }
}
Write-Log "  -> Svi potrebni provideri su registrirani." -Level "OK"

# v2.2 NEW: Defender for Cloud Free tier - Ishod 4 (sigurnosni incidenti)
# Free tier daje: Secure Score, Security Recommendations, Compliance posture
# Ovo NE generira trosak - Free tier je besplatan na svakoj pretplati
Write-Log "" -Level "INFO"
Write-Log "  v2.2 [Ishod 4] Defender for Cloud Free tier" -Level "INFO"
$defenderPlans = @("VirtualMachines", "AppServices", "StorageAccounts", "Containers", "Arm", "KeyVaults")
$defenderOk = 0
foreach ($plan in $defenderPlans) {
    az security pricing create --name $plan --tier "Free" --subscription $subId --output none 2>$null
    if ($LASTEXITCODE -eq 0) { $defenderOk++ }
}
Write-Log "  -> Defender for Cloud Free aktiviran za $defenderOk/$($defenderPlans.Count) planova" -Level "OK"
Write-Log "     Pristup: portal.azure.com -> Microsoft Defender for Cloud" -Level "INFO"

# Provjera vCPU kvote
try {
    $usage = Get-AzVMUsage -Location $location | Where-Object { $_.Name.Value -eq "cores" }
    $currentVcpu = $usage.CurrentValue
    $limitVcpu   = $usage.Limit
    $neededVcpu  = 4
    Write-Host "  -> vCPU iskoristenost: $currentVcpu / $limitVcpu u regiji $location" -ForegroundColor Cyan
    if (($currentVcpu + $neededVcpu) -gt $limitVcpu) {
        Write-Log "  UPOZORENJE: Potrebno $neededVcpu vCPU, dostupno $($limitVcpu - $currentVcpu)." -Level "WARN"
    }
} catch {
    Write-Log "  Nije moguce provjeriti kvotu automatski - nastavljam." -Level "WARN"
}

# =============================================================================
# 1. RESOURCE GRUPA
# =============================================================================
Write-LogStep "[1/13] Resource Grupa"
try {
    if (!(Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue)) {
        New-AzResourceGroup -Name $rgName -Location $location -Tag $globalTags | Out-Null
        Write-Log "  -> Kreirano: $rgName (s globalnim tagovima)" -Level "OK"
    } else {
        Write-Log "  -> Postoji: $rgName" -Level "INFO"
    }
} catch {
    Write-LogError "Korak [1/13] Resource Grupa prekinut." -Exception $_.Exception.Message
}

# =============================================================================
# 2. ENTRA ID GRUPE + RBAC  (Ishod 1)
# =============================================================================
Write-LogStep "[2/13] Entra ID Grupe i RBAC (Ishod 1)"
try {
    $departments = @(
        @{ Name = "TechNova-Development"; Role = "Contributor"; Scope = "/subscriptions/$subId/resourceGroups/$rgName" },
        @{ Name = "TechNova-Sales";       Role = "Reader";      Scope = "/subscriptions/$subId/resourceGroups/$rgName" },
        @{ Name = "TechNova-Support";     Role = "Reader";      Scope = "/subscriptions/$subId/resourceGroups/$rgName" }
    )

    foreach ($dept in $departments) {
        $group = Get-AzADGroup -DisplayName $dept.Name -ErrorAction SilentlyContinue
        $isNewGroup = $false
        if (!$group) {
            $group = New-AzADGroup -DisplayName $dept.Name -MailNickname ($dept.Name -replace "-", "") -ErrorAction Stop
            Write-Log "  -> Kreirana Entra ID grupa: $($dept.Name)" -Level "OK"
            $isNewGroup = $true
        } else {
            Write-Log "  -> Entra ID grupa postoji: $($dept.Name)" -Level "INFO"
        }

        # v2.2.2 FIX: cekaj na Azure AD replication delay za novokreiranu grupu
        # New-AzRoleAssignment moze ne uspjeti s PrincipalNotFound ako AAD nije
        # repliciran ObjectId u Microsoft Graph backend
        if ($isNewGroup) {
            Write-Log "     Cekam 10s na AAD replikaciju..." -Level "INFO"
            Start-Sleep -Seconds 10
        }

        $existingAssign = Get-AzRoleAssignment -ObjectId $group.Id -RoleDefinitionName $dept.Role -Scope $dept.Scope -ErrorAction SilentlyContinue
        if (!$existingAssign) {
            # v2.2.2 FIX: retry logic na PrincipalNotFound (jos uvijek replication delay)
            $maxRetries = 3
            $assigned = $false
            for ($retry = 1; $retry -le $maxRetries; $retry++) {
                try {
                    New-AzRoleAssignment -ObjectId $group.Id `
                        -RoleDefinitionName $dept.Role `
                        -Scope $dept.Scope `
                        -ErrorAction Stop | Out-Null
                    Write-Log "  -> Dodijeljena uloga '$($dept.Role)' grupi '$($dept.Name)' (pokusaj $retry/$maxRetries)" -Level "OK"
                    $assigned = $true
                    break
                } catch {
                    $errMsg = $_.Exception.Message
                    if ($errMsg -match "PrincipalNotFound" -and $retry -lt $maxRetries) {
                        Write-Log "     Replication delay - cekam 15s pa retry ($retry/$maxRetries)" -Level "WARN"
                        Start-Sleep -Seconds 15
                    } else {
                        Write-LogError "Dodjela uloge '$($dept.Role)' grupi '$($dept.Name)' neuspjesna (pokusaj $retry)." -Exception $errMsg
                        break
                    }
                }
            }
            if (!$assigned) {
                Write-Log "     RUCNA INTERVENCIJA: New-AzRoleAssignment -ObjectId $($group.Id) -RoleDefinitionName '$($dept.Role)' -Scope '$($dept.Scope)'" -Level "WARN"
            }
        }
    }

    Write-Host ""
    Write-Host "  +- RUCNA KONFIGURACIJA (besplatno, bez AAD P1) ---------------------+" -ForegroundColor Yellow
    Write-Host "  |  MFA (Security Defaults):                                          |" -ForegroundColor Yellow
    Write-Host "  |  Entra ID portal -> Properties -> Manage Security Defaults -> Enable |" -ForegroundColor Yellow
    Write-Host "  |                                                                    |" -ForegroundColor Yellow
    Write-Host "  |  Conditional Access (pristup samo iz HR) - zahtijeva AAD P1:       |" -ForegroundColor Yellow
    Write-Host "  |  Dokumentirati u PDF-u kao arhitekturno rjesenje                   |" -ForegroundColor Yellow
    Write-Host "  +--------------------------------------------------------------------+" -ForegroundColor Yellow
    Write-Host ""
} catch {
    Write-LogError "Korak [2/13] Entra ID + RBAC prekinut." -Exception $_.Exception.Message
}

# =============================================================================
# 3. NSG + VNet  (Ishod 2 + 4)
# =============================================================================
Write-LogStep "[3/13] NSG i VNet (Ishod 2 + 4)"
try {
    $nsg = Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $rgName -ErrorAction SilentlyContinue
    if (!$nsg) {
        $ruleHttp = New-AzNetworkSecurityRuleConfig -Name "Allow-HTTP" `
            -Protocol Tcp -Direction Inbound -Priority 100 `
            -SourceAddressPrefix Internet -SourcePortRange * `
            -DestinationAddressPrefix * -DestinationPortRange 80 -Access Allow
        $ruleHttps = New-AzNetworkSecurityRuleConfig -Name "Allow-HTTPS" `
            -Protocol Tcp -Direction Inbound -Priority 110 `
            -SourceAddressPrefix Internet -SourcePortRange * `
            -DestinationAddressPrefix * -DestinationPortRange 443 -Access Allow
        $ruleSsh = New-AzNetworkSecurityRuleConfig -Name "Allow-SSH-Mgmt" `
            -Protocol Tcp -Direction Inbound -Priority 200 `
            -SourceAddressPrefix "10.0.3.0/24" -SourcePortRange * `
            -DestinationAddressPrefix * -DestinationPortRange 22 -Access Allow
        $ruleDeny = New-AzNetworkSecurityRuleConfig -Name "Deny-All-Inbound" `
            -Protocol * -Direction Inbound -Priority 4096 `
            -SourceAddressPrefix * -SourcePortRange * `
            -DestinationAddressPrefix * -DestinationPortRange * -Access Deny
        $nsg = New-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $rgName -Location $location `
            -SecurityRules $ruleHttp, $ruleHttps, $ruleSsh, $ruleDeny
        Write-Log "  -> NSG kreiran: HTTP(80), HTTPS(443), SSH samo s Mgmt subneta." -Level "OK"
    } else {
        Write-Log "  -> NSG postoji: $nsgName" -Level "INFO"
    }

    $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $rgName -ErrorAction SilentlyContinue
    if (!$vnet) {
        $subFrontend = New-AzVirtualNetworkSubnetConfig -Name "Frontend"   -AddressPrefix "10.0.1.0/24" -NetworkSecurityGroupId $nsg.Id
        $subBackend  = New-AzVirtualNetworkSubnetConfig -Name "Backend"    -AddressPrefix "10.0.2.0/24" -NetworkSecurityGroupId $nsg.Id
        $subMgmt     = New-AzVirtualNetworkSubnetConfig -Name "Management" -AddressPrefix "10.0.3.0/24" -NetworkSecurityGroupId $nsg.Id
        $vnet = New-AzVirtualNetwork -Name $vnetName -ResourceGroupName $rgName -Location $location -AddressPrefix "10.0.0.0/16" -Subnet $subFrontend, $subBackend, $subMgmt
        Write-Log "  -> VNet kreiran: Frontend(10.0.1.0/24) | Backend(10.0.2.0/24) | Mgmt(10.0.3.0/24)" -Level "OK"
    } else {
        Write-Log "  -> VNet postoji: $vnetName" -Level "INFO"
    }
} catch {
    Write-LogError "Korak [3/13] NSG + VNet prekinut." -Exception $_.Exception.Message
}

# =============================================================================
# 4. STORAGE ACCOUNT + LIFECYCLE POLICY  (Ishod 2)
# =============================================================================
Write-LogStep "[4/13] Storage Account (Ishod 2)"

$existingSA = Get-AzStorageAccount -ResourceGroupName $rgName -ErrorAction SilentlyContinue |
              Where-Object { $_.StorageAccountName -like "technovastorage*" } | Select-Object -First 1

if (!$existingSA) {
    Write-Host "  -> Kreiram Storage Account: $saName..."
    try {
        $sa = New-AzStorageAccount -ResourceGroupName $rgName -Name $saName -SkuName Standard_LRS `
              -Location $location -Kind StorageV2 -AccessTier Hot `
              -EnableHttpsTrafficOnly $true -MinimumTlsVersion TLS1_2 -ErrorAction Stop
    } catch {
        Write-Warning "PS greska: $($_.Exception.Message) -> Pokusavam CLI..."
        az storage account create --name $saName --resource-group $rgName --location $location `
            --sku Standard_LRS --kind StorageV2 --access-tier Hot --https-only true `
            --min-tls-version TLS1_2 --subscription $subId --output none
        Start-Sleep -Seconds 5
        $sa = Get-AzStorageAccount -ResourceGroupName $rgName -Name $saName
    }

    if ($sa) {
        $ctxSA = $sa.Context
        New-AzStorageContainer -Name "app-data"          -Context $ctxSA -Permission Off | Out-Null
        New-AzStorageShare     -Name "department-share"  -Context $ctxSA               | Out-Null
        Write-Log "  -> Blob kontejner 'app-data' i File Share 'department-share' kreirani." -Level "OK"

        $action = Add-AzStorageAccountManagementPolicyAction -BaseBlobAction TierToCool -daysAfterModificationGreaterThan 30
        $action = Add-AzStorageAccountManagementPolicyAction -InputObject $action -BaseBlobAction Delete -daysAfterModificationGreaterThan 365
        $filter = New-AzStorageAccountManagementPolicyFilter -BlobType blockBlob
        $rule   = New-AzStorageAccountManagementPolicyRule -Name "tiering-rule" -Action $action -Filter $filter
        Set-AzStorageAccountManagementPolicy -ResourceGroupName $rgName -StorageAccountName $sa.StorageAccountName -Rule $rule | Out-Null
        Write-Log "  -> Lifecycle policy: Hot->Cool(30d), Delete(365d) konfigurirana." -Level "OK"
    }
} else {
    Write-Log "  -> Storage Account postoji." -Level "INFO"
    $sa = $existingSA
}

# =============================================================================
# 5. LOAD BALANCER  (Ishod 4)
# =============================================================================
Write-LogStep "[5/13] Load Balancer (Ishod 4)"
try {
    if (!(Get-AzLoadBalancer -Name $lbName -ResourceGroupName $rgName -ErrorAction SilentlyContinue)) {
        $pipLB       = New-AzPublicIpAddress -ResourceGroupName $rgName -Name "technova-lb-ip" -Location $location -AllocationMethod Static -Sku Standard -Force
        $frontendIP  = New-AzLoadBalancerFrontendIpConfig -Name "LBFrontend" -PublicIpAddress $pipLB
        $bePool      = New-AzLoadBalancerBackendAddressPoolConfig -Name "LBBackendPool"
        $probeHttp   = New-AzLoadBalancerProbeConfig -Name "HealthProbe-HTTP" -Protocol Http -Port 80 -RequestPath "/" -IntervalInSeconds 15 -ProbeCount 2
        $lbRuleHttp  = New-AzLoadBalancerRuleConfig -Name "HTTPRule"  -FrontendIpConfiguration $frontendIP -BackendAddressPool $bePool -Probe $probeHttp -Protocol Tcp -FrontendPort 80  -BackendPort 80
        $lbRuleHttps = New-AzLoadBalancerRuleConfig -Name "HTTPSRule" -FrontendIpConfiguration $frontendIP -BackendAddressPool $bePool -Probe $probeHttp -Protocol Tcp -FrontendPort 443 -BackendPort 443

        $lb = New-AzLoadBalancer -ResourceGroupName $rgName -Name $lbName -Location $location -Sku Standard `
              -FrontendIpConfiguration $frontendIP -BackendAddressPool $bePool `
              -Probe $probeHttp -LoadBalancingRule $lbRuleHttp, $lbRuleHttps
        Write-Log "  -> Load Balancer kreiran (HTTP port 80 + HTTPS port 443)." -Level "OK"
    } else {
        Write-Log "  -> LB postoji: $lbName" -Level "INFO"
        $lb = Get-AzLoadBalancer -Name $lbName -ResourceGroupName $rgName
    }
} catch {
    Write-LogError "Korak [5/13] Load Balancer prekinut." -Exception $_.Exception.Message
}

# =============================================================================
# 6. VIRTUALNE MASINE s Managed Identity  (Ishod 3)
# =============================================================================
Write-LogStep "[6/13] Virtualne Masine (Ishod 3)"

$vnet = Get-AzVirtualNetwork    -Name $vnetName -ResourceGroupName $rgName
$lb   = Get-AzLoadBalancer      -Name $lbName   -ResourceGroupName $rgName
$nsg  = Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $rgName

$avSet = Get-AzAvailabilitySet -Name $avSetName -ResourceGroupName $rgName -ErrorAction SilentlyContinue
if (!$avSet) {
    $avSet = New-AzAvailabilitySet -Location $location -Name $avSetName -ResourceGroupName $rgName `
             -Sku Aligned -PlatformFaultDomainCount 2 -PlatformUpdateDomainCount 2
    Write-Log "  -> Availability Set kreiran (HA izmedju 2 fault domene)." -Level "OK"
}

$vmPassword = ConvertTo-SecureString "AlgebraProjekt2025!" -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ("azureuser", $vmPassword)

for ($i = 1; $i -le 2; $i++) {
    $vmName = "technova-vm$i-prod"
    if (!(Get-AzVM -Name $vmName -ResourceGroupName $rgName -ErrorAction SilentlyContinue)) {
        Write-Host "  -> Kreiram $vmName (Standard_B1s, Ubuntu 22.04 Gen2)..."

        $nic   = New-AzNetworkInterface -Name "technova-nic$i-prod" -ResourceGroupName $rgName `
                 -Location $location -SubnetId $vnet.Subnets[0].Id `
                 -NetworkSecurityGroupId $nsg.Id `
                 -LoadBalancerBackendAddressPoolId $lb.BackendAddressPools[0].Id -Force

        $vmConfig = New-AzVMConfig -VMName $vmName -VMSize "Standard_B1s" -AvailabilitySetId $avSet.Id -IdentityType SystemAssigned |
            Set-AzVMOperatingSystem  -Linux -ComputerName $vmName -Credential $cred |
            Set-AzVMSourceImage      -PublisherName "Canonical" -Offer "0001-com-ubuntu-server-jammy" -Skus "22_04-lts-gen2" -Version "latest" |
            Add-AzVMNetworkInterface -Id $nic.Id |
            Set-AzVMSecurityProfile  -SecurityType "TrustedLaunch" |
            Set-AzVMUefi             -EnableVtpm $true -EnableSecureBoot $true

        New-AzVM -ResourceGroupName $rgName -Location $location -VM $vmConfig | Out-Null
        Write-Log "  -> $vmName kreiran." -Level "OK"

        $blobEndpoint = $sa.PrimaryEndpoints.Blob
        az vm boot-diagnostics enable --name $vmName --resource-group $rgName --storage $blobEndpoint | Out-Null
        Write-Log "  -> Boot Diagnostics enabled (-> $($sa.StorageAccountName))." -Level "OK"

        $vmObj = Get-AzVM -Name $vmName -ResourceGroupName $rgName
        if ($vmObj.Identity.PrincipalId -and $sa) {
            New-AzRoleAssignment -ObjectId $vmObj.Identity.PrincipalId `
                -RoleDefinitionName "Storage Blob Data Contributor" -Scope $sa.Id -ErrorAction SilentlyContinue | Out-Null
            Write-Log "  -> ${vmName}: Managed Identity -> Storage pristup bez lozinke." -Level "OK"
        }

        Write-Host "  -> Instaliram nginx + docker na $vmName (moze trajati 2-3 min)..."
        $setupScript = @"
#!/bin/bash
set -e
sudo killall apt apt-get 2>/dev/null || true
sudo rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock*
sudo dpkg --configure -a 2>/dev/null || true
sudo apt-get update -qq
sudo apt-get install -y nginx docker.io
sudo systemctl enable --now nginx
echo '<h1>TechNova Solutions</h1><p>Server: $vmName | Status: OK</p>' | sudo tee /var/www/html/index.html
sudo systemctl enable --now docker
"@
        try {
            Invoke-AzVMRunCommand -ResourceGroupName $rgName -VMName $vmName -CommandId "RunShellScript" `
                -ScriptString $setupScript -ErrorAction Stop | Out-Null
            Write-Log "  -> ${vmName}: nginx + docker postavljeni." -Level "OK"
        } catch {
            Write-LogError "RunCommand neuspjesan za $vmName (nginx/docker)." -Exception $_.Exception.Message
        }
    } else {
        Write-Log "  -> $vmName postoji." -Level "INFO"
    }
}

# =============================================================================
# 7. AKS KLUSTER  (Ishod 3)
# =============================================================================
Write-LogStep "[7/13] AKS Kubernetes Cluster (Ishod 3)"
Write-Host "  -> NAPOMENA: AKS s 1 node (2 vCPU). Provjeri kvotu ako pukne!" -ForegroundColor Cyan

az aks show --name $aksName --resource-group $rgName --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  -> Kreiram AKS cluster: $aksName (moze trajati 5-10 min)..."
    try {
        az aks create `
            --resource-group $rgName `
            --name $aksName `
            --location $location `
            --node-count 1 `
            --node-vm-size Standard_B2s `
            --enable-managed-identity `
            --network-plugin kubenet `
            --generate-ssh-keys `
            --subscription $subId `
            --output none
        Write-Log "  -> AKS cluster kreiran: $aksName (1 node, kubenet)" -Level "OK"
        Write-Host "  -> Kubeconfig: az aks get-credentials --resource-group $rgName --name $aksName" -ForegroundColor Cyan
    } catch {
        Write-LogError "AKS kreiranje neuspjesno." -Exception $_.Exception.Message
    }
} else {
    Write-Log "  -> AKS cluster postoji: $aksName" -Level "INFO"
}

# =============================================================================
# 8. APP SERVICE  (Ishod 5)
# =============================================================================
Write-LogStep "[8/13] App Service (Ishod 5)"
try {
    Write-Host ""
    Write-Host "  +- VAZNO ZA STUDENT PRETPLATU --------------------------------------+" -ForegroundColor Yellow
    Write-Host "  |  Basic B1 (~`$13/mj) - NE podrzava auto-scale skriptom            |" -ForegroundColor Yellow
    Write-Host "  |  -> U PDF: opisati auto-scale kao arhitekturno rjesenje (S1+)    |" -ForegroundColor Yellow
    Write-Host "  +-------------------------------------------------------------------+" -ForegroundColor Yellow
    Write-Host ""

    if (!(Get-AzAppServicePlan -Name $appSvcPlan -ResourceGroupName $rgName -ErrorAction SilentlyContinue)) {
        New-AzAppServicePlan -ResourceGroupName $rgName -Name $appSvcPlan -Location $location -Tier Basic -WorkerSize Small -NumberofWorkers 1 | Out-Null
        Write-Log "  -> App Service Plan kreiran: Basic B1." -Level "OK"
    }
    if (!(Get-AzWebApp -Name $webAppName -ResourceGroupName $rgName -ErrorAction SilentlyContinue)) {
        New-AzWebApp -ResourceGroupName $rgName -Name $webAppName -AppServicePlan $appSvcPlan -Location $location | Out-Null
        Write-Log "  -> Web App kreiran: https://$webAppName.azurewebsites.net" -Level "OK"
    }
} catch {
    Write-LogError "Korak [8/13] App Service prekinut." -Exception $_.Exception.Message
}

# =============================================================================
# 9. MONITORING: LAW + App Insights + Diagnostic Settings + 
#    v2.2 NEW: Entra ID audit + Web App availability test  (Ishod 1 + 5)
# =============================================================================
Write-LogStep "[9/13] Monitoring + Entra ID audit + Availability test (Ishod 1+5)"
try {
    $law = Get-AzOperationalInsightsWorkspace -Name $lawName -ResourceGroupName $rgName -ErrorAction SilentlyContinue
    if (!$law) {
        $law = New-AzOperationalInsightsWorkspace -ResourceGroupName $rgName -Name $lawName `
               -Location $location -Sku PerGB2018 -RetentionInDays 30
        Write-Log "  -> Log Analytics Workspace kreiran (30 dana, 5GB/mj besplatno)." -Level "OK"
    } else {
        Write-Log "  -> Log Analytics Workspace postoji." -Level "INFO"
    }

    $ai = Get-AzApplicationInsights -ResourceGroupName $rgName -Name $appInsightsName -ErrorAction SilentlyContinue
    if (!$ai) {
        try {
            New-AzApplicationInsights -ResourceGroupName $rgName -Name $appInsightsName `
                -Location $location -WorkspaceResourceId $law.ResourceId | Out-Null
            Write-Log "  -> Application Insights kreiran (workspace-based)." -Level "OK"
        } catch {
            Write-LogError "Application Insights kreiranje neuspjesno." -Exception $_.Exception.Message
        }
    }

    $ai = Get-AzApplicationInsights -ResourceGroupName $rgName -Name $appInsightsName
    $iKey = $ai.InstrumentationKey
    $connStr = "InstrumentationKey=$iKey;IngestionEndpoint=https://polandcentral-0.in.applicationinsights.azure.com/;LiveEndpoint=https://polandcentral.livediagnostics.monitor.azure.com/"

    if ($iKey) {
        Set-AzWebApp -ResourceGroupName $rgName -Name $webAppName -AppSettings @{
            "APPINSIGHTS_INSTRUMENTATIONKEY"        = $iKey
            "APPLICATIONINSIGHTS_CONNECTION_STRING" = $connStr
        } | Out-Null
        Write-Log "  -> Application Insights (key: $($iKey.Substring(0,8))...) spojen s Web Appom." -Level "OK"
    } else {
        Write-Log "  InstrumentationKey nije dostupan." -Level "WARN"
    }

    # Diagnostic Settings za VM-ove
    for ($i = 1; $i -le 2; $i++) {
        $vmName = "technova-vm$i-prod"
        $vmObj  = Get-AzVM -Name $vmName -ResourceGroupName $rgName -ErrorAction SilentlyContinue
        if ($vmObj) {
            $diagName    = "diag-$vmName"
            $existDiag   = Get-AzDiagnosticSetting -ResourceId $vmObj.Id -Name $diagName -ErrorAction SilentlyContinue
            if (!$existDiag) {
                $metricSettings = New-AzDiagnosticSettingMetricSettingsObject -Enabled $true -Category AllMetrics
                New-AzDiagnosticSetting -ResourceId $vmObj.Id -Name $diagName `
                    -WorkspaceId $law.ResourceId -Metric $metricSettings | Out-Null
                Write-Log "  -> Diagnostic settings: $vmName -> Log Analytics." -Level "OK"
            }
        }
    }

    # -------------------------------------------------------------------------
    # v2.2 NEW: Entra ID Diagnostic Settings -> LAW  (Ishod 1: audit pristupa)
    # NAPOMENA: Zahtjeva Global Admin ili Security Admin na tenantu.
    # Vecina Azure for Students korisnika NEMA tu role - graceful failure.
    # -------------------------------------------------------------------------
    Write-Log "" -Level "INFO"
    Write-Log "  v2.2 [Ishod 1] Entra ID Diagnostic Settings -> Log Analytics" -Level "INFO"

    $entraDiagBody = @{
        properties = @{
            workspaceId = $law.ResourceId
            logs = @(
                @{category = "AuditLogs"; enabled = $true},
                @{category = "SignInLogs"; enabled = $true},
                @{category = "NonInteractiveUserSignInLogs"; enabled = $true},
                @{category = "ServicePrincipalSignInLogs"; enabled = $true}
            )
        }
    } | ConvertTo-Json -Depth 10

    $bodyPath = "$HOME/entra-diag-body.json"
    $entraDiagBody | Out-File -FilePath $bodyPath -Encoding UTF8

    try {
        $url = "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/TechNova-EntraID-Audit?api-version=2017-04-01-preview"
        az rest --method PUT --url $url --body "@$bodyPath" --output none 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "  -> Entra ID audit logs -> LAW konfigurirano (AuditLogs + SignInLogs)" -Level "OK"
            Write-Log "     Query: AuditLogs | take 10  (u LAW portalu)" -Level "INFO"
        } else {
            Write-Log "  -> Entra ID Diagnostic Settings nije uspjelo (vjerovatno nedovoljne ovlasti)" -Level "WARN"
            Write-Log "     Manual fallback: portal -> Entra ID -> Diagnostic settings -> + Add" -Level "WARN"
            Write-Log "     Dokumentirati postupak u PDF-u kao arhitekturno rjesenje" -Level "WARN"
        }
    } finally {
        Remove-Item $bodyPath -ErrorAction SilentlyContinue
    }

    # -------------------------------------------------------------------------
    # v2.2 NEW: Web App Availability Test  (Ishod 5: alert za nedostupnost)
    # Koristi App Insights Standard Test (ping iz vise lokacija svakih 5 min)
    # Besplatno do 5 testova
    # -------------------------------------------------------------------------
    Write-Log "" -Level "INFO"
    Write-Log "  v2.2 [Ishod 5] Web App Availability Test (App Insights ping test)" -Level "INFO"

    $webAppUrl     = "https://$webAppName.azurewebsites.net"
    $availTestName = "technova-availability-prod"

    # WebTest configuration kao XML string - mora se escape-ati za JSON
    $webTestXml = "<WebTest Name=`"$availTestName`" Enabled=`"True`" Timeout=`"30`" Frequency=`"300`" Version=`"1.1`"><Items><Request Method=`"GET`" Guid=`"a5f10126-e26b-4bba-9d18-ec6ca18d9a99`" Version=`"1.1`" Url=`"$webAppUrl`" ThinkTime=`"0`" Timeout=`"30`" ParseDependentRequests=`"False`" FollowRedirects=`"True`" RecordResult=`"True`" Cache=`"False`" ResponseTimeGoal=`"0`" Encoding=`"utf-8`" ExpectedHttpStatusCode=`"200`" ExpectedResponseUrl=`"`" ReportingName=`"`" IgnoreHttpStatusCode=`"False`" /></Items></WebTest>"

    $aiId = $ai.Id
    $hiddenLinkTag = "hidden-link:$aiId"

    # ARM template za webtest (CLI nema direktnu podrsku u svim verzijama)
    $webTestTemplate = @{
        '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
        contentVersion = "1.0.0.0"
        parameters = @{}
        resources = @(
            @{
                type = "Microsoft.Insights/webtests"
                apiVersion = "2022-06-15"
                name = $availTestName
                location = $location
                tags = @{ $hiddenLinkTag = "Resource" }
                properties = @{
                    SyntheticMonitorId = $availTestName
                    Name = "TechNova Web App Availability"
                    Enabled = $true
                    Frequency = 300
                    Timeout = 30
                    Kind = "ping"
                    RetryEnabled = $true
                    Locations = @(
                        @{Id = "emea-nl-ams-azr"},
                        @{Id = "emea-se-sto-edge"},
                        @{Id = "emea-gb-db3-azr"}
                    )
                    Configuration = @{
                        WebTest = $webTestXml
                    }
                }
            }
        )
    } | ConvertTo-Json -Depth 20

    $tmplPath = "$HOME/webtest-template.json"
    $webTestTemplate | Out-File -FilePath $tmplPath -Encoding UTF8

    try {
        az deployment group create --resource-group $rgName --template-file $tmplPath --output none 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "  -> Web App Availability Test kreiran (ping iz 3 lokacije, svakih 5 min)" -Level "OK"
            Write-Log "     URL: $webAppUrl" -Level "INFO"
        } else {
            Write-LogError "Availability Test deploy neuspjesan."
        }
    } finally {
        Remove-Item $tmplPath -ErrorAction SilentlyContinue
    }

} catch {
    Write-LogError "Korak [9/13] Monitoring prekinut." -Exception $_.Exception.Message
}

# =============================================================================
# 10. v2.2 NEW: VNET FLOW LOGS + TRAFFIC ANALYTICS  (Ishod 4)
# v2.2.2 FIX: Microsoft je 30.6.2025 deprecated kreiranje NSG Flow Logs.
# Sad koristimo VNet Flow Logs (nasljednik - capture na VNet razini, sira pokritenost).
# =============================================================================
Write-LogStep "[10/13] VNet Flow Logs + Traffic Analytics (Ishod 4) [v2.2.2: VNet umjesto NSG]"
try {
    Write-Log "  -> Konfiguriram Network Watcher u $location..." -Level "INFO"

    # Force-enable Network Watcher u regiji
    az network watcher configure --locations $location --enabled true 2>$null | Out-Null
    Start-Sleep -Seconds 5

    # v2.2.2: Target je sad VNet umjesto NSG
    $vnetId = az network vnet show --name $vnetName --resource-group $rgName --query id -o tsv 2>$null
    $saId  = $sa.Id
    if (!$saId) {
        $saId = az storage account show --name $sa.StorageAccountName --resource-group $rgName --query id -o tsv 2>$null
    }
    $lawIdFull = $law.ResourceId

    $flowLogName = "technova-vnetflowlog-prod"  # v2.2.2: rename reflektira VNet target

    az network watcher flow-log show --location $location --name $flowLogName --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  -> Kreiram VNet Flow Log + Traffic Analytics (LAW: $lawName)..." -Level "INFO"
        Write-Log "     Razlog migracije: Microsoft je 30.6.2025 blokirao NSG Flow Logs creation." -Level "INFO"

        # v2.2.2: Capture output for diagnostics on failure
        $createOutput = (az network watcher flow-log create `
            --location $location `
            --name $flowLogName `
            --vnet $vnetId `
            --storage-account $saId `
            --workspace $lawIdFull `
            --interval 10 `
            --traffic-analytics true `
            --enabled true 2>&1)

        if ($LASTEXITCODE -eq 0) {
            Write-Log "  -> VNet Flow Logs aktiviran (10-min interval, Traffic Analytics: ON)" -Level "OK"
            Write-Log "     Storage: $($sa.StorageAccountName) | Analiza: $lawName" -Level "INFO"
            Write-Log "     Portal: Network Watcher -> Flow logs -> $flowLogName" -Level "INFO"
        } else {
            Write-LogError "VNet Flow Logs kreiranje neuspjesno."
            # Output prvih 500 znakova greske za dijagnostiku
            $errStr = ($createOutput -join "`n")
            $errSnippet = if ($errStr.Length -gt 500) { $errStr.Substring(0, 500) + "..." } else { $errStr }
            Write-Log "     Output: $errSnippet" -Level "WARN"
        }
    } else {
        Write-Log "  -> VNet Flow Logs vec postoji: $flowLogName" -Level "INFO"
    }
} catch {
    Write-LogError "Korak [10/13] VNet Flow Logs prekinut." -Exception $_.Exception.Message
}

# =============================================================================
# 11. v2.2 NEW: AZURE MONITOR WORKBOOK  (Ishod 5)
# Vizualizacija kljucnih pokazatelja: VM CPU, App Service, Storage, Security
# =============================================================================
Write-LogStep "[11/13] Azure Monitor Workbook (Ishod 5) [v2.2]"
try {
    $workbookGuid = [guid]::NewGuid().ToString()
    $workbookName = "technova-workbook-prod"

    # Workbook sadrzaj - KQL upiti za kljucne metrike
    $workbookContent = @{
        version = "Notebook/1.0"
        items = @(
            @{
                type = 1
                content = @{
                    json = "# TechNova Solutions - Operations Dashboard`n`n**Kljucni pokazatelji infrastrukture u realnom vremenu.**`n`n- CPU iskoristenost VM-ova (Ishod 3)`n- Web App performanse (Ishod 5)`n- Audit logovi pristupa (Ishod 1)`n- Mrezne anomalije (Ishod 4)"
                }
                name = "header"
            },
            @{
                type = 3
                content = @{
                    version = "KqlItem/1.0"
                    query = "Perf | where ObjectName == 'Processor' and CounterName == '% Processor Time' | summarize avg(CounterValue) by bin(TimeGenerated, 5m), Computer | render timechart"
                    size = 0
                    title = "CPU Iskoristenost - VM-ovi (24h)"
                    timeContext = @{ durationMs = 86400000 }
                    queryType = 0
                    resourceType = "microsoft.operationalinsights/workspaces"
                }
                name = "vmCpu"
            },
            @{
                type = 3
                content = @{
                    version = "KqlItem/1.0"
                    query = "AppRequests | summarize count() by bin(TimeGenerated, 5m), success | render timechart"
                    size = 0
                    title = "Web App - Broj zahtjeva (success/fail)"
                    timeContext = @{ durationMs = 86400000 }
                    queryType = 0
                    resourceType = "microsoft.operationalinsights/workspaces"
                }
                name = "webAppRequests"
            },
            @{
                type = 3
                content = @{
                    version = "KqlItem/1.0"
                    query = "AzureMetrics | where ResourceProvider == 'MICROSOFT.STORAGE' | where MetricName == 'UsedCapacity' | summarize max(Maximum) by bin(TimeGenerated, 1h), Resource | render timechart"
                    size = 0
                    title = "Storage Account - Iskoristen kapacitet"
                    timeContext = @{ durationMs = 604800000 }
                    queryType = 0
                    resourceType = "microsoft.operationalinsights/workspaces"
                }
                name = "storageCapacity"
            },
            @{
                type = 3
                content = @{
                    version = "KqlItem/1.0"
                    query = "SigninLogs | summarize count() by bin(TimeGenerated, 1h), ResultType | render columnchart"
                    size = 0
                    title = "Entra ID - Sign-in pokusaji (24h)"
                    timeContext = @{ durationMs = 86400000 }
                    queryType = 0
                    resourceType = "microsoft.operationalinsights/workspaces"
                }
                name = "signins"
            },
            @{
                type = 3
                content = @{
                    version = "KqlItem/1.0"
                    query = "AzureNetworkAnalytics_CL | where SubType_s == 'FlowLog' | summarize count() by bin(TimeGenerated, 1h), FlowStatus_s | render columnchart"
                    size = 0
                    title = "NSG Flow Logs - Allowed/Denied promet (24h)"
                    timeContext = @{ durationMs = 86400000 }
                    queryType = 0
                    resourceType = "microsoft.operationalinsights/workspaces"
                }
                name = "nsgFlow"
            }
        )
        styleSettings = @{}
        fallbackResourceIds = @($law.ResourceId)
        '$schema' = "https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json"
    } | ConvertTo-Json -Depth 30

    $workbookTemplate = @{
        '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
        contentVersion = "1.0.0.0"
        parameters = @{}
        resources = @(
            @{
                type = "microsoft.insights/workbooks"
                apiVersion = "2022-04-01"
                name = $workbookGuid
                location = $location
                kind = "shared"
                properties = @{
                    displayName = "TechNova Operations Dashboard"
                    serializedData = $workbookContent
                    version = "1.0"
                    sourceId = $law.ResourceId
                    category = "workbook"
                }
            }
        )
    } | ConvertTo-Json -Depth 30

    $wbPath = "$HOME/workbook-template.json"
    $workbookTemplate | Out-File -FilePath $wbPath -Encoding UTF8

    try {
        az deployment group create --resource-group $rgName --template-file $wbPath --output none 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "  -> Workbook kreiran: 'TechNova Operations Dashboard'" -Level "OK"
            Write-Log "     Pristup: portal -> Monitor -> Workbooks -> Recently modified" -Level "INFO"
        } else {
            Write-Log "  -> Workbook deploy neuspjesan - import rucno iz JSON template-a" -Level "WARN"
            Write-Log "     Template sacuvan: $wbPath (nije obrisan)" -Level "WARN"
            $script:stepErrors += "[11/13] Workbook - manual import potreban"
        }
    } catch {
        Write-LogError "Workbook ARM deploy neuspjesan." -Exception $_.Exception.Message
    } finally {
        if (Test-Path $wbPath) { Remove-Item $wbPath -ErrorAction SilentlyContinue }
    }
} catch {
    Write-LogError "Korak [11/13] Workbook prekinut." -Exception $_.Exception.Message
}

# =============================================================================
# 12. ALERTI I ACTION GROUP  (Ishod 5) + v2.2: availability alert
# =============================================================================
Write-LogStep "[12/13] Alerti i Obavijesti (Ishod 5)"

$agExists = az monitor action-group show --name $actionGroupName --resource-group $rgName --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    try {
        az monitor action-group create `
            --name $actionGroupName `
            --resource-group $rgName `
            --short-name "TN-Admin" `
            --action email AdminEmail $alertEmail `
            --output none
        Write-Log "  -> Action Group kreiran -> e-mail: $alertEmail" -Level "OK"
    } catch {
        Write-LogError "Action Group kreiranje neuspjesno." -Exception $_.Exception.Message
    }
} else {
    Write-Log "  -> Action Group postoji: $actionGroupName" -Level "INFO"
}

$agId = az monitor action-group show --name $actionGroupName --resource-group $rgName --query id -o tsv 2>$null

# Alert: CPU > 80% na svakom VM-u
for ($i = 1; $i -le 2; $i++) {
    $vmName  = "technova-vm$i-prod"
    $alertNm = "technova-alert-cpu-vm$i-prod"
    $vmId    = az vm show --name $vmName --resource-group $rgName --query id -o tsv 2>$null

    $alertExists = az monitor metrics alert show --name $alertNm --resource-group $rgName --output none 2>$null
    if ($LASTEXITCODE -ne 0 -and $vmId) {
        try {
            az monitor metrics alert create `
                --name $alertNm `
                --resource-group $rgName `
                --scopes $vmId `
                --condition "avg Percentage CPU > 80" `
                --window-size 5m `
                --evaluation-frequency 1m `
                --severity 2 `
                --description "CPU > 80% na $vmName" `
                --action $agId `
                --output none
            Write-Log "  -> Alert 'CPU>80%' kreiran za $vmName." -Level "OK"
        } catch {
            Write-LogError "Alert CPU>80% za $vmName neuspjesan." -Exception $_.Exception.Message
        }
    } else {
        Write-Log "  -> Alert CPU postoji ili VM nije pronadjen: $vmName" -Level "INFO"
    }
}

# Alert: Web App HTTP 5xx
$webAppId = az webapp show --name $webAppName --resource-group $rgName --query id -o tsv 2>$null
$svcAlertExists = az monitor metrics alert show --name "technova-alert-svc-prod" --resource-group $rgName --output none 2>$null
if ($LASTEXITCODE -ne 0 -and $webAppId) {
    az monitor metrics alert create `
        --name "technova-alert-svc-prod" `
        --resource-group $rgName `
        --scopes $webAppId `
        --condition "total Http5xx > 5" `
        --window-size 5m `
        --evaluation-frequency 1m `
        --severity 1 `
        --description "Web App HTTP 5xx greske > 5 u 5 min" `
        --action $agId `
        --output none 2>$null

    if ($LASTEXITCODE -eq 0) {
        Write-Log "  -> Alert 'HTTP 5xx' kreiran za $webAppName." -Level "OK"
    } else {
        Write-Log "  -> Alert 'HTTP 5xx' nije kreiran - App Service metrike jos nisu dostupne." -Level "WARN"
        $script:stepErrors += "[12/13] Alert HTTP 5xx odgodjen - pokreni rucno za 5 min"
    }
} else {
    Write-Log "  -> Alert HTTP 5xx postoji ili Web App nije pronadjen." -Level "INFO"
}

# -------------------------------------------------------------------------
# v2.2 NEW: Alert za Web App Availability Test failure
# v2.2.2 FIX: scope samo na App Insights (ne i webtest), agregacija "avg" umjesto "max"
# Razlog: max nikad nece pasti ispod thresholda (max je najvisa vrijednost).
# Dvostruki scope (webtest + AI) je redundantan - metrika "availabilityResults/*"
# se prikuplja na AI razini.
# -------------------------------------------------------------------------
Write-Log "" -Level "INFO"
Write-Log "  v2.2 [Ishod 5] Alert za Availability Test failure" -Level "INFO"

$availAlertName = "technova-alert-availability-prod"
$availAlertExists = az monitor metrics alert show --name $availAlertName --resource-group $rgName --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    # v2.2.2 FIX: --scopes samo $ai.Id, --condition s "avg" umjesto "max"
    az monitor metrics alert create `
        --name $availAlertName `
        --resource-group $rgName `
        --scopes $ai.Id `
        --condition "avg availabilityResults/availabilityPercentage < 80" `
        --window-size 5m `
        --evaluation-frequency 1m `
        --severity 1 `
        --description "Web App availability < 80% - servis nedostupan" `
        --action $agId `
        --output none 2>$null

    if ($LASTEXITCODE -eq 0) {
        Write-Log "  -> Alert 'Availability < 80%' kreiran za Web App" -Level "OK"
    } else {
        Write-Log "  -> Availability alert kreiranje neuspjesno" -Level "WARN"
        $script:stepErrors += "[12/13] Availability alert - rucni fix potreban"
    }
} else {
    Write-Log "  -> Availability alert vec postoji" -Level "INFO"
}

# =============================================================================
# 13. v2.2 NEW: TAG PROPAGATION  (governance + cost tracking)
# =============================================================================
Write-LogStep "[13/13] Tag Propagation - svi resursi (governance) [v2.2]"
try {
    Write-Log "  -> Propagiram globalne tagove na sve resurse u $rgName..." -Level "INFO"

    $resources = Get-AzResource -ResourceGroupName $rgName -ErrorAction SilentlyContinue
    $tagged = 0
    $skipped = 0
    foreach ($r in $resources) {
        try {
            Update-AzTag -ResourceId $r.Id -Tag $globalTags -Operation Merge -ErrorAction SilentlyContinue | Out-Null
            $tagged++
        } catch {
            $skipped++
            # Neki resursi (managed by AKS itd.) ne dopustaju update
        }
    }
    Write-Log "  -> Tagovi propagirani na $tagged resursa ($skipped preskoceno)" -Level "OK"
    Write-Log "     Tagovi: Project=TechNova, Env=prod, Owner=student," -Level "INFO"
    Write-Log "             CostCenter=Algebra-Projekt-2025, ManagedBy=PowerShell-IaC-v2.2" -Level "INFO"
    Write-Log "     Cost Management: portal -> Cost Management + Billing -> Cost analysis (filter by tag)" -Level "INFO"
} catch {
    Write-LogError "Korak [13/13] Tag Propagation prekinut." -Exception $_.Exception.Message
}

# =============================================================================
# ZAVRSETAK + SAZETAK
# =============================================================================
$lbIp  = (Get-AzPublicIpAddress -ResourceGroupName $rgName -Name "technova-lb-ip" -ErrorAction SilentlyContinue).IpAddress

Write-Host "`n+======================================================+" -ForegroundColor Green
Write-Host "|         DEPLOYMENT v2.2 ZAVRSEN!                    |" -ForegroundColor Green
Write-Host "+======================================================+" -ForegroundColor Green

Write-Host "`nSAZETAK:" -ForegroundColor Cyan
Write-Host "  Resource Group  : $rgName ($location)"
Write-Host "  VNet            : $vnetName (Frontend / Backend / Management)"
Write-Host "  NSG             : $nsgName + Flow Logs + Traffic Analytics [v2.2]"
Write-Host "  Storage         : $($sa.StorageAccountName) (Blob + FileShare + lifecycle)"
Write-Host "  Load Balancer   : $lbIp (HTTP + HTTPS)"
Write-Host "  VM1/VM2         : technova-vm1/2-prod (nginx+docker, MI)"
Write-Host "  AKS             : $aksName (1 node, kubenet)"
Write-Host "  Web App         : https://$webAppName.azurewebsites.net"
Write-Host "  App Insights    : $appInsightsName + Availability Test [v2.2]"
Write-Host "  Log Analytics   : $lawName"
Write-Host "  Workbook        : 'TechNova Operations Dashboard' [v2.2]"
Write-Host "  Defender        : Free tier aktivan (Secure Score) [v2.2]"
Write-Host "  Alerti          : CPU>80%, HTTP 5xx, Availability<80% -> $alertEmail"
Write-Host "  Entra ID Audit  : Diagnostic Settings -> LAW (ako su ovlasti OK) [v2.2]"

Write-Host "`nPROCJENA TROSKA (Student pretplata):" -ForegroundColor Yellow
Write-Host "  2x VM Standard_B1s     ~`$14/mj"
Write-Host "  App Service Basic B1   ~`$13/mj"
Write-Host "  AKS (1x B2s node)      ~`$30/mj  <- iskljuci kad ne koristis!"
Write-Host "  1x Public IP Standard  ~`$ 4/mj"
Write-Host "  Storage + LAW + AI     ~`$ 5/mj"
Write-Host "  NSG Flow Logs + TA     ~`$ 2/mj  [v2.2]"
Write-Host "  Workbook + Defender    `$0      (besplatno)"
Write-Host "  ----------------------------------"
Write-Host "  Ukupno (bez AKS)       ~`$45/mj" -ForegroundColor Green
Write-Host "  Ukupno (s AKS)         ~`$75/mj" -ForegroundColor Yellow

Write-Host "`nKORISNE NAREDBE:" -ForegroundColor Cyan
Write-Host "  # Verifikacija dodataka v2.2:"
Write-Host "  az network watcher flow-log list --location $location -o table"
Write-Host "  az security pricing list -o table"
Write-Host "  az monitor app-insights web-test list --resource-group $rgName -o table"
Write-Host "  az resource list --resource-group $rgName --resource-type microsoft.insights/workbooks -o table"
Write-Host ""
Write-Host "  # AKS i VM:"
Write-Host "  az aks get-credentials --resource-group $rgName --name $aksName"
Write-Host "  az aks stop --name $aksName --resource-group $rgName  # ustedi novac"

# Sazetak loga
$endTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Add-Content -Path $logFile -Value "" -Encoding UTF8
Add-Content -Path $logFile -Value "================================================================" -Encoding UTF8
Add-Content -Path $logFile -Value "  ZAVRSETAK DEPLOYMENTA v2.2: $endTime" -Encoding UTF8
Add-Content -Path $logFile -Value "================================================================" -Encoding UTF8

if ($script:stepErrors.Count -eq 0) {
    Add-Content -Path $logFile -Value "  STATUS: USPJESNO - nema gresaka" -Encoding UTF8
    Write-Host "`n[OK] Log sacuvan bez gresaka: $logFile" -ForegroundColor Green
} else {
    Add-Content -Path $logFile -Value "  STATUS: ZAVRSENO S GRESKAMA ($($script:stepErrors.Count))" -Encoding UTF8
    foreach ($err in $script:stepErrors) {
        Add-Content -Path $logFile -Value "    - $err" -Encoding UTF8
    }
    Write-Host "`n[WARN] Deployment zavrsen s $($script:stepErrors.Count) greskom/ama." -ForegroundColor Yellow
    Write-Host "       Greske:" -ForegroundColor Red
    foreach ($err in $script:stepErrors) {
        Write-Host "         - $err" -ForegroundColor Red
    }
}
Write-Host "`nPuni log: $logFile" -ForegroundColor Cyan
