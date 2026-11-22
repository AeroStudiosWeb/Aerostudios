# AeroStudio unified Windows launcher — four independent creative apps.
# Windows PowerShell 5.1 / Windows Forms. Published download assets are SHA-256 pinned.
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
$form.Size = [System.Drawing.Size]::new(1130,835)
$form.MinimumSize = [System.Drawing.Size]::new(1090,805)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $base
$form.ForeColor = $fg
$form.Font = [System.Drawing.Font]::new('Segoe UI',10)
function New-Label([string]$text,[int]$x,[int]$y,[int]$w,[int]$h,[float]$size,[System.Drawing.Color]$color,[bool]$bold) {
    $ctl = New-Object System.Windows.Forms.Label
    $ctl.Text=$text
    $ctl.Location=[System.Drawing.Point]::new($x,$y)
    $ctl.Size=[System.Drawing.Size]::new($w,$h)
    $ctl.ForeColor=$color
    $ctl.BackColor=[System.Drawing.Color]::Transparent
    $style = if($bold){[System.Drawing.FontStyle]::Bold}else{[System.Drawing.FontStyle]::Regular}
    $ctl.Font = [System.Drawing.Font]::new('Segoe UI',$size,$style)
    return $ctl
}
$form.Controls.Add((New-Label 'A E R O S T U D I O' 40 23 740 48 24 $accent $true))
$form.Controls.Add((New-Label 'One creative suite for aviation photography, enhancement, video and graphics' 42 75 970 30 11 $muted $false))
$form.Controls.Add((New-Label 'INSTALL  /  DOWNLOAD  /  LAUNCH' 42 112 600 25 9 $accent $true))
$apps = @(
    @{Id='AeroRoom';Name='AeroRoom Studio';Role='RAW PHOTOGRAPHY';Description='RAW editing, catalogue and aircraft-focused looks.';Exe='AeroRoomStudio.exe'},
    @{Id='AeroFilm';Name='AeroFilm Studio';Role='AVIATION VIDEO';Description='Timeline editing, shot logging and video export.';Exe='AeroFilmStudio.exe'},
    @{Id='AeroPhoto';Name='AeroPhoto Studio';Role='GRAPHICS & COMPOSITES';Description='Layered graphics, aircraft information cards and artwork.';Exe='AeroPhotoStudio.exe'},
    @{Id='AeroEnhance';Name='AeroEnhance Studio';Role='AI PHOTO ENHANCEMENT';Description='RAW AI denoise, sharpening and high-precision TIFF exports.';Exe='AeroEnhance-Studio.exe'}
)
$status = New-Label 'Ready. Originals and photo catalogues are not modified by this launcher.' 40 763 1030 30 9 $accent $false
$form.Controls.Add((New-Label 'Install from a verified release ZIP, select a trusted local ZIP, or launch an installed app.' 40 735 1030 27 9 $muted $false))
$form.Controls.Add($status)
function Installed($app) {
    return (Join-Path $env:LOCALAPPDATA "AeroStudio\Apps\$($app.Id)\$($app.Exe)")
}
function Start-Installer([string]$id,[string]$method,[string]$path='') {
    $script = Join-Path $Root 'scripts\Install-App.ps1'
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',('"'+$script+'"'),'-App',$id,'-Method',$method)
    if($method -eq 'LocalZip') { $arguments += @('-ZipPath',('"'+$path+'"')) }
    if($method -eq 'LocalExe') { $arguments += @('-ExePath',('"'+$path+'"')) }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $Root
    $status.Text = "$id`: $method started in a separate installer window."
}
function New-ActionButton($card,[string]$text,[int]$x,[int]$y,[int]$w,[int]$h,$tag) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text=$text
    $b.Location=[System.Drawing.Point]::new($x,$y)
    $b.Size=[System.Drawing.Size]::new($w,$h)
    $b.FlatStyle='Flat'
    $b.FlatAppearance.BorderColor=$blue
    $b.BackColor=$blue
    $b.ForeColor=$fg
    $b.Tag=$tag
    $card.Controls.Add($b)
    return $b
}
$cards = @()
for ($i=0; $i -lt $apps.Count; $i++) {
    $a = $apps[$i]
    $col = $i % 2
    $row = [math]::Floor($i / 2)
    $x = 40 + 535*$col
    $y = 150 + 287*$row
    $card = New-Object System.Windows.Forms.Panel
    $card.Location=[System.Drawing.Point]::new($x,$y)
    $card.Size=[System.Drawing.Size]::new(515,277)
    $card.BackColor=$panelColor
    $form.Controls.Add($card)
    $img = Join-Path $Root "Apps\$($a.Id)\assets\aerostudio\icon.png"
    if (-not (Test-Path $img) -and $a.Id -eq 'AeroRoom') {
        $img = Join-Path $Root 'Apps\AeroRoom\assets\app-icon\aeroroom.png'
    }
    if (Test-Path $img) {
        $pic = New-Object System.Windows.Forms.PictureBox
        $pic.Location=[System.Drawing.Point]::new(20,17)
        $pic.Size=[System.Drawing.Size]::new(66,66)
        $pic.SizeMode='Zoom'
        $pic.Image=[System.Drawing.Image]::FromFile($img)
        $card.Controls.Add($pic)
    } else {
        $short = if ($a.Id -eq 'AeroEnhance') {'AI'} else {'AS'}
        $card.Controls.Add((New-Label $short 31 26 60 51 22 $accent $true))
    }
    $card.Controls.Add((New-Label $a.Name 107 21 387 36 17 $fg $true))
    $card.Controls.Add((New-Label $a.Role 107 60 385 27 10 $accent $true))
    $card.Controls.Add((New-Label $a.Description 21 103 472 41 10 $muted $false))
    $state=New-Label 'Checking local installation...' 21 152 472 25 9 $muted $false
    $card.Controls.Add($state)
    $launch=New-ActionButton $card 'Launch' 21 186 108 34 $a
    $launch.Add_Click({
        $entry=$this.Tag
        $exe=Installed $entry
        if(Test-Path -LiteralPath $exe -PathType Leaf) {
            Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe)
        } else {
            [System.Windows.Forms.MessageBox]::Show('Install this app first.','AeroStudio') | Out-Null
        }
    })
    $download=New-ActionButton $card 'Download / Install' 137 186 160 34 $a.Id
    $record=$Manifest.($a.Id)
    $hasRelease=$null -ne $record -and -not [string]::IsNullOrWhiteSpace([string]$record.url) -and -not [string]::IsNullOrWhiteSpace([string]$record.sha256)
    $download.Enabled=$hasRelease
    if(-not $hasRelease){$download.Text='Not hosted yet'}
    $download.Add_Click({ Start-Installer $this.Tag 'Download' })
    $build=New-ActionButton $card 'Build from source' 305 186 188 34 $a.Id
    $build.Enabled = (Test-Path -LiteralPath (Join-Path $Root "Apps\$($a.Id)\Cargo.toml") -PathType Leaf)
    if(-not $build.Enabled) {$build.Text='Source not bundled'}
    $build.Add_Click({Start-Installer $this.Tag 'Build'})
    $zip=New-ActionButton $card 'Install local ZIP' 21 234 150 30 $a.Id
    $zip.Add_Click({
        $picker=New-Object System.Windows.Forms.OpenFileDialog
        $picker.Filter='AeroStudio release archive (*.zip)|*.zip'
        if($picker.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Start-Installer $this.Tag 'LocalZip' $picker.FileName
        }
    })
    $exe=New-ActionButton $card 'Use EXE' 180 234 126 30 $a.Id
    if($a.Id -eq 'AeroEnhance') {
        $exe.Enabled=$false
        $exe.Text='ZIP required'
    }
    $exe.Add_Click({
        $picker=New-Object System.Windows.Forms.OpenFileDialog
        $picker.Filter='Windows executable (*.exe)|*.exe'
        if($picker.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Start-Installer $this.Tag 'LocalExe' $picker.FileName
        }
    })
    if($a.Id -eq 'AeroEnhance') {
        $card.Controls.Add((New-Label 'Installs GPU DLLs too' 323 236 174 30 9 $muted $false))
    } else {
        $card.Controls.Add((New-Label 'Verified ZIP preferred' 323 236 175 30 9 $muted $false))
    }
    $cards += @{ App=$a; State=$state; Launch=$launch }
}
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1200
$timer.Add_Tick({
    foreach($c in $cards) {
        $exe=Installed $c.App
        $installed=Test-Path -LiteralPath $exe -PathType Leaf
        $c.Launch.Enabled=$installed
        $c.State.Text=if($installed){'INSTALLED  -  Ready to launch'}else{'NOT INSTALLED  -  Download or install'}
        $c.State.ForeColor=if($installed){$accent}else{$muted}
    }
})
$timer.Start()
$form.Add_FormClosed({$timer.Stop()})
[void]$form.ShowDialog()
