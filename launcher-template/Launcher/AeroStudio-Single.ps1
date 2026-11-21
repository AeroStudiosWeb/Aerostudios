param([Parameter(Mandatory=$true)][ValidateSet('AeroRoom','AeroFilm','AeroPhoto')][string]$App)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Details = @{
 AeroRoom  = @{Name='AeroRoom Studio';Role='RAW photography and aviation presets';Exe='AeroRoomStudio.exe'}
 AeroFilm  = @{Name='AeroFilm Studio';Role='Aviation video editing';Exe='AeroFilmStudio.exe'}
 AeroPhoto = @{Name='AeroPhoto Studio';Role='Aircraft graphics and compositing';Exe='AeroPhotoStudio.exe'}
}
$Detail = $Details[$App]
$Manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'releases.json') -Raw | ConvertFrom-Json
$record = $Manifest.$App
$canDownload = $null -ne $record -and -not [string]::IsNullOrWhiteSpace([string]$record.url) -and -not [string]::IsNullOrWhiteSpace([string]$record.sha256)
$background = [System.Drawing.ColorTranslator]::FromHtml('#0b1827')
$surface = [System.Drawing.ColorTranslator]::FromHtml('#152c3e')
$white = [System.Drawing.ColorTranslator]::FromHtml('#f1f9fc')
$muted = [System.Drawing.ColorTranslator]::FromHtml('#a6c0ce')
$accent = [System.Drawing.ColorTranslator]::FromHtml('#7bdbe9')
$form = New-Object System.Windows.Forms.Form
$form.Text = "$($Detail.Name) | AeroStudio"
$form.Size = [System.Drawing.Size]::new(570,390)
$form.MinimumSize = [System.Drawing.Size]::new(560,375)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $background
$form.ForeColor = $white
$form.Font = [System.Drawing.Font]::new('Segoe UI',10)
function Add-Text([string]$value,[int]$x,[int]$y,[int]$w,[int]$h,[int]$size,[bool]$bold,[System.Drawing.Color]$color){
 $label = New-Object System.Windows.Forms.Label
 $label.Text = $value
 $label.Location = [System.Drawing.Point]::new($x,$y)
 $label.Size = [System.Drawing.Size]::new($w,$h)
 $style = if($bold){[System.Drawing.FontStyle]::Bold}else{[System.Drawing.FontStyle]::Regular}
 $label.Font = [System.Drawing.Font]::new('Segoe UI',$size,$style)
 $label.ForeColor = $color
 $label.BackColor = [System.Drawing.Color]::Transparent
 $form.Controls.Add($label)
 return $label
}
[void](Add-Text 'AERO  /  STUDIO' 30 24 500 27 11 $true $accent)
[void](Add-Text $Detail.Name 30 66 500 50 25 $true $white)
[void](Add-Text $Detail.Role 31 123 495 26 11 $false $muted)
$status = Add-Text 'Checking local installation...' 30 169 500 30 11 $false $muted
function InstalledPath { return Join-Path $env:LOCALAPPDATA "AeroStudio\Apps\$App\$($Detail.Exe)" }
function Begin-Install([string]$method,[string]$path=''){
 $script = Join-Path $Root 'scripts\Install-App.ps1'
 $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',('"'+$script+'"'),'-App',$App,'-Method',$method)
 if($method -eq 'LocalZip'){$arguments += @('-ZipPath',('"'+$path+'"'))}
 Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $Root
 $status.Text = "${App}: installer opened. Return here after it completes."
}
function Add-Button([string]$name,[int]$x,[int]$y,[int]$w){
 $button = New-Object System.Windows.Forms.Button
 $button.Text = $name
 $button.Location = [System.Drawing.Point]::new($x,$y)
 $button.Size = [System.Drawing.Size]::new($w,43)
 $button.FlatStyle = 'Flat'
 $button.FlatAppearance.BorderColor = $accent
 $button.ForeColor = $white
 $button.BackColor = $surface
 $form.Controls.Add($button)
 return $button
}
$download = Add-Button 'Download / Install' 30 225 190
$download.Enabled = $canDownload
if(-not $canDownload) {$download.Text = 'Release not available'}
$download.Add_Click({ Begin-Install 'Download' })
$launch = Add-Button 'Launch app' 230 225 136
$launch.Add_Click({$exe = InstalledPath;if(Test-Path -LiteralPath $exe -PathType Leaf){Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe)}})
$local = Add-Button 'Install ZIP' 376 225 145
$local.Add_Click({
 $picker = New-Object System.Windows.Forms.OpenFileDialog
 $picker.Filter = 'AeroStudio Windows app ZIP (*.zip)|*.zip'
 if($picker.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){Begin-Install 'LocalZip' $picker.FileName}
})
[void](Add-Text 'The installer verifies the published ZIP with SHA-256 before installing.' 31 294 505 38 9 $false $muted)
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1200
$timer.Add_Tick({
 $ready = Test-Path -LiteralPath (InstalledPath) -PathType Leaf
 $launch.Enabled = $ready
 if($ready) {$status.Text = 'INSTALLED - Ready to launch';$status.ForeColor = $accent}
 elseif(-not $status.Text.Contains('installer opened')) {$status.Text = 'NOT INSTALLED - Download or install a ZIP';$status.ForeColor = $muted}
})
$timer.Start()
$form.Add_FormClosed({$timer.Stop()})
[void]$form.ShowDialog()
