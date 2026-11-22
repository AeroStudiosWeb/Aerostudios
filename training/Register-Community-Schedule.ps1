<#
OPTIONAL local Windows Task Scheduler registration.
Scheduled tasks can only prepare a reviewer CSV or produce private candidate
weights, NEVER sign/publish/activate or bypass per-image human approval.
Operator invokes this manually after reading the privacy/setup guide.
#>
[CmdletBinding()]
param(
  [ValidateSet('Review','Candidate')][string]$Task = 'Review',
  [Parameter(Mandatory=$true)][string]$FeedbackDir,
  [Parameter(Mandatory=$true)][string]$ReviewCsv,
  [string]$BaseDataset = '',
  [string]$BenchmarkDataset = '',
  [string]$IncumbentCheckpoint = '',
  [string]$RunsRoot = '',
  [string]$AviationDataset = '',
  [string]$At = '18:00'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if ($At -notmatch '^([01][0-9]|2[0-3]):[0-5][0-9]$') {throw 'Use HH:MM in local time'}
if ($Task -eq 'Candidate') {
  foreach ($p in @($BaseDataset,$BenchmarkDataset,$IncumbentCheckpoint,$RunsRoot)) {
    if (!$p) {throw 'Candidate scheduling requires all dataset, incumbent and run locations'}
  }
}
$script = Join-Path $PSScriptRoot 'Weekly-AeroLearning.ps1'
$arguments = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$script,
  '-Phase',$(if($Task -eq 'Candidate'){'Train'}else{'Review'}),
  '-FeedbackDir',$FeedbackDir,'-ReviewCsv',$ReviewCsv)
if ($Task -eq 'Candidate') {
  $arguments += @('-BaseDataset',$BaseDataset,'-BenchmarkDataset',$BenchmarkDataset,
                  '-IncumbentCheckpoint',$IncumbentCheckpoint,'-RunsRoot',$RunsRoot)
  if ($AviationDataset) {$arguments += @('-AviationDataset',$AviationDataset)}
  $arguments += '-ConfirmCuration'
}
foreach ($a in $arguments) {if ($a.Contains('"')) {throw 'Invalid double-quote in path/argument'}}
$line = ($arguments | ForEach-Object {if ($_ -match '\s') {'"'+$_+'"'} else {$_}}) -join ' '
$name = if ($Task -eq 'Candidate') {'AeroEnhance Community Candidate (PRIVATE)'} else {'AeroEnhance Community Review (PRIVATE)'}
if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
  throw "Task '$name' already exists. Review it manually instead of overwriting silently."
}
$time = [datetime]::ParseExact($At,'HH:mm',[Globalization.CultureInfo]::InvariantCulture)
$day = if ($Task -eq 'Candidate') {'Saturday'} else {'Friday'}
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $day -At $time
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $line -WorkingDirectory (Split-Path $PSScriptRoot -Parent)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 24)
# Interactive-token tasks only run while the operator is logged on;
# avoid putting Windows passwords or service credentials into source code.
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
  -Description 'AeroEnhance private weekly curation/training candidate; NO automatic model publication' | Out-Null
Write-Host "Registered $name, $day at $At local time. PRIVATE; no user data auto-approved or models published." -ForegroundColor Green
Write-Host 'Review Task Scheduler history for failures. These tasks require an operator logged in.'
