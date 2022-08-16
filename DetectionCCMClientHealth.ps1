<# 
.SYNOPSIS
    Script to detect if Configuration Manager Client and WMI is healthy on end points

.DESCRIPTION 
    This script is aimed at hybrid joined devices with ConfigMgr Client falsely reporting as healthy.
    - WMI check to see if Root\CCM is accessible
    - Check Last policy request was within 24 hours
    - Check Current Management Point is set
    - CcmExec service is running
 
.NOTES     

.COMPONENT     

.Author
    Amir Joseph Sayes    
 
.Date
    5/8/2022

.VERSIONS
    Beta: First Script creation and logic
#>

#Variables
# If any of the below variables is set to true in the code below it means remediation should be triggered
$WMICheckStatus = $false 
$CcmExecCheckStatus = $false 
$LastMachinePolicyRequestStatus = $false 
$CurrentManagementPointStatus = $false

#How many hours back within which the CCM Machine policy download date is deemed healthy 
$LastMachinePolicyHoursRang = 24

#Cleanup Variables - useful when testing the script manually on an endpoint.
$AggregateMessages = ""
$PolicyRequestErrorMsg = ""
$WMICheckErrorMsg = ""
$CcmExecErrorMsg = ""
$ManagementPointErrorMsg = ""
$LastMachinePolicyRequest = ""
$CcmExecStatus = ""
$CurrentManagementPoint = ""

$ErrorActionPreference = "Stop"

$CurrentTime = Get-Date -Format "dd_MM_yyyy-HH_mm_ss"
Start-Transcript -Path c:\Windows\logs\DetectingCCMClient_$($env:COMPUTERNAME)_$CurrentTime.log -Force

#Create a key to record the results of this detection script - the key and sub values will be overwritten every time the detection script runs
New-Item -Path "HKLM:\SOFTWARE\" -Name "IntuneRemediations" -Force -Verbose 

#Check if CCMSetup is not running, otherwise, don't run the detections/remediations
$status = Get-Process ccmsetup -ErrorAction SilentlyContinue
if ($status) {
    Write-Output "CCMSetup.exe is running, skipping detection/remediations for this interval"
    Stop-Transcript | Out-Null
    Remove-Item -Path c:\Windows\logs\DetectingCCMClient_$($env:COMPUTERNAME)_$CurrentTime.log -Force | Out-Null
    exit 0
}

#Check if CcmExec.exe exists, otherwise, exit gracefully 
if (Test-Path -Path $env:windir\CCM\CcmExec.exe) {
    Try {
        #Check if we can connect to WMI CCM namespace on the machine
        Get-WmiObject -Namespace "root\ccm" -class SMS_Client | Out-Null
        $AggregateMessages = "Root\CCM is accessible"
        Try {
            #Check last policy Request
            $LastMachinePolicyRequest = (get-wmiobject -query "SELECT LastTriggerTime FROM CCM_Scheduler_History WHERE ScheduleID='{00000000-0000-0000-0000-000000000021}' and UserSID='Machine'" -namespace "Root\CCM\Scheduler").LastTriggerTime
            [datetime]$LastMachinePolicyRequestDate = ([WMI] '').ConvertToDateTime($LastMachinePolicyRequest)
            Write-Host "Last policy request date/time: $($LastMachinePolicyRequestDate)"

            if (($LastMachinePolicyRequest.Length -gt 0)  -and ($LastMachinePolicyRequestDate -gt (get-date).AddHours(-$LastMachinePolicyHoursRang))) {   
                #Machine is requesting policy within specified hours in variable $LastMachinePolicyHoursRang
                $AggregateMessages += " | Last policy request was within $($LastMachinePolicyHoursRang) hours"
                Write-Host "Last policy request was within $($LastMachinePolicyHoursRang) hours from now"
            }
            else {
                #Machine is not requesting refresh
                $PolicyRequestErrorMsg = "Machine has not requested policies within the last $($LastMachinePolicyHoursRang) hours"
                $LastMachinePolicyRequestStatus = $true
                Write-Host "Machine has not requested policies within the last $($LastMachinePolicyHoursRang) hours"
            }
        }
        Catch {
            #Failed to query last policy request
            $PolicyRequestErrorMsg = "Failed to query last policy request date: $($_.Exception.Message)"
            $LastMachinePolicyRequestStatus = $true
            Write-Host "Failed to query last policy request date: $($_.Exception.Message)"
        }      
        Try {
            #Check Management Point entry
            $CurrentManagementPoint = (Get-WmiObject -query "SELECT * FROM SMS_Authority" -namespace "root\ccm").CurrentManagementPoint
            if ($CurrentManagementPoint.Length -gt 0) {   
                #  CurrentManagementPoint is not null      
                $AggregateMessages += " | Current Management Point is:  $($CurrentManagementPoint) "
                Write-Host "Current Management Point is:  $($CurrentManagementPoint)"
            }
            else {
                #Machine has empty string for Management Point Value
                $ManagementPointErrorMsg = "Machine has empty string for Management Point Value"
                $CurrentManagementPointStatus = $true
                Write-Host "Machine has empty string for Management Point Value"
            }
        }
        Catch {
            #Failed to query Management Point value
            $ManagementPointErrorMsg = "Failed to query Management Point value: $($_.Exception.Message)"
            $CurrentManagementPointStatus = $true
            Write-Host "Failed to query Management Point value: $($_.Exception.Message)"
        }     
    }
    catch {
        $WMICheckErrorMsg = "WMI CCM Namespace check failed: $($_.Exception.Message)"    
        $WMICheckStatus = $true    
        write-host "WMI CCM Namespace check failed: $($_.Exception.Message)"    
    }

    #Check SMS service status
    Try {
        #Check if CCMEXEC service is running
        $CcmExecStatus = (Get-Service "CcmExec").Status
        If ($CcmExecStatus -eq "Running") {
            $AggregateMessages += " | CcmExec service is running "    
            Write-Host "CcmExec service is running"
        }
        else {
            $CcmExecErrorMsg = "CCMExec Service is not running"
            $CcmExecCheckStatus =$true
            Write-Host "CCMExec Service is not running"
        }    
    }
    catch {
        $CcmExecErrorMsg = "Failed to query CcmExec: $($_.Exception.Message)"
        $CcmExecCheckStatus =$true
        Write-Host "Failed to query CcmExec: $($_.Exception.Message)"
    }

    #Check overall status and determine exit codes
    If ($WMICheckStatus -or $CcmExecCheckStatus -or $LastMachinePolicyRequestStatus -or $CurrentManagementPointStatus) {        
        If ($WMICheckStatus -eq $true) {
            New-ItemProperty  -Path "HKLM:\SOFTWARE\IntuneRemediations" -PropertyType dword -Name "WMICheckStatus" -Value "1" -Force | Out-Null
            Write-Host "Created reg value WMICheckStatus = 1"
        }
        If ($CcmExecCheckStatus -eq $true) {
            New-ItemProperty  -Path "HKLM:\SOFTWARE\IntuneRemediations" -PropertyType dword -Name "CcmExecCheckStatus" -Value "1" -Force | Out-Null
            Write-Host "Created reg value CcmExecCheckStatus = 1"
        }
        If ($LastMachinePolicyRequestStatus -eq $true) {
            New-ItemProperty  -Path "HKLM:\SOFTWARE\IntuneRemediations" -PropertyType dword -Name "LastMachinePolicyRequestStatus" -Value "1" -Force | Out-Null
            Write-Host "Created reg value LastMachinePolicyRequestStatus = 1"
        }
        If ($CurrentManagementPointStatus -eq $true) {
            New-ItemProperty  -Path "HKLM:\SOFTWARE\IntuneRemediations" -PropertyType dword -Name "CurrentManagementPointStatus" -Value "1" -Force | Out-Null
            Write-Host "Created reg value CurrentManagementPointStatus = 1"
        }
        Write-Output "Triggering remediations: $WMICheckErrorMsg | $PolicyRequestErrorMsg | $CcmExecErrorMsg | $ManagementPointErrorMsg"
        Stop-Transcript | Out-Null
        exit 1
    }
    else {
        Write-Output "$AggregateMessages"
        Stop-Transcript | Out-Null
        Remove-Item -Path c:\Windows\logs\DetectingCCMClient_$($env:COMPUTERNAME)_$CurrentTime.log -Force | Out-Null
        exit 0
    }
}
#If CCmExec is not found on the system, exit without triggering remediations
else {
    Write-Output "Cannot find $env:windir\CCM\CcmExec.exe | No remediation is required"
    Stop-Transcript | Out-Null
    Remove-Item -Path c:\Windows\logs\DetectingCCMClient_$($env:COMPUTERNAME)_$CurrentTime.log -Force | Out-Null
    exit 0
}
Stop-Transcript | Out-Null    