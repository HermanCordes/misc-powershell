<#
.SYNOPSIS
    The Register-FileIOWatcher function watches one or more files and/or subdirectories within a specified Target Directory for
    particular file events. When an event occurs, the specified action will be taken.

.DESCRIPTION
    See SYNOPSIS and PARAMETER sections.

.NOTES
    KNOWN BUG: There is a known bug with System.IO.FileSystemWatcher objects involving triggers firing multiple times for 
    singular events. For details, see: http://stackoverflow.com/questions/1764809/filesystemwatcher-changed-event-is-raised-twice 

    This function works around this bug by using Size as opposed to LastWrite time in the IO.FIleSystemWatcher object's
    NotifyFilter property. However, there is one drawback to this workaround: If the file is modified and remains
    EXACTLY the same size (not very likely, but still possible), then the event will NOT trigger.

.PARAMETER TargetDir
    This parameter is MANDATORY.

    This parameter takes a string that represents a directory that contains one or more files and/or subdirectories that you
    would like to monitor for changes.

.PARAMETER FilesToWatchRegexMatch
    This parameter is OPTIONAL.

    This parameter takes a regex value that specifies one or more files or subdirectories to monitor within the $TargetDir.

    Either this parameter or FilesToWatchEasyMatch MUST be used.

.PARAMETER FilesToWatchEasyMatch
    This parameter is OPTIONAL

    This parameter takes a string value that is pseudo-regex. It acepts wildcard characters. Examples:
    *.*             matches    All files (default)
    *.txt           matches    All files with a "txt" extension.
    *recipe.doc     matches    All files ending in "recipe" with a "doc" extension.
    win*.xml        matches    All files beginning with "win" with an "xml" extension.
    Sales*200?.xls  matches    Files such as "Sales_July_2001.xls","Sales_Aug_2002.xls","Sales_March_2004.xls"
    MyReport.Doc    matches    Only MyReport.doc

    NOTE: You CANNOT use multiple filters such as "*.txt|*.doc". If you would like this functionality, use the
    FilesToWatchRegexMatch parameter.

    Either this parameter or FilesToWatchRegexMatch MUST be used.

.PARAMETER IncludeSubdirectories
    This parameter is OPTIONAL.

    This parameter is a switch. Include it if you want to monitor subdirectories (and their contents) within $TargetDir.

.PARAMETER Trigger
    This parameter is MANDATORY.

    This parameter takes a string and must be one of the following values: 
    "Changed","Created","Deleted","Disposed","Error","Renamed"

    This parameter specifies when a particular event (and its associated action) are triggered.

.PARAMETER ActionToTakeScriptBlock
    This parameter is MANDATORY.

    This parameter takes EITHER a string (that will later be converted to a scriptblock object), or a scriptblock object.

    The scriptblock provided to this parameter defines specifically what action will take place when an event is triggered.

.EXAMPLE
    In in active PowerShell Console, try the following:
    (IMPORTANT: Make sure the characters '@ are justified all-the-way to the left regardless of indentations elsewhere)

    $TestTargetDir = "$HOME"
    $GCITest = Get-ChildItem -Path "$HOME\Downloads"

    $ActionToTake = @'
Write-Host "Hello there!"

Write-Host "Writing Register-FileIOWatcher value for parameter -Trigger"
Write-Host "$Trigger"
Write-Host "Writing fullname of the first item in `$GCITest object index to STDOUT"
Write-Host "$($GCITest[0].FullName)"
Write-Host "Setting new variable `$AltGCI equal to `$GCITest"
$AltGCI = $GCITest
Write-Host "Writing `$AltGCI out to file `$HOME\Documents\AltGCIOutput.txt"
$AltGCI | Out-File $HOME\Documents\AltGCIOutput.txt

Write-Host "Bye!"
'@

    Register-FileIOWatcher -TargetDir "$TestTargetDir" `
    -FilesToWatchEasyMatch "SpecificDoc.txt" `
    -Trigger "Changed" `
    -ActionToTakeScriptBlock $ActionToTake

    Next, create/make a change to the file $HOME\SpecificDoc.txt and save it. This will trigger the
    $ActionToTake scriptblock. (Note that $ActionToTake is actually a string that is converted a scriptblock object 
    by the function). Anything in the scriptblock using the Write-Host cmdlet will appear in STDOUT in your active PowerShell 
    session. If your scriptblock does NOT use the  Write-Host cmdlet, it will NOT appear in your active PowerShell session
    (but, of course, the operations will still occur).

.OUTPUTS
    At the conclusion of this function a new Global PSCustomObject is created called:
        $global:FileIOWatcherFor<TARGETDIRECTORYNAME>
    This PSCustomObject contains the following:
    
        Event                    : System.Management.Automation.PSEventArgs
        SubscriberEvent          : System.Management.Automation.PSEventSubscriber
        TriggerType              : Changed
        TimeStamp                : 2/11/2017 6:57:02 AM
        FilesThatChanged         :
        FilesThatChangedFullPath :

    When the event is triggered (in this case, when a change to the file SpecificDoc.txt occurs), a NEW Global PSCustomObject
    is created called:
        $global:FileIOWatcherFor<TARGETDIRECTORYNAME><EventIdentifierNumber>

    Since you won't necessarily know the EventIdentifierNumber ahead of time, to get the variable created upon the most
    recent trigger, use tab completion, or in a scripting context, use the following:
        $TestTargetDirLeaf = $TestTargetDir | Split-Path -Leaf
        $LatestEventVarName = $($(Get-Variable | Where-Object {$_.Name -like "FileIOWatcher*$TestTargetDirLeaf*[0-9+]"}).Name | Measure-Object -Maximum).Maximum
        Get-Variable -Name "$LatestEventVarName" -ValueOnly

    To review the scriptblock that was executed, inspect the PSCustomObject as follows:
        $(Get-Variable -Name "$LatestEventVarName" -ValueOnly).SubscriberEvent.Action.Command
#>

Function Register-FileIOWatcher {
    [CmdletBinding(PositionalBinding=$True)]
    Param(
        [Parameter(Mandatory=$False)]
        [string]$TargetDir = $(Read-Host -Prompt "Please enter the full path to the directory that contains the file(s) you would like to watch."),

        [Parameter(Mandatory=$False)]
        [regex]$FilesToWatchRegexMatch,

        [Parameter(Mandatory=$False)]
        [string]$FilesToWatchEasyMatch,

        [Parameter(Mandatory=$False)]
        [switch]$IncludeSubdirectories,

        [Parameter(Mandatory=$True)]
        [ValidateSet("Changed","Created","Deleted","Disposed","Error","Renamed")]
        $Trigger,

        [Parameter(Mandatory=$True)]
        $ActionToTakeScriptBlock # Can be a string or a scriptblock. If string, the function will handle converting it to a scriptblock object.
    )

    ##### BEGIN Variable/Parameter Transforms and PreRun Prep #####
    # Make sure $TargetPath is a valid path
    $TargetDirNameOnly = $TargetDir | Split-Path -Leaf

    if ( !$($([uri]$TargetDir).IsAbsoluteURI -and $($([uri]$TargetDir).IsLoopBack -or $([uri]$TargetDir).IsUnc)) ) {
        Write-Verbose "$TargetDir is not a valid directory path! Halting!"
        Write-Error "$TargetDir is not a valid directory path! Halting!"
        $global:FunctionResult = "1"
        return
    }
    if (!$(Test-Path $TargetDir)) {
        Write-Verbose "The path $TargetDir was not found! Halting!"
        Write-Error "The path $TargetDir was not found! Halting!"
        $global:FunctionResult = "1"
        return
    }

    if ($FilesToWatchRegexMatch -and $FilesToWatchEasyMatch) {
        Write-Verbose "Please use *either* the `$FilesToWatchRegexMatch parameter *or* the `$FilesToWatchEasyMatch parameter. Halting!"
        Write-Error "Please use *either* the `$FilesToWatchRegexMatch parameter *or* the `$FilesToWatchEasyMatch parameter. Halting!"
        $global:FunctionResult = "1"
        return
    }
    if (!$FilesToWatchRegexMatch -and !$FilesToWatchEasyMatch) {
        Write-Verbose "You must use either the `$FilesToWatchRegexMatch parameter or the `$FilesToWatchEasyMatch parameter in order to specify which files you would like to watch in the directory `"$TargetDir`". Halting!"
        Write-Error "You must use either the `$FilesToWatchRegexMatch parameter or the `$FilesToWatchEasyMatch parameter in order to specify which files you would like to watch in the directory `"$TargetDir`". Halting!"
        $global:FunctionResult = "1"
        return
    }

    if ($($ActionToTakeScriptBlock.GetType()).FullName -eq "System.Management.Automation.ScriptBlock") {
        $UpdatedActionToTakeScriptBlock = $ActionToTakeScriptBlock
    }
    if ($($ActionToTakeScriptBlock.GetType()).FullName -eq "System.String") {
        $UpdatedActionToTakeScriptBlock = [scriptblock]::Create($ActionToTakeScriptBlock)
    }
    if ($($ActionToTakeScriptBlock.GetType()).FullName -notmatch "System.Management.Automation.ScriptBlock|System.String") {
        Write-Verbose "The value passed to the `$ActionToTakeScriptBlock parameter must either be a System.Management.Automation.ScriptBlock or System.String! Halting!"
        Write-Error "The value passed to the `$ActionToTakeScriptBlock parameter must either be a System.Management.Automation.ScriptBlock or System.String! Halting!"
        $global:FunctionResult = "1"
        return
    }

    ##### END Variable/Parameter Transforms and PreRun Prep #####


    ##### BEGIN Main Body #####

    $Watcher = New-Object IO.FileSystemWatcher
    $Watcher.Path = $TargetDir
    # Setting NotifyFilter to FileName, DirectoryName, and Size as opposed to FileName, DirectoryName, and LastWrite
    # prevents the bug that causes the trigger fire twice on Change to LastWrite time.
    # Bug: http://stackoverflow.com/questions/1764809/filesystemwatcher-changed-event-is-raised-twice
    $watcher.NotifyFilter = "FileName, DirectoryName, Size"
    # NOTE: The Filter property can't handle normal regex, so if $FileToWatchRegexMatch is used, just temporarily set it to 
    # every file and do the regex check in the $FilesToWatchRegexMatchClause which is ultimately added to the 
    # $AlwaysIncludeInScriptBlock script block
    if ($FilesToWatchRegexMatch) {
        $Watcher.Filter = "*.*"
    }
    if ($FilesToWatchEasyMatch) {
        $Watcher.Filter = $FilesToWatchEasyMatch
    }
    if ($IncludeSubdirectories) {
        $Watcher.IncludeSubdirectories = $True
    }
    else {
        $Watcher.IncludeSubdirectories = $False
    }
    $Watcher.EnableRaisingEvents = $True

    $ValidExistingVariablesPrep = $(Get-Variable).Name
    [System.Collections.ArrayList]$ValidExistingVariables = $ValidExistingVariablesPrep
    $FunctionParamVarsToPassToScriptBlock = @("TargetDir","FilesToWatchRegexMatch","FilesToWatchEasyMatch","IncludeSubdirectories","Trigger")
    foreach ($ParamName in $FunctionParamVar) {
        if ($ValidExistingVariables -notcontains $ParamName) {
            $ValidExistingVariables.Add("$ParamName")
        }
    }

    # Adding Array elements in this manner becaue order is important
    [System.Collections.ArrayList]$FunctionParamVarsToPassToScriptBlock = @("TargetDir")
    if ($FilesToWatchRegexMatch) {
        $FunctionParamVarsToPassToScriptBlock.Add("FilesToWatchRegexMatch") | Out-Null
    }
    if ($FilesToWatchEasyMatch) {
        $FunctionParamVarsToPassToScriptBlock.Add("FilesToWatchEasyMatch") | Out-Null
    }
    if ($IncludeSubdirectories) {
        $FunctionParamVarsToPassToScriptBlock.Add("IncludeSubdirectories") | Out-Null
    }
    $FunctionParamVarsToPassToScriptBlock.Add("Trigger") | Out-Null
    

    $FunctionArgsToBeUsedByActionToTakeScriptBlock = @()
    foreach ($VarName in $FunctionParamVarsToPassToScriptBlock) {
        # The below $StringToBePassedToScriptBlock is valid because all of the function parameters can be represented as strings
        $StringToBePassedToScriptBlock = "`$$VarName = '$(Get-Variable -Name $VarName -ValueOnly)'"
        $FunctionArgsToBeUsedByActionToTakeScriptBlock += $StringToBePassedToScriptBlock
    }
    $UpdatedFunctionArgsToBeUsedByActionToTakeScriptBlockAsString = $($FunctionArgsToBeUsedByActionToTakeScriptBlock | Out-String).Trim()

    if ($FilesToWatchRegexMatch) {
        $FilesToWatchRegexMatchClause = @"
`$FilesOfConcern = @()
foreach (`$file in `$FilesThatChanged) {
    if (`$file -match `'$FilesToWatchRegexMatch`') {
        `$FilesOfConcern += `$file
    }
}
if (`$FilesOfConcern.Count -lt 1) {
    Write-Verbose "The files that were $Trigger in the target directory $TargetDir do not match the specified regex. No action taken."
    return
}
"@
    }

    # Always include the following in whatever scriptblock is passed to $ActionToTakeScriptBlock parameter
    # NOTE: $Event is an automatic variable that becomes available in the context of the Regiter-ObjectEvent cmdlet
    # For more information, see:
    # https://msdn.microsoft.com/en-us/powershell/reference/5.1/microsoft.powershell.utility/register-objectevent
    # https://msdn.microsoft.com/en-us/powershell/reference/5.1/microsoft.powershell.core/about/about_automatic_variables

    $AlwaysIncludeInScriptBlock = @"

############################################################
# BEGIN Always Included ScriptBlock
############################################################

`$FilesThatChanged = `$Event.SourceEventArgs.Name
`$FilesThatChangedFullPath = `$Event.SourceEventArgs.FullPath

$FilesToWatchRegexMatchClause

`$PSEvent = `$Event
`$SourceIdentifier = `$Event.SourceIdentifier
`$PSEventSubscriber = Get-EventSubscriber | Where-Object {`$_.SourceIdentifier -eq `$SourceIdentifier}
`$EventIdentifier = `$Event.EventIdentifier
`$TriggerType = `$Event.SourceEventArgs.ChangeType
`$TimeStamp = `$Event.TimeGenerated

if (`$(Get-Variable).Name -notcontains "FileIOWatcherFor$TargetDirNameOnly") {
    `$NewVariableName = "FileIOWatcherFor$TargetDirNameOnly"
}
if (`$(Get-Variable).Name -contains "FileIOWatcherFor$TargetDirNameOnly") {
    `$NewVariableName = "FileIOWatcherFor$TargetDirNameOnly`$EventIdentifier"
}
New-Variable -Name "`$NewVariableName" -Scope Global -Value `$(
    New-Object PSObject -Property @{
        Event                      = `$PSEvent
        SubscriberEvent            = `$PSEventSubscriber
        FilesThatChangedFullPath   = `$FilesThatChangedFullPath
        FilesThatChanged           = `$FilesThatChanged
        TriggerType                = `$TriggerType
        TimeStamp                  = `$TimeStamp
    }
)

##### BEGIN Function Args Passed To ScriptBlock #####

$UpdatedFunctionArgsToBeUsedByActionToTakeScriptBlockAsString

##### END Function Args Passed To ScriptBlock  #####

############################################################
# END Always Included ScriptBlock
############################################################

#############################################################################
# BEGIN ScriptBlock Passed In Using The Parameter -ActionToTakeScriptBlock
#############################################################################

"@

    $Action = [scriptblock]::Create($AlwaysIncludeInScriptBlock+"`n"+$UpdatedActionToTakeScriptBlock.ToString())

    Register-ObjectEvent -InputObject $Watcher -EventName "$Trigger" -Action $Action

    ##### END Main Body #####
}









# SIG # Begin signature block
# MIIMLAYJKoZIhvcNAQcCoIIMHTCCDBkCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQU2fs6xdA9h9wSYF/I1M3Etlqv
# ammgggmhMIID/jCCAuagAwIBAgITawAAAAQpgJFit9ZYVQAAAAAABDANBgkqhkiG
# 9w0BAQsFADAwMQwwCgYDVQQGEwNMQUIxDTALBgNVBAoTBFpFUk8xETAPBgNVBAMT
# CFplcm9EQzAxMB4XDTE1MDkwOTA5NTAyNFoXDTE3MDkwOTEwMDAyNFowPTETMBEG
# CgmSJomT8ixkARkWA0xBQjEUMBIGCgmSJomT8ixkARkWBFpFUk8xEDAOBgNVBAMT
# B1plcm9TQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCmRIzy6nwK
# uqvhoz297kYdDXs2Wom5QCxzN9KiqAW0VaVTo1eW1ZbwZo13Qxe+6qsIJV2uUuu/
# 3jNG1YRGrZSHuwheau17K9C/RZsuzKu93O02d7zv2mfBfGMJaJx8EM4EQ8rfn9E+
# yzLsh65bWmLlbH5OVA0943qNAAJKwrgY9cpfDhOWiYLirAnMgzhQd3+DGl7X79aJ
# h7GdVJQ/qEZ6j0/9bTc7ubvLMcJhJCnBZaFyXmoGfoOO6HW1GcuEUwIq67hT1rI3
# oPx6GtFfhCqyevYtFJ0Typ40Ng7U73F2hQfsW+VPnbRJI4wSgigCHFaaw38bG4MH
# Nr0yJDM0G8XhAgMBAAGjggECMIH/MBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQW
# BBQ4uUFq5iV2t7PneWtOJALUX3gTcTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMA
# QTAOBgNVHQ8BAf8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBR2
# lbqmEvZFA0XsBkGBBXi2Cvs4TTAxBgNVHR8EKjAoMCagJKAihiBodHRwOi8vcGtp
# L2NlcnRkYXRhL1plcm9EQzAxLmNybDA8BggrBgEFBQcBAQQwMC4wLAYIKwYBBQUH
# MAKGIGh0dHA6Ly9wa2kvY2VydGRhdGEvWmVyb0RDMDEuY3J0MA0GCSqGSIb3DQEB
# CwUAA4IBAQAUFYmOmjvbp3goa3y95eKMDVxA6xdwhf6GrIZoAg0LM+9f8zQOhEK9
# I7n1WbUocOVAoP7OnZZKB+Cx6y6Ek5Q8PeezoWm5oPg9XUniy5bFPyl0CqSaNWUZ
# /zC1BE4HBFF55YM0724nBtNYUMJ93oW/UxsWL701c3ZuyxBhrxtlk9TYIttyuGJI
# JtbuFlco7veXEPfHibzE+JYc1MoGF/whz6l7bC8XbgyDprU1JS538gbgPBir4RPw
# dFydubWuhaVzRlU3wedYMsZ4iejV2xsf8MHF/EHyc/Ft0UnvcxBqD0sQQVkOS82X
# +IByWP0uDQ2zOA1L032uFHHA65Bt32w8MIIFmzCCBIOgAwIBAgITWAAAADw2o858
# ZSLnRQAAAAAAPDANBgkqhkiG9w0BAQsFADA9MRMwEQYKCZImiZPyLGQBGRYDTEFC
# MRQwEgYKCZImiZPyLGQBGRYEWkVSTzEQMA4GA1UEAxMHWmVyb1NDQTAeFw0xNTEw
# MjcxMzM1MDFaFw0xNzA5MDkxMDAwMjRaMD4xCzAJBgNVBAYTAlVTMQswCQYDVQQI
# EwJWQTEPMA0GA1UEBxMGTWNMZWFuMREwDwYDVQQDEwhaZXJvQ29kZTCCASIwDQYJ
# KoZIhvcNAQEBBQADggEPADCCAQoCggEBAJ8LM3f3308MLwBHi99dvOQqGsLeC11p
# usrqMgmEgv9FHsYv+IIrW/2/QyBXVbAaQAt96Tod/CtHsz77L3F0SLuQjIFNb522
# sSPAfDoDpsrUnZYVB/PTGNDsAs1SZhI1kTKIjf5xShrWxo0EbDG5+pnu5QHu+EY6
# irn6C1FHhOilCcwInmNt78Wbm3UcXtoxjeUl+HlrAOxG130MmZYWNvJ71jfsb6lS
# FFE6VXqJ6/V78LIoEg5lWkuNc+XpbYk47Zog+pYvJf7zOric5VpnKMK8EdJj6Dze
# 4tJ51tDoo7pYDEUJMfFMwNOO1Ij4nL7WAz6bO59suqf5cxQGd5KDJ1ECAwEAAaOC
# ApEwggKNMA4GA1UdDwEB/wQEAwIHgDA9BgkrBgEEAYI3FQcEMDAuBiYrBgEEAYI3
# FQiDuPQ/hJvyeYPxjziDsLcyhtHNeIEnofPMH4/ZVQIBZAIBBTAdBgNVHQ4EFgQU
# a5b4DOy+EUyy2ILzpUFMmuyew40wHwYDVR0jBBgwFoAUOLlBauYldrez53lrTiQC
# 1F94E3EwgeMGA1UdHwSB2zCB2DCB1aCB0qCBz4aBq2xkYXA6Ly8vQ049WmVyb1ND
# QSxDTj1aZXJvU0NBLENOPUNEUCxDTj1QdWJsaWMlMjBLZXklMjBTZXJ2aWNlcyxD
# Tj1TZXJ2aWNlcyxDTj1Db25maWd1cmF0aW9uLERDPXplcm8sREM9bGFiP2NlcnRp
# ZmljYXRlUmV2b2NhdGlvbkxpc3Q/YmFzZT9vYmplY3RDbGFzcz1jUkxEaXN0cmli
# dXRpb25Qb2ludIYfaHR0cDovL3BraS9jZXJ0ZGF0YS9aZXJvU0NBLmNybDCB4wYI
# KwYBBQUHAQEEgdYwgdMwgaMGCCsGAQUFBzAChoGWbGRhcDovLy9DTj1aZXJvU0NB
# LENOPUFJQSxDTj1QdWJsaWMlMjBLZXklMjBTZXJ2aWNlcyxDTj1TZXJ2aWNlcyxD
# Tj1Db25maWd1cmF0aW9uLERDPXplcm8sREM9bGFiP2NBQ2VydGlmaWNhdGU/YmFz
# ZT9vYmplY3RDbGFzcz1jZXJ0aWZpY2F0aW9uQXV0aG9yaXR5MCsGCCsGAQUFBzAC
# hh9odHRwOi8vcGtpL2NlcnRkYXRhL1plcm9TQ0EuY3J0MBMGA1UdJQQMMAoGCCsG
# AQUFBwMDMBsGCSsGAQQBgjcVCgQOMAwwCgYIKwYBBQUHAwMwDQYJKoZIhvcNAQEL
# BQADggEBACbc1NDl3NTMuqFwTFd8NHHCsSudkVhuroySobzUaFJN2XHbdDkzquFF
# 6f7KFWjqR3VN7RAi8arW8zESCKovPolltpp3Qu58v59qZLhbXnQmgelpA620bP75
# zv8xVxB9/xmmpOHNkM6qsye4IJur/JwhoHLGqCRwU2hxP1pu62NUK2vd/Ibm8c6w
# PZoB0BcC7SETNB8x2uKzJ2MyAIuyN0Uy/mGDeLyz9cSboKoG6aQibnjCnGAVOVn6
# J7bvYWJsGu7HukMoTAIqC6oMGerNakhOCgrhU7m+cERPkTcADVH/PWhy+FJWd2px
# ViKcyzWQSyX93PcOj2SsHvi7vEAfCGcxggH1MIIB8QIBATBUMD0xEzARBgoJkiaJ
# k/IsZAEZFgNMQUIxFDASBgoJkiaJk/IsZAEZFgRaRVJPMRAwDgYDVQQDEwdaZXJv
# U0NBAhNYAAAAPDajznxlIudFAAAAAAA8MAkGBSsOAwIaBQCgeDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMCMGCSqGSIb3DQEJBDEWBBQMIImQnXUv
# LxSlFZCS73QwQzl/PjANBgkqhkiG9w0BAQEFAASCAQCMinwPKlnorFR+RKv9iDSg
# fV1HP/HT2nBA+atuKBas4l2zxEKiUscOgH81OS19zg+Sk6/bs3i84RSNjlM08u3a
# E+9K+DUkMXO0xckhC6/DbO6s768XdZ6H24myCmX5lf9HwRt3FGJghf2HBEcgVJBD
# CpmBulm9Ex8sfmWirvrDvde+r0dAdtbBcxq+El5SAMnz3/Nbe2hdqQ6vfwfvpTzI
# 9TYaCY/21Gpl4n3NV4S0MzTYskgn+CbbSWr/XeeCt8NtZuMt4MAiAEyt9x3D9xJR
# /IFZhgYB3K4fJ2cp2V8lTkfN9IMhJMFfA1cXqYYN3tYwzjolGEgv/Rw5lHZyYJYb
# SIG # End signature block
