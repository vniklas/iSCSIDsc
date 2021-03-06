$script:DSCModuleName   = 'iSCSIDsc'
$script:DSCResourceName = 'DSR_iSCSIInitiator'

# These tests are disabled because they require iSCSI Loopback
# iSCSI Loopback is supposed to work in Windows Server 2012 R2
# However, as of 2016-01-03 I have not been able to get it to
# work and there is no documentation available on how to do so.
# See http://blogs.technet.com/b/filecab/archive/2012/05/21/introduction-of-iscsi-target-in-windows-server-2012.aspx
# This has been left here in case someone is able to figure out
# how to get it going.
return

#region HEADER
# Integration Test Template Version: 1.1.1
[System.String] $script:moduleRoot = Join-Path -Path $(Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $Script:MyInvocation.MyCommand.Path))) -ChildPath 'Modules\iSCSIDsc'

if ( (-not (Test-Path -Path (Join-Path -Path $script:moduleRoot -ChildPath 'DSCResource.Tests'))) -or `
     (-not (Test-Path -Path (Join-Path -Path $script:moduleRoot -ChildPath 'DSCResource.Tests\TestHelper.psm1'))) )
{
    & git @('clone','https://github.com/PowerShell/DscResource.Tests.git',(Join-Path -Path $script:moduleRoot -ChildPath '\DSCResource.Tests\'))
}

Import-Module (Join-Path -Path $script:moduleRoot -ChildPath 'DSCResource.Tests\TestHelper.psm1') -Force
Import-Module (Join-Path -Path $script:moduleRoot -ChildPath "$($script:DSCModuleName).psd1") -Force
$TestEnvironment = Initialize-TestEnvironment `
    -DSCModuleName $script:DSCModuleName `
    -DSCResourceName $script:DSCResourceName `
    -TestType Integration
#endregion

# Using try/finally to always cleanup even if something awful happens.
try
{
    # Ensure that the tests can be performed on this computer
    $ProductType = (Get-CimInstance Win32_OperatingSystem).ProductType
    Describe 'Environment' {
        Context 'Operating System' {
            It 'Should be a Server OS' {
                $ProductType | Should Be 3
            }
        }
    }
    if ($ProductType -ne 3)
    {
        Break
    }

    $Installed = (Get-WindowsFeature -Name FS-iSCSITarget-Server).Installed
    Describe 'Environment' {
        Context 'Windows Features' {
            It 'Should have the iSCSI Target Feature Installed' {
                $Installed | Should Be $true
            }
        }
    }
    if ($Installed -eq $false)
    {
        Break
    }

    #region Integration Tests
    $ConfigFile = Join-Path -Path $PSScriptRoot -ChildPath "$($script:DSCResourceName).config.ps1"
    . $ConfigFile

    Describe "$($script:DSCResourceName)_Integration" {
        BeforeAll {
            # Create a Server Target on this computer to test with
            $VirtualDiskPath = Join-Path -Path $ENV:Temp -ChildPath ([System.IO.Path]::ChangeExtension([System.IO.Path]::GetRandomFileName(),'vhdx'))
            New-iSCSIVirtualDisk `
                -ComputerName LOCALHOST `
                -Path $VirtualDiskPath `
                -SizeBytes 500MB
            New-iSCSIServerTarget `
                -TargetName $TargetName `
                -InitiatorIds "Iqn:iqn.1991-05.com.microsoft:$($Initiator.InitiatorPortalAddress)" `
                -ComputerName LOCALHOST
            Add-IscsiVirtualDiskTargetMapping `
                -ComputerName LOCALHOST `
                -TargetName $TargetName `
                -Path $VirtualDiskPath
        } # BeforeAll

        #region DEFAULT TESTS
        It 'Should compile and apply the MOF without throwing' {
            {
                & "$($script:DSCResourceName)_Config" -OutputPath $TestDrive
                Start-DscConfiguration -Path $TestDrive -ComputerName localhost -Wait -Verbose -Force
            } | Should not throw
        }

        It 'should be able to call Get-DscConfiguration without throwing' {
            { Get-DscConfiguration -Verbose -ErrorAction Stop } | Should Not throw
        }
        #endregion

        It 'Should have set the resource and all the parameters should match' {
            # Get the Target Portal details
            $TargetPortalNew = Get-iSCSITargetPortal `
                -TargetPortalAddress $TargetPortal.TargetPortalAddress `
                -InitiatorPortalAddress $TargetPortal.InitiatorPortalAddress
            $Initiator.TargetPortalAddress    | Should Be $TargetPortalNew.TargetPortalAddress
            $Initiator.TargetPortalPortNumber | Should Be $TargetPortalNew.TargetPortalPortNumber
            $Initiator.InitiatorInstanceName  | Should Be $TargetPortalNew.InitiatorInstanceName
            $Initiator.InitiatorPortalAddress | Should Be $TargetPortalNew.InitiatorPortalAddress
            $Initiator.IsDataDigest           | Should Be $TargetPortalNew.IsDataDigest
            $Initiator.IsHeaderDigest         | Should Be $TargetPortalNew.IsHeaderDigest
            $TargetNew = Get-iSCSITarget `
                -NodeAddress $Target.NodeAddress
            $Initiator.IsConnected            | Should Be $True
            $Initiator.NodeAddress            | Should Be $TargetNew.NodeAddress
            $SessionNew = Get-iSCSISession `
                -IscsiTarget $TargetNew
            $Initiator.TargetPortalAddress    | Should Be $SessionNew.TargetAddress
            $Initiator.InitiatorPortalAddress | Should Be $SessionNew.InitiatorAddress
            $Initiator.TargetPortalPortNumber | Should Be $SessionNew.TargetPortNumber
            $Initiator.ConnectionIdentifier   | Should Be $SessionNew.ConnectionIdentifier
            $ConnectionNew = Get-iSCSIConnection `
                -NodeAddress $Target.NodeAddress
            $Initiator.AuthenticationType     | Should Be $ConnectionNew.AuthenticationType
            $Initiator.InitiatorInstanceName  | Should Be $ConnectionNew.InitiatorInstanceName
            $Initiator.InitiatorPortalAddress | Should Be $ConnectionNew.InitiatorPortalAddress
            $Initiator.IsConnected            | Should Be $ConnectionNew.IsConnected
            $Initiator.IsDataDigest           | Should Be $ConnectionNew.IsDataDigest
            $Initiator.IsDiscovered           | Should Be $ConnectionNew.IsDiscovered
            $Initiator.IsHeaderDigest         | Should Be $ConnectionNew.IsHeaderDigest
            $Initiator.IsPersistent           | Should Be $ConnectionNew.IsPersistent
            $iSNSServerNew = Get-WmiObject -Class MSiSCSIInitiator_iSNSServerClass -Namespace root\wmi
            # The iSNS Server is not usually accessible so won't be able to be set
            # $Initiator.iSNSServer          | Should Be $iSNSServerNew.iSNSServerAddress
        }

        AfterAll {
            # Clean up
            Disconnect-IscsiTarget `
                -NodeAddress $Initiator.NodeAddress `
                -Confirm:$False
            Remove-IscsiTargetPortal `
                -TargetPortalAddress $Initiator.TargetPortalAddress `
                -InitiatorPortalAddress $Initiator.InitiatorPortalAddress `
                -Confirm:$False
            Remove-iSCSIServerTarget `
                -ComputerName LOCALHOST `
                -TargetName $TargetName
            Remove-iSCSIVirtualDisk `
                -ComputerName LOCALHOST `
                -Path $VirtualDiskPath
            Remove-Item `
                -Path $VirtualDiskPath `
                -Force
        } # AfterAll
    }
    #endregion
}
finally
{
    #region FOOTER
    Restore-TestEnvironment -TestEnvironment $TestEnvironment
    #endregion
}
