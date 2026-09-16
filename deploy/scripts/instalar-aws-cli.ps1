<#
.SYNOPSIS
    Prepara un equipo Windows para desplegar AndesStay en AWS.

.DESCRIPTION
    Comprueba e instala las herramientas que necesitan los scripts de despliegue:

      - AWS CLI v2 : crea la instancia, la Elastic IP y los HTTP API.
      - Git        : trae Git Bash, y con él bash, ssh, scp, tar, curl y openssl.

    Docker NO hace falta en el equipo local: las imágenes se construyen dentro
    de la instancia EC2.

    Intenta primero con winget. Si winget no está disponible o la política del
    equipo lo bloquea, descarga el instalador MSI oficial de Amazon y lo ejecuta
    pidiendo elevación.

    Es idempotente: lo que ya está instalado se omite.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File infra\deploy\scripts\instalar-aws-cli.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Write-Paso($texto) { Write-Host "`n==> $texto" -ForegroundColor Cyan }
function Write-Ok($texto)   { Write-Host "  [ok] $texto" -ForegroundColor Green }
function Write-Aviso($texto){ Write-Host "  [aviso] $texto" -ForegroundColor Yellow }

# Refresca el PATH de la sesión actual con el del sistema y el del usuario, para
# detectar un programa recién instalado sin tener que abrir otra terminal.
function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Test-Comando($nombre) {
    return [bool](Get-Command $nombre -ErrorAction SilentlyContinue)
}

$hayWinget = Test-Comando 'winget'

# ── AWS CLI v2 ───────────────────────────────────────────────────────────────
Write-Paso 'AWS CLI v2'

$awsDefault = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'

if ((Test-Comando 'aws') -or (Test-Path $awsDefault)) {
    Update-SessionPath
    $version = if (Test-Comando 'aws') { aws --version } else { & $awsDefault --version }
    Write-Ok "ya instalado: $version"
}
else {
    $instalado = $false

    if ($hayWinget) {
        Write-Host '  instalando con winget...'
        winget install --exact --id Amazon.AWSCLI --silent `
            --accept-source-agreements --accept-package-agreements --disable-interactivity
        $instalado = ($LASTEXITCODE -eq 0)
    }

    if (-not $instalado) {
        Write-Aviso 'winget no disponible o falló; se usa el instalador MSI oficial'
        $msi = Join-Path $env:TEMP 'AWSCLIV2.msi'
        Invoke-WebRequest -Uri 'https://awscli.amazonaws.com/AWSCLIV2.msi' -OutFile $msi -UseBasicParsing

        # msiexec necesita permisos de administrador para instalar en Program Files
        $proceso = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn" -Verb RunAs -Wait -PassThru
        if ($proceso.ExitCode -ne 0) {
            throw "El instalador MSI terminó con código $($proceso.ExitCode). Puede requerir que un administrador del equipo lo ejecute."
        }
        Remove-Item $msi -ErrorAction SilentlyContinue
    }

    Update-SessionPath
    if (Test-Path $awsDefault) {
        Write-Ok "instalado: $(& $awsDefault --version)"
    }
    else {
        throw 'La instalación no dejó aws.exe en la ruta esperada.'
    }
}

# ── Git (y con él Git Bash) ──────────────────────────────────────────────────
Write-Paso 'Git y Git Bash'

if (Test-Comando 'git') {
    Write-Ok "ya instalado: $(git --version)"
}
elseif ($hayWinget) {
    Write-Host '  instalando con winget...'
    winget install --exact --id Git.Git --silent `
        --accept-source-agreements --accept-package-agreements --disable-interactivity
    Update-SessionPath
    if (Test-Comando 'git') { Write-Ok "instalado: $(git --version)" }
    else { Write-Aviso 'Git quedó instalado pero no aparece en el PATH de esta sesión; abrir una terminal nueva.' }
}
else {
    Write-Aviso 'Git no está instalado y winget no está disponible. Descargar desde https://git-scm.com/download/win'
}

# ── Resumen ──────────────────────────────────────────────────────────────────
Write-Paso 'Siguiente paso'

Write-Host @'

  Cerrar esta terminal y abrir Git Bash (menú Inicio → "Git Bash"), para que
  tome el PATH con el AWS CLI recién instalado. Luego, desde la carpeta infra:

    cd deploy
    cp credenciales-aws.example credenciales-aws.txt
    #   pegar en credenciales-aws.txt el bloque de AWS Details → AWS CLI
    bash scripts/aws-session.sh
    bash scripts/crear-infra.sh

  La guía completa está en infra/deploy/README.md.

'@
