<# 
.SYNOPSIS
    Script to remediate Configuration Manager Client and WMI based on results from the detection script

.DESCRIPTION 
    This script is aimed at hybrid joined devices with ConfigMgr Client falsely reporting as healthy
 
.NOTES        

.PARAMETER      

.Author
    Amir Joseph Sayes    
 
.Date
    5/8/2022

.VERSIONS
    Beta: First Script creation and logic
#>

#Variables and Configurations
Param 
(
    $CurrentTime = (Get-Date -Format "dd_MM_yyyy-HH_mm_ss"),
    $WMICheckResult = "",
    $CcmExecCheckResult = "",
    $LastMachinePolicyRequestResult = "",
    $CurrentManagementPointResult = "",
    $RemediationAggregateMessages = ""
)

$ErrorActionPreference = "Stop"

#Functions
Function Reset-WMI {
    [CmdletBinding()]
    Param (
        $CCMSetupWait = 10
    )
     ####Do heal WMI 
     Write-Host "Stopping winmgmt Service..."
     Stop-Service winmgmt -Force
     Write-Host "Resetting WMI repo..."                
     winmgmt /resetrepository
     Write-Host "Wait for 10 seconds..."
     Start-Sleep -Seconds 10
     Write-Host "Restart ccmexec service..."     
     Restart-Service ccmexec -Verbose -Force
     Write-Host "Wait until ccmsetup is started..."                     
     $limit = (Get-Date).AddMinutes($CCMSetupWait)
     Do {
         $status = Get-Process ccmsetup -ErrorAction SilentlyContinue
         If (!($status)) { 
             Write-Host "Waiting for ccmsetup to start - time elapsed: $(($limit - (Get-Date)).minutes) minutes and $(($limit - (Get-Date)).seconds) seconds" 
             Start-Sleep -Seconds 30                        
         }                    
         Else { 
             Write-Host "ccmsetup has started - time elapsed: $(($limit - (Get-Date)).minutes) minutes and $(($limit - (Get-Date)).seconds) seconds" 
             $started = $true 
         }
     }
     Until ( $started -or ((get-date) -gt $limit))                
     
     #Report if the Do while exited without CCMSetup starting 
     if ($started -eq $False) {
         Write-Host "$($CCMSetupWait) minutes has passed and ccmsetup did not start" 
         #Flag the result of this check as failed:
         $WMICheckResult = $False
     }
     elseif ($started -eq $true) {
         #Flag the result of this check as successful:
         $WMICheckResult = $true
     }
     
     #Check if CCMSetup has exited with code 0 
     Write-Host "Wait until ccmsetup logs an event signalling a successful reconfiguration (Event 1035)..."   
     $CCMEventFound = $false                
     $limit = (Get-Date).AddMinutes($CCMSetupWait)
     DO {
         $filter = @{
             Logname = 'Application'
             ID = 1035                    
             StartTime =  ((Get-Date).AddMinutes(-1))
             EndTime = (Get-Date)                    
         }
         try {
             $CCMEvent = Get-WinEvent -FilterHashtable $filter -MaxEvents 1 -ErrorAction SilentlyContinue | Where-Object -Property Message -Like '*Product Name: Configuration Manager Client.*Reconfiguration success or error status: 0.'
             if ($CCMEvent) {
                 Write-Host "Event showing CCMSetup has reconfigured the client successfully was found at: $($CCMEvent.TimeCreated) - Message: $($CCMEvent.Message)"
                 $CCMEventFound = $true
             }
         }
         catch {
             $CCMEventFound = $false
             Start-Sleep -Seconds 60    
             Write-Host "No event found at $(get-date)"
         }                    
     }
     Until ( $CCMEventFound -or ((get-date) -gt $limit))                

     #Report if the Do while exited without CCMSetup starting 
     if ($CCMEventFound -eq $False) {
         Write-Host "$($CCMSetupWait) minutes has passed and ccmsetup did not report a success exit code 0 in the event logs" 
         #Flag the result of this check as failed:
         $WMICheckResult = $False
     }
     elseif ($CCMEventFound -eq $true) {
         #Flag the result of this check as successful:
         $WMICheckResult = $true
     }
     return $WMICheckResult                
}

Function Restore-CCMService {
    ####Do heal Ccm Service
    Write-Host "Starting ccmexec Service..."
    Start-Service ccmexec -Verbose
    Write-Host "Wait for 3 minutes..."
    Start-Sleep -Seconds 180 -Verbose
    Write-Host "Triggering Machine Policy Refresh..."
    ([wmiclass]'ROOT\ccm:SMS_Client').TriggerSchedule('{00000000-0000-0000-0000-000000000021}')
    if ((Get-Service ccmexec).status -eq "Running") {
        $CcmExecCheckResult = $true
    }
    else {
        $CcmExecCheckResult = $False
    }            
    Return $CcmExecCheckResult
}

Function Update-CCMMachinePolicy {
    [CmdletBinding()]
    Param (
        $LoopingWindowInMinutes = 60
    )

    ####Do heal last policy refresh
    Write-Host "Killing ccmexec Service..."
    taskkill /IM "CcmExec.exe" /F | Out-Null
    Write-Host "Wait for 30 seconds"
    Start-Sleep -Seconds 30 -Verbose
    Write-Host "Starting ccmexec Service..."
    Start-Service ccmexec -Verbose                
    Write-Host "Wait for 3 minutes..."
    Start-Sleep -Seconds 180 -Verbose                                
    Write-Host  "Check last policy request date over the next $($LoopingWindowInMinutes) minutes..."                
    $limit = (Get-Date).AddMinutes($LoopingWindowInMinutes)
    Do {
        Write-Host "Triggering Machine Policy Refresh..."
        ([wmiclass]'ROOT\ccm:SMS_Client').TriggerSchedule('{00000000-0000-0000-0000-000000000021}')
        Write-Host "Wait for 5 minutes..."
        Start-Sleep -Seconds 300
        $LastMachinePolicyRequest = (get-wmiobject -query "SELECT LastTriggerTime FROM CCM_Scheduler_History WHERE ScheduleID='{00000000-0000-0000-0000-000000000021}' and UserSID='Machine'" -namespace "Root\CCM\Scheduler").LastTriggerTime                
        [datetime]$LastMachinePolicyRequestDate = ([WMI] '').ConvertToDateTime($LastMachinePolicyRequest)                                      
        Write-Host "Last policy request is currently showing: $($LastMachinePolicyRequestDate)"
    } until ((($LastMachinePolicyRequest.Length -gt 0) -and ($LastMachinePolicyRequestDate -gt (get-date).AddHours(-24))) -or ((get-date) -gt $limit))

    Write-Host "Triggering Data Discovery Collection Cycle..."
    ([wmiclass]'ROOT\ccm:SMS_Client').TriggerSchedule('{00000000-0000-0000-0000-000000000003}')
    Write-Host "Wait for 1 minutes..."
    Start-Sleep -Seconds 60 -Verbose
    Write-Host "Triggering Hardware Inventory Cycle..."
    ([wmiclass]'ROOT\ccm:SMS_Client').TriggerSchedule('{00000000-0000-0000-0000-000000000001}')
    Write-Host "Wait for 1 minutes..."
    Start-Sleep -Seconds 60 -Verbose
    Write-Host "Triggering Software Update Scan Cycle..."
    ([wmiclass]'ROOT\ccm:SMS_Client').TriggerSchedule('{00000000-0000-0000-0000-000000000113}')                           
    Write-Host "Wait for 1 minutes..."
    Start-Sleep -Seconds 60 -Verbose

    if (($LastMachinePolicyRequest.Length -gt 0)  -and ($LastMachinePolicyRequestDate -gt (get-date).AddHours(-24))) {   
        #Machine is requesting policy within 24 hours         
        Write-Host "Last policy request is now showing: $($LastMachinePolicyRequestDate)"
        $LastMachinePolicyRequestResult = $true                    
    }
    else {
        #Machine is not requesting refresh
        Write-Host "Last policy request is still showing older than 24 hours: $($LastMachinePolicyRequestDate)"                    
        $LastMachinePolicyRequestResult = $False
    }       
    Return $LastMachinePolicyRequestResult         
}

Function Update-CCMManagementPoint {
    Write-Host "Killing ccmexec Service..."
    taskkill /IM "CcmExec.exe" /F | Out-Null
    Write-Host "Wait for 30 seconds"
    Start-Sleep -Seconds 30 -Verbose
    Write-Host "Starting ccmexec Service..."
    Start-Service ccmexec -Verbose      
    Write-Host "Wait for 5 minutes"
    Start-Sleep -Seconds 300 -Verbose    
    #Check Management Point entry
    $CurrentManagementPoint = (Get-WmiObject -query "SELECT * FROM SMS_Authority" -namespace "root\ccm").CurrentManagementPoint
    if ($CurrentManagementPoint.Length -gt 0) {   
        #  CurrentManagementPoint is not null                          
        Write-Host "Current Management Point is:  $($CurrentManagementPoint)"                    
        $CurrentManagementPointResult = $true                    
    }
    else {
        #Machine has empty string for Management Point Value                    
        $CurrentManagementPointResult = $False
        Write-Host "Machine has empty string for Management Point Value after remediation"
    }
    Return $CurrentManagementPointResult
}
Start-Transcript -Path c:\Windows\logs\RemediatingCCMClient_$($env:COMPUTERNAME)_$CurrentTime.log -Force

#Check if CcmExec.exe exists, otherwise, exit gracefully 
if ((Test-Path -Path $env:windir\CCM\CcmExec.exe)) {
    #Check registry for various values 
    If ((Test-Path -Path "HKLM:\SOFTWARE\IntuneRemediations")) {
        Try {
            $IntuneRemediationsValues = (Get-ItemProperty -Path "HKLM:\SOFTWARE\IntuneRemediations")
            #Process each value and its actions
            if ($IntuneRemediationsValues.WMICheckStatus -eq 1) {                
               #Call Function Remediate-WMI
               $WMICheckResult = Reset-WMI
            }
            if ($IntuneRemediationsValues.CcmExecCheckStatus -eq 1) {
                # Restart CCM service and trigger a machine policy download
                $CcmExecCheckResult = Restore-CCMService   
            }
            if ($IntuneRemediationsValues.LastMachinePolicyRequestStatus -eq 1) {
                #Force refresh machine policy download
                $LastMachinePolicyRequestResult = Update-CCMMachinePolicy
            }
            if ($IntuneRemediationsValues.CurrentManagementPointStatus -eq 1) {
                #Try to update management point entry on endpoint by restarting CCMExce service
                $CurrentManagementPointResult = Update-CCMManagementPoint
            }

            #Report back on overall remediation status
            #WMI Check Report
            if ($WMICheckResult -eq $true) {
                $RemediationAggregateMessages += " | Remediations logic has run for repairing WMI and passed successfully"
            }
            elseif ($WMICheckResult -eq $False) {
                $RemediationAggregateMessages += " | Remediations logic has run for repairing WMI with errors - see log file"
            }

            #CCM Service Report
            if ($CcmExecCheckResult -eq $true) {
                $RemediationAggregateMessages += " | Remediations has run for CCM Service being stopped and the service was started successfully"
            }
            elseif ($CcmExecCheckResult -eq $False) {
                $RemediationAggregateMessages += " | Remediations has run for CCM Service being stopped but the service could not be restarted"
            }

             #Last Machine Policy Refresh Report
             if ($LastMachinePolicyRequestResult -eq $true) {
                $RemediationAggregateMessages += " | Remediations have run for last policy refresh being older than 24 hours. Result: Success. Last Machine Policy Download Date: $($LastMachinePolicyRequestDate) "
            }
            elseif ($LastMachinePolicyRequestResult -eq $False) {
                $RemediationAggregateMessages += " | Remediations have run for last policy refresh being older than 24 hours. Result: Failed. Last Machine Policy Download Date: $($LastMachinePolicyRequestDate) - see log file for details "
            }   
            
            # Management Point Report
            if ($CurrentManagementPointResult -eq $true) {
                $RemediationAggregateMessages += " | Remediations have run for Management Point entry being empty. Result: Success. Current Management Point is:  $($CurrentManagementPoint) "
            }
            elseif ($CurrentManagementPointResult -eq $False) {
                $RemediationAggregateMessages += " | Remediations have run for Management Point entry being empty. Result: Failed. Current Management Point is empty:  $($CurrentManagementPoint) "
            }               
            
            #If any of the checks is failed, exit with code 1 and return the messages from all checks
            #otherwise, exit with code 0 and return the messages from all checks

            If (($WMICheckResult -eq $true) -or ($CcmExecCheckResult -eq $true) -or ($LastMachinePolicyRequestResult -eq $true) -or ($CurrentManagementPointResult -eq $true)) {                        
                return $RemediationAggregateMessages        
                exit 0
            }
            else {       
                return $RemediationAggregateMessages                 
                exit 1
            }            
        }
        Catch {
            #Could not get the reg keys
            $errMsg = $_.Exception.Message
            return $errMsg
            exit 1
        }
    }
}
#If CCmExec is not found on the system, exit without triggering remediations
else {
    Write-Output "Cannot find $env:windir\CCM\CcmExec.exe | No remediation is required" 
    exit 0   
}

Stop-Transcript 