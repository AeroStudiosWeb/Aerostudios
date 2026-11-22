# Backwards-compatible command used in earlier AeroEnhance instructions.
[CmdletBinding()]
param([ValidateSet('CPU','CUDA')][string]$Variant='CUDA', [string]$BuildRoot='', [switch]$SkipTests)
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'build-and-package.ps1') -Variant $Variant -BuildRoot $BuildRoot -SkipTests:$SkipTests
if (-not $?) { throw 'Build / test / packaging failed' }
