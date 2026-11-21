# AeroStudio suite manager. Uses Windows PowerShell 5.1 + Windows Forms, already included with Windows.
# Only AeroStudio builds can be installed from the release manifest; online packages require SHA256.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'releases.json') -Raw | ConvertFrom-Json
$base = [System.Drawing.ColorTranslator]::FromHtml('#0d1727')
$panelColor = [System.Drawing.ColorTranslator]::FromHtml('#182638')
$fg = [System.Drawing.ColorTranslator]::FromHtml('#f3f7fb')
$muted = [System.Drawing.ColorTranslator]::FromHtml('#a0b4c6')
$accent = [System.Drawing.ColorTranslator]::FromHtml('#67d7e9')
$blue = [System.Drawing.ColorTranslator]::FromHtml('#244761')
$form = New-Object System.Windows.Forms.Form
$form.Text = 'AeroStudio | Aviation Creative Suite'
$form.Size = [System.Drawing.Size]::new(1110,670)
$form.MinimumSize = [System.Drawing.Size]::new(1040,650)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $base
$form.ForeColor = $fg
$form.Font = [System.Drawing.Font]::new('Segoe UI',10)
$label = {param($text,$x,$y,$w,$h,$size,$color,$bold)
    $ctl = New-Object System.Windows.Forms.Label
    $ctl.Text=$text; $ctl.Location=[System.Drawing.Point]::new($x,$y); $ctl.Size=[System.Drawing.Size]::new($w,$h)
    $ctl.ForeColor=$color; $ctl.BackColor=[System.Drawing.Color]::Transparent
    $ctl.Font = [System.Drawing.Font]::new('Segoe UI',$size, $(if($bold){[System.Drawing.FontStyle]::Bold}else{[System.Drawing.FontStyle]::Regular}))
    return $ctl
}
$form.Controls.Add((& $label 'A E R O S T U D I O' 40 27 520 50 24 $accent $true))
$form.Controls.Add((& $label 'One creative suite for aviation photography, film and graphics' 42 80 760 34 11 $muted $false))
$form.Controls.Add((& $label 'BUILD  /  INSTALL  /  LAUNCH' 42 119 400 28 9 $accent $true))
$apps = @(
 @{Id='AeroRoom';Name='AeroRoom Studio';Role='RAW photography';Description='RAW editing, catalogue and aircraft-focused looks.\nExisting denoise engine preserved.';Exe='AeroRoomStudio.exe'},
 @{Id='AeroFilm';Name='AeroFilm Studio';Role='Aviation video';Description='Timeline, real aircraft caption clips,\nflight-shot logging and export.';Exe='AeroFilmStudio.exe'},
 @{Id='AeroPhoto';Name='AeroPhoto Studio';Role='Layered artwork';Description='Photo composites, aircraft ID cards,\nvector overlays and embedded layers.';Exe='AeroPhotoStudio.exe'}
)
$info = & $label 'Build from the bundled source, install a trusted release ZIP, or download an official release when one has been published.' 40 566 1020 30 9 $muted $false
$form.Controls.Add($info)
$status = & $label 'Ready. Your originals and existing photo catalogues are not modified by this launcher.' 40 599 1040 30 9 $accent $false
$form.Controls.Add($status)
function Installed($a) { return (Join-Path $env:LOCALAPPDATA "AeroStudio\Apps\$($a.Id)\$($a.Exe)") }
function Start-Installer([string]$id,[string]$method,[string]$zip='') {
    $script = Join-Path $Root 'scripts\Install-App.ps1'
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',('"'+$script+'"'),'-App',$id,'-Method',$method)
    if($method -eq 'LocalZip') { $arguments+=@('-ZipPath',('"'+$zip+'"')) }
    if($method -eq 'LocalExe') { $arguments+=@('-ExePath',('"'+$zip+'"')) }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $Root
    $status.Text = "${id}: $method launched in its own PowerShell window. The launcher stays available."
}
$cards = @()
foreach($i in 0..2) {
    $a=$apps[$i]
    $x=40+$i*350
    $card=New-Object System.Windows.Forms.Panel
    $card.Location=[System.Drawing.Point]::new($x,168)
    $card.Size=[System.Drawing.Size]::new(330,379)
    $card.BackColor=$panelColor
    $form.Controls.Add($card)
    $img = Join-Path $Root "Apps\$($a.Id)\assets\aerostudio\icon.png"
    if(-not (Test-Path $img) -and $a.Id -eq 'AeroRoom') { $img=Join-Path $Root 'Apps\AeroRoom\assets\app-icon\aeroroom.png' }
    if(Test-Path $img) {
        $pic=New-Object System.Windows.Forms.PictureBox
        $pic.Location=[System.Drawing.Point]::new(19,18);$pic.Size=[System.Drawing.Size]::new(70,70)
        $pic.SizeMode='Zoom';$pic.Image=[System.Drawing.Image]::FromFile($img)
        $card.Controls.Add($pic)
    }
    $card.Controls.Add((& $label $a.Name 19 105 305 39 16 $fg $true))
    $card.Controls.Add((& $label $a.Role.ToUpperInvariant() 19 148 290 26 10 $accent $true))
    $description=$a.Description.Replace('\n',"`n")
    $card.Controls.Add((& $label $description 19 187 296 67 10 $muted $false))
    $state=& $label 'Checking installation...' 19 259 300 24 9 $muted $false
    $card.Controls.Add($state)
    $launch=New-Object System.Windows.Forms.Button
    $launch.Text='Launch';$launch.Location=[System.Drawing.Point]::new(19,291);$launch.Size=[System.Drawing.Size]::new(92,34)
    $launch.FlatStyle='Flat';$launch.BackColor=$blue;$launch.ForeColor=$fg;$launch.Tag=$a
    $launch.Add_Click({$entry=$this.Tag;$exe=Installed $entry;if(Test-Path $exe){Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe)}else{[System.Windows.Forms.MessageBox]::Show('Build or install this app first.','AeroStudio') | Out-Null}})
    $card.Controls.Add($launch)
    $build=New-Object System.Windows.Forms.Button
    $build.Text='Build / Install';$build.Location=[System.Drawing.Point]::new(119,291);$build.Size=[System.Drawing.Size]::new(126,34)
    $build.FlatStyle='Flat';$build.BackColor=$blue;$build.ForeColor=$fg;$build.Tag=$a.Id
    if(-not (Test-Path (Join-Path $Root ('Apps\' + $a.Id + '\Cargo.toml')))) { $build.Enabled = $false; $build.Text = 'Build needs source' }
    $build.Add_Click({Start-Installer $this.Tag 'Build'})
    $card.Controls.Add($build)
    $zip=New-Object System.Windows.Forms.Button
    $zip.Text='Install ZIP';$zip.Location=[System.Drawing.Point]::new(19,337);$zip.Size=[System.Drawing.Size]::new(93,30)
    $zip.FlatStyle='Flat';$zip.BackColor=$blue;$zip.ForeColor=$fg;$zip.Tag=$a.Id
    $zip.Add_Click({
        $file=New-Object System.Windows.Forms.OpenFileDialog;$file.Filter='AeroStudio release archive (*.zip)|*.zip'
        if($file.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Start-Installer $this.Tag 'LocalZip' $file.FileName }
    })
    $card.Controls.Add($zip)
    $exe=New-Object System.Windows.Forms.Button
    $exe.Text='Use EXE';$exe.Location=[System.Drawing.Point]::new(119,337);$exe.Size=[System.Drawing.Size]::new(86,30)
    $exe.FlatStyle='Flat';$exe.BackColor=$blue;$exe.ForeColor=$fg;$exe.Tag=$a.Id
    $exe.Add_Click({
        $file=New-Object System.Windows.Forms.OpenFileDialog;$file.Filter='Windows application (*.exe)|*.exe'
        if($file.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Start-Installer $this.Tag 'LocalExe' $file.FileName }
    })
    $card.Controls.Add($exe)
    $download=New-Object System.Windows.Forms.Button
    $download.Text='Download';$download.Location=[System.Drawing.Point]::new(211,337);$download.Size=[System.Drawing.Size]::new(102,30)
    $download.FlatStyle='Flat';$download.BackColor=$blue;$download.ForeColor=$fg;$download.Tag=$a.Id
    $hasRelease=$null -ne $Manifest.($a.Id) -and -not [string]::IsNullOrWhiteSpace([string]$Manifest.($a.Id).url) -and -not [string]::IsNullOrWhiteSpace([string]$Manifest.($a.Id).sha256)
    $download.Enabled=$hasRelease
    if(-not $hasRelease){$download.Text='Not hosted yet'}
    $download.Add_Click({Start-Installer $this.Tag 'Download'})
    $card.Controls.Add($download)
    $cards+=@(@{App=$a;State=$state;Launch=$launch})
}
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval=1500
$timer.Add_Tick({
    foreach($c in $cards) {
        $exe=Installed $c.App
        $installed=Test-Path $exe -PathType Leaf
        $c.Launch.Enabled=$installed
        $c.State.Text=if($installed){'INSTALLED  -  Ready to launch'}else{'NOT INSTALLED  -  Build or install'}
        $c.State.ForeColor=if($installed){$accent}else{$muted}
    }
})
$timer.Start()
$form.Add_FormClosed({$timer.Stop()})
[void]$form.ShowDialog()
