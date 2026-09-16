#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AndesStay — estado de la sesión del AWS Learner Lab
#
# Responde a la pregunta que aparece cada vez que un despliegue falla a medio
# camino: ¿siguen vivas las credenciales o caducaron?
#
# Uso:
#   bash check-aws-session.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

PROFILE="${AWS_PROFILE_NAME:-andesstay}"

if ! command -v aws > /dev/null 2>&1 && [[ -x "/c/Program Files/Amazon/AWSCLIV2/aws.exe" ]]; then
    export PATH="$PATH:/c/Program Files/Amazon/AWSCLIV2"
fi

command -v aws > /dev/null 2>&1 || {
    echo "[error] El AWS CLI no está instalado." >&2
    exit 1
}

echo "Perfil: $PROFILE"
echo ""

OUTPUT=$(aws sts get-caller-identity --profile "$PROFILE" --output json 2>&1)
STATUS=$?

if [[ $STATUS -ne 0 ]]; then
    echo "SESIÓN NO VÁLIDA"
    echo ""

    case "$OUTPUT" in
        *ExpiredToken*|*ExpiredTokenException*)
            echo "Motivo: las credenciales caducaron (duran unas 4 horas)."
            ;;
        *InvalidClientTokenId*)
            echo "Motivo: el access key no es válido. Suele ser una copia incompleta,"
            echo "        o que el laboratorio se reinició y emitió credenciales nuevas."
            ;;
        *"could not be found"*|*"Unable to locate credentials"*)
            echo "Motivo: el perfil '$PROFILE' no existe en ~/.aws/credentials."
            ;;
        *)
            echo "Detalle:"
            echo "$OUTPUT" | sed 's/^/  /'
            ;;
    esac

    echo ""
    echo "Solución: abrir el Learner Lab, copiar el bloque de AWS Details -> AWS CLI y ejecutar"
    echo "  Windows : powershell -File scripts/aws-session.ps1"
    echo "  Git Bash: bash scripts/aws-session.sh"
    exit 1
fi

ACCOUNT=$(echo "$OUTPUT" | sed -n 's/.*"Account"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
ARN=$(echo "$OUTPUT" | sed -n 's/.*"Arn"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

echo "SESIÓN ACTIVA"
echo "  Cuenta : $ACCOUNT"
echo "  Rol    : $ARN"
echo ""

# STS no informa cuándo caduca la sesión, así que se estima por la antigüedad
# del archivo de credenciales: el laboratorio las emite con unas 4 horas de vida.
CREDS="$HOME/.aws/credentials"
if [[ -f "$CREDS" ]]; then
    NOW=$(date +%s)
    MTIME=$(stat -c %Y "$CREDS" 2>/dev/null || stat -f %m "$CREDS" 2>/dev/null || echo "$NOW")
    ELAPSED=$(( (NOW - MTIME) / 60 ))
    REMAINING=$(( 240 - ELAPSED ))

    echo "  Cargadas hace : ${ELAPSED} min"
    if (( REMAINING > 0 )); then
        echo "  Restante aprox: ${REMAINING} min"
        (( REMAINING < 30 )) && echo "  [aviso] Queda poco: conviene recargar antes de un despliegue largo."
    else
        echo "  [aviso] Pasaron más de 4 horas desde la carga; la sesión puede caer en cualquier momento."
    fi
fi
