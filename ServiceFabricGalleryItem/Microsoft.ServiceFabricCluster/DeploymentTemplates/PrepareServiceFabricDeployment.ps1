﻿param
(
        [parameter(Mandatory = $true)]
        [string] $SubnetIPFormat,

        [parameter(Mandatory = $true)]
        [System.UInt32] $NodeTypeCount
)

$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$VerbosePreference = "Continue"

# Enable File and Printer Sharing for Network Discovery (Port 445)
Write-Verbose "Opening TCP firewall port 445 for networking."
Set-NetFirewallRule -Name 'FPS-SMB-In-TCP' -Enabled True
Get-NetFirewallRule -DisplayGroup 'Network Discovery' | Set-NetFirewallRule -Profile 'Private, Public' -Enabled true

# Add remote IP addresse for Windows Remote Management (HTTP-In)
# This enables every node have access to the nods which are behind different sub domain
# IP got from paramater should have a format of 10.0.[].0/24
Write-Verbose "Add remote IP addresses for Windows Remote Management (HTTP-In) for different sub domain."
$IParray = @()
for($i = 0; $i -lt $NodeTypeCount; $i ++)
{
    $IParray += $SubnetIPFormat.Replace("[]", $i)
}
#Set-NetFirewallRule -Name 'WINRM-HTTP-In-TCP-PUBLIC' -RemoteAddress $IParray
#Write-Verbose "Subnet IPs enabled in WINRM-HTTP-In-TCP-PUBLIC: $IParray"
#TODO - Temporary workaround to enable PSRemoting debugging for JIT
Set-NetFirewallRule -Name 'WINRM-HTTP-In-TCP-PUBLIC' -RemoteAddress Any
Write-Verbose "Enabled WINRM-HTTP-In-TCP-PUBLIC for Any RemoteAddress"

# As per Service fabric documentation at: https://docs.microsoft.com/en-us/azure/service-fabric/service-fabric-windows-cluster-x509-security#install-the-certificates
# set the access control on this certificate so that the Service Fabric process, which runs under the Network Service account, 
# can use it by running the following script. Provide the thumbprint of the certificate and NETWORK SERVICE for the service account.
function Grant-CertAccess
{
    param
    (
    [Parameter(Position=1, Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$subjectName,

    [Parameter(Position=2, Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$serviceAccount
    )

    $cert = Get-ChildItem -Path cert:\LocalMachine\My | Where-Object -FilterScript { $PSItem.SubjectName.Name -eq $subjectName; }
    if ($cert.Count -ne 1)
    {
        Write-Error -Exception "$($cert.Count) certificate(s) with $subjectName found. Expecting only one"
        throw
    }
    # Specify the user, the permissions, and the permission type
    $permission = "$($serviceAccount)","FullControl","Allow"
    $accessRule = New-Object -TypeName System.Security.AccessControl.FileSystemAccessRule -ArgumentList $permission

    # Location of the machine-related keys
    $keyPath = Join-Path -Path $env:ProgramData -ChildPath "\Microsoft\Crypto\RSA\MachineKeys"
    $keyName = $cert.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName
    $keyFullPath = Join-Path -Path $keyPath -ChildPath $keyName

    # Get the current ACL of the private key
    $acl = (Get-Item $keyFullPath).GetAccessControl('Access')

    # Add the new ACE to the ACL of the private key
    $acl.SetAccessRule($accessRule)

    # Write back the new ACL
    Set-Acl -Path $keyFullPath -AclObject $acl -ErrorAction Stop

    # Observe the access rights currently assigned to this certificate
    get-acl $keyFullPath| fl
}

$subjectNames = @{"ClusterCert" = "CN=SFClusterCertificate";
"ServerCert" = "CN=SFServerCertificate";
"ReverseProxyCert" = "CN=SFReverseProxyCertificate" }
# Grant Network Service access to certificates as per the documentation at: 
# https://docs.microsoft.com/en-us/azure/service-fabric/service-fabric-windows-cluster-x509-security#install-the-certificates

Write-Verbose "Granting Network access to SF Cluster Certificate" -Verbose
Grant-CertAccess -subjectName $subjectNames.ClusterCert -serviceAccount "Network Service"
Write-Verbose "Granting Network access to SF Server Certificate" -Verbose
Grant-CertAccess -subjectName $subjectNames.ServerCert -serviceAccount "Network Service"
try {
    Write-Verbose "Granting Network access to SF ReverseProxy Certificate" -Verbose
    Grant-CertAccess -subjectName $subjectNames.ReverseProxyCert -serviceAccount "Network Service"
}
catch {
    Write-Verbose $_
}