
# Configuration Manager Client Self-Heal Using PowerShell and Intune Proactive Remediations

Original Article on [Configuration Manager Client Self-Heal Using PowerShell and Intune Proactive Remediations - Ninar (ninaronline.co.uk)](https://ninaronline.co.uk/2022/08/17/configuration-manager-client-self-heal-using-powershell-and-intune-proactive-remediations/) 

Co-managing Windows Devices made it possible to concurrently manage devices using the good old Configuration Manager and Microsoft Intune. Basically getting the best of both worlds as you transition to modern management.

This opens the door to leveraging  [Intune Proactive Remediations.](https://docs.microsoft.com/en-us/mem/analytics/proactive-remediations)  which enables detection and remediation scripts to find and fix the problem before it is realised and before it becomes a ticket in the Desktop Support queue.

### **The Problem**

Randomly some devices would report to SCCM (Endpoint Configuration Manager) as “Healthy” but in reality they are not, and unless you have a third party software that can reach out to the endpoint and remediate it, the only other solution would require a manual intervention which in many occasions is too little too late (from InfoSec view) and impacts the user’s productivity.

To tackle this, we have grouped the most commonly issues we have seen and wrote a tailored script to detect and remediate them!

### **The Detection Script**

The script can be found on  [GitHub](https://github.com/amirjs/RemediateSCCMClient.git)

The script checks for the following abnormalities on the endpoint:

-   Whether WMI is broken
-   Whether the client policy download date is within the last 24 hours (configurable with variable)
-   Whether CCMExec Service is down.
-   Whether the Management Point entry in WMI is empty.
    

If CCMSetup is running, the script will exit gracefully for this detection intervel

    #Check if CCMSetup is not running, otherwise, don't run the detections/remediations
    
        $status = Get-Process ccmsetup -ErrorAction SilentlyContinue
        
        if  ($status)  {
        
        Write-Output  "CCMSetup.exe is running, skipping detection/remediations for this interval"
        
        Stop-Transcript | Out-Null
        
        Remove-Item -Path c:\Windows\logs\DetectingCCMClient_$($env:COMPUTERNAME)_$CurrentTime.log -Force | Out-Null
        
        exit  0
        
        }

We also check for the existence of CcmExec.exe, if it doesn’t exist, we skip checks as they are not applicable. If it does exist, we go on a series of try/catch and if-else statements to check the health of each component from the above list.

Depending on each check, we build up our “Output” message which eventually will show up in Intune Console. Intune Report will only show the last output that a script is writing out (e.g. Write-host or Write-output) so in order for us to summarise all checks statuses, we build an “Aggregated Message” variable as we go.

### **Combining the Checks!**

Since we are dealing here with 4 different checks, and since there are dependencies between those components; We didn’t want to create 4 separate detection and remediation scripts. Instead, we combined them in a single detection and a single remediation scripts.

The challenge was in controlling “exit” points and how to let the remediation script know what to remediate! In a  [simple one-to-one detection and remediation scripts,](https://docs.microsoft.com/en-us/mem/analytics/powershell-scripts#bkmk_ps_scripts)  it’s usually easy to trigger remediation when a single condition is met during detection. However, in this scenario, a detection script might trigger remediation for one or more of the checks being scanned by the detection script.

**This was dealt with by using a mixture of:-**

-   Boolean variables (flags) to signal which detection has failed.
-   Registry values created on the fly which then used by the remediation logic to trigger the correct healing functions.

When detection finds an issue, it will exit with code 1 and set a reg value in the Registry. This Reg Value is then checked by the remediation script to know what needs fixing. Value of 1 means remediation is needed.

![RegistryValues](https://i0.wp.com/ninaronline.co.uk/wp-content/uploads/2022/08/RegistryValues.png?resize=750%2C278&ssl=1)

Another challenge was to write PoSH/WMI commands that are  [Constrained Language Mode](https://devblogs.microsoft.com/powershell/powershell-constrained-language-mode/)  friendly. In many enterprise environments PoSH is either constrained or restricted on endpoints using the undocumented environment variable __PSLockDownPolicy. So we had to avoid using any commands that would fail unless executed in Full Language Mode.

### **The Remediation Script**

The script can be found on  [GitHub](https://github.com/amirjs/RemediateSCCMClient.git)

When remediations are triggered, they checks the registry for values under key HKLM\SOFTWARE\IntuneRemediations and triggers remediation functions accordingly.

#### **Function  Reset-WMI**

-   Stops winmgmt service
-   Triggers a WMI reset
-   Restarts CcmExec service
-   Waits for CcmSetup to get triggered (10 minutes wait – configurable)
-   Checks the event logs for event 1035 signalling a successful reconfiguration.

#### **Function  Restore-CCMService**

-   Start CcmExec service
-   Wait for 3 minutes
-   Trigger machine policy download

#### **Function  Update-CCMMachinePolicy**

-   Kills ccmexec and start it again
-   Wait for 3 minutes
-   Check if the machine policy download date is recent
-   Go a loop for 25 minutes (configurable) or until the above date is refreshed. Within the loop trigger a check every 5 minutes.
-   Trigger Data Discovery Collection Cycle, Hardware Inventory Cycle and Software Update Scan Cycle

#### **Function  Update-CCMManagmentPoint**

-   Query WMI for CurrentManagementPoint value
-   if empty, restart ccmexec service.

### **Logging**

Also, to have a better insight on what those remediation runs, transcript logging was added for both detection and remediation scripts. They are saved %windir%\logs. These logs are in addition to the native Intune exit code messages that can be seen in Intune (Endpoint Manager) portal.

![LoggingFiles](https://i0.wp.com/ninaronline.co.uk/wp-content/uploads/2022/08/LoggingFiles-2258863630-1660727327519.png?resize=750%2C216&ssl=1)

When a device is found with issues, the script would tell you exactly which checks were detected:

![Pre-remediationDetectionOutput](https://i0.wp.com/ninaronline.co.uk/wp-content/uploads/2022/08/Pre-remediationDetectionOutput.png?resize=750%2C114&ssl=1)

Similarly, post-remediation detection output will have status message detailing the state of each checked service/issue

![PostRemediationDetectionOutput](https://i0.wp.com/ninaronline.co.uk/wp-content/uploads/2022/08/PostRemediationDetectionOutput.png?resize=577%2C207&ssl=1)

Enjoy!
