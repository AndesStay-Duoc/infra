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
    powershell -File infra\deploy\scripts\aws-session.ps1
    Lee infra\deploy\credenciales-aws.txt si existe; si no, pide pegar el bloque.

.EXAMPLE
    .\aws-session.ps1 -Archivo C:\ruta\credenciales.txt

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

    # Archivo con el bloque del laboratorio. Por defecto, deploy\credenciales-aws.txt
    [string] $Archivo = '',

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
    # Sin entrada por tubería: primero el archivo indicado o la plantilla completada
    if ($collected.Count -eq 0) {
        if (-not $Archivo) {
            $Archivo = Join-Path (Split-Path $PSScriptRoot -Parent) 'credenciales-aws.txt'
        }
        if (Test-Path $Archivo) {
            Write-Host "Leyendo $Archivo" -ForegroundColor DarkGray
            Get-Content $Archivo | ForEach-Object { $collected.Add($_) }
        }
    }

    # Y si tampoco hay archivo, se pide pegar el bloque de forma interactiva
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

    # La plantilla trae valores de ejemplo: si siguen ahí, no se completó el archivo
    if ($creds['aws_access_key_id'] -like '*XXXX*' -or $creds['aws_secret_access_key'] -like 'REEMPLAZAR*') {
        throw 'credenciales-aws.txt todavía tiene los valores de la plantilla. Pegar ahí el bloque de AWS Details -> AWS CLI.'
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
        # AppendAllText sin BOM: Add-Content -Encoding utf8 de Windows PowerShell 5.1
        # antepone un BOM al crear el archivo, y el CLI ya no reconoce la sección.
        [System.IO.File]::AppendAllText($confIn, "`n[profile $ProfileName]`nregion=$Region`noutput=json`n",
            (New-Object System.Text.UTF8Encoding($false)))
    }

    Write-Host ''
    Write-Host "Perfil '$ProfileName' actualizado en $credsIn" -ForegroundColor Green

    # ── Verificación ─────────────────────────────────────────────────────────
    # Una terminal abierta antes de instalar el CLI no tiene su ruta en el PATH
    $awsDefault = 'C:\Program Files\Amazon\AWSCLIV2'
    if (-not (Get-Command aws -ErrorAction SilentlyContinue) -and (Test-Path "$awsDefault\aws.exe")) {
        $env:Path = "$env:Path;$awsDefault"
    }

    if (Get-Command aws -ErrorAction SilentlyContinue) {
        Write-Host 'Verificando la sesión...' -ForegroundColor Cyan
        # Con ErrorActionPreference en Stop, el 2>&1 convierte el stderr de aws.exe
        # en un error terminante y el script abortaría justo cuando las
        # credenciales son inválidas, que es el caso que interesa informar.
        $previo = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $identity = & aws sts get-caller-identity --profile $ProfileName --output json 2>&1
        $codigo = $LASTEXITCODE
        $ErrorActionPreference = $previo

        if ($codigo -eq 0) {
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
