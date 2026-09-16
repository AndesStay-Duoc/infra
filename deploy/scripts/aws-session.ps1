<#
.SYNOPSIS
    Carga las credenciales temporales del AWS Learner Lab en el perfil "andesstay".

.DESCRIPTION
    El Learner Lab entrega credenciales que caducan a las ~4 horas. Este script
    toma el bloque que muestra el botón "AWS Details -> AWS CLI" tal cual, lo
    interpreta y escribe el perfil en %USERPROFILE%\.aws\credentials.

    Evita transcribir las tres claves a mano, que es donde se cuela el error que
    después aparece como InvalidClientTokenId o SignatureDoesNotMatch.

    Estas credenciales NO se comparten con el equipo ni se guardan en la carpeta
    de secretos: caducan demasiado rápido para que tenga sentido. Cada integrante
    abre su propio laboratorio y ejecuta este script.

.EXAMPLE
    .\aws-session.ps1
    Pide pegar el bloque y terminar con una línea en blanco.

.EXAMPLE
    Get-Clipboard | .\aws-session.ps1
    Toma el bloque directamente del portapapeles.

.EXAMPLE
    Get-Content .\credenciales.txt | .\aws-session.ps1
#>

[CmdletBinding()]
param(
    # Nombre del perfil en ~/.aws/credentials
    [string] $ProfileName = 'andesstay',

    # El Learner Lab solo opera en esta región
    [string] $Region = 'us-east-1',

    [Parameter(ValueFromPipeline = $true)]
    [string[]] $InputLines
)

begin {
    $ErrorActionPreference = 'Stop'
    $collected = New-Object System.Collections.Generic.List[string]
}

process {
    if ($InputLines) { $InputLines | ForEach-Object { $collected.Add($_) } }
}

end {
    # Sin entrada por tubería, se pide pegar el bloque de forma interactiva
    if ($collected.Count -eq 0) {
        Write-Host ''
        Write-Host 'Pegar el bloque de AWS Details -> AWS CLI y terminar con una línea en blanco:' -ForegroundColor Cyan
        Write-Host '(tiene el aspecto de [default] / aws_access_key_id=... / aws_secret_access_key=... / aws_session_token=...)' -ForegroundColor DarkGray
        Write-Host ''

        while ($true) {
            $line = Read-Host
            if ([string]::IsNullOrWhiteSpace($line)) { break }
            $collected.Add($line)
        }
    }

    if ($collected.Count -eq 0) {
        throw 'No se recibió ninguna línea.'
    }

    # ── Interpretación del bloque ────────────────────────────────────────────
    # Se acepta tanto "clave=valor" como "clave = valor", y se ignoran las
    # líneas de sección como [default].
    $creds = @{}
    foreach ($line in $collected) {
        if ($line -match '^\s*(aws_access_key_id|aws_secret_access_key|aws_session_token)\s*=\s*(.+?)\s*$') {
            $creds[$Matches[1]] = $Matches[2]
        }
    }

    $required = @('aws_access_key_id', 'aws_secret_access_key', 'aws_session_token')
    $missing  = $required | Where-Object { -not $creds.ContainsKey($_) }

    if ($missing) {
        throw "Faltan claves en el bloque pegado: $($missing -join ', ')"
    }

    # Las credenciales temporales de STS empiezan por ASIA. Una que empiece por
    # AKIA es una credencial permanente y no viene del Learner Lab.
    if ($creds['aws_access_key_id'] -notlike 'ASIA*') {
        Write-Warning "El access key no empieza por ASIA: puede no ser una credencial temporal del laboratorio."
    }

    # ── Escritura del perfil ─────────────────────────────────────────────────
    $awsDir  = Join-Path $env:USERPROFILE '.aws'
    $credsIn = Join-Path $awsDir 'credentials'
    $confIn  = Join-Path $awsDir 'config'

    if (-not (Test-Path $awsDir)) {
        New-Item -ItemType Directory -Path $awsDir | Out-Null
    }

    # Se conservan los demás perfiles: solo se reemplaza el bloque de este.
    $existing = @()
    if (Test-Path $credsIn) {
        $all = Get-Content $credsIn
        $inTargetProfile = $false
        foreach ($line in $all) {
            if ($line -match '^\s*\[(.+)\]\s*$') {
                $inTargetProfile = ($Matches[1] -eq $ProfileName)
            }
            if (-not $inTargetProfile) { $existing += $line }
        }
    }

    $block = @(
        "[$ProfileName]"
        "aws_access_key_id=$($creds['aws_access_key_id'])"
        "aws_secret_access_key=$($creds['aws_secret_access_key'])"
        "aws_session_token=$($creds['aws_session_token'])"
    )

    # Trailing whitespace fuera, para que el archivo no acumule líneas vacías
    $output = (@($existing) + @('') + $block) -join "`n"
    $output = $output.Trim() + "`n"

    # utf8 sin BOM: el SDK de AWS no interpreta el BOM y fallaría al leer el
    # primer perfil del archivo.
    [System.IO.File]::WriteAllText($credsIn, $output, (New-Object System.Text.UTF8Encoding($false)))

    # La región se fija en config, que es donde la busca el CLI
    if (-not (Test-Path $confIn) -or -not (Select-String -Path $confIn -Pattern "^\[profile $ProfileName\]" -Quiet)) {
        Add-Content -Path $confIn -Value "`n[profile $ProfileName]`nregion=$Region`noutput=json" -Encoding utf8
    }

    Write-Host ''
    Write-Host "Perfil '$ProfileName' actualizado en $credsIn" -ForegroundColor Green

    # ── Verificación ─────────────────────────────────────────────────────────
    if (Get-Command aws -ErrorAction SilentlyContinue) {
        Write-Host 'Verificando la sesión...' -ForegroundColor Cyan
        $identity = & aws sts get-caller-identity --profile $ProfileName --output json 2>&1

        if ($LASTEXITCODE -eq 0) {
            $parsed = $identity | ConvertFrom-Json
            Write-Host "  Cuenta : $($parsed.Account)" -ForegroundColor Green
            Write-Host "  Rol    : $($parsed.Arn)"     -ForegroundColor Green
            Write-Host ''
            Write-Host "Usar con: aws --profile $ProfileName <comando>" -ForegroundColor DarkGray
        }
        else {
            Write-Warning "La verificación falló. ¿El laboratorio sigue iniciado?"
            Write-Host $identity -ForegroundColor DarkGray
        }
    }
    else {
        Write-Warning 'El AWS CLI no está instalado; no se pudo verificar la sesión.'
        Write-Host 'Instalación: https://aws.amazon.com/cli/' -ForegroundColor DarkGray
    }
}
