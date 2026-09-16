#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AndesStay — carga las credenciales del AWS Learner Lab en el perfil "andesstay"
#
# Lee el bloque de "AWS Details -> AWS CLI" y escribe el perfil en
# ~/.aws/credentials. Funciona en Git Bash (Windows), WSL, macOS y Linux.
#
# Orden en que busca las credenciales:
#   1. el archivo pasado como argumento,
#   2. infra/deploy/credenciales-aws.txt, creado desde credenciales-aws.example,
#   3. lo que se pegue por la entrada estándar.
#
# Estas credenciales caducan a las ~4 horas y NO se comparten con el equipo:
# cada integrante abre su propio laboratorio y carga las suyas.
#
# Uso:
#   bash scripts/aws-session.sh                       # lee credenciales-aws.txt
#   bash scripts/aws-session.sh otro-archivo.txt
#   pbpaste | bash scripts/aws-session.sh -           # desde la entrada estándar
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PROFILE="${AWS_PROFILE_NAME:-andesstay}"
REGION="${AWS_REGION:-us-east-1}"
AWS_DIR="$HOME/.aws"
CREDS="$AWS_DIR/credentials"
CONFIG="$AWS_DIR/config"

DEFAULT_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/credenciales-aws.txt"
TEMPLATE_FILE="${DEFAULT_FILE%.txt}.example"

# Protección: la plantilla SÍ está versionada y el repositorio es público. Pegar
# las credenciales en ella en vez de en la copia es un error fácil de cometer, y
# un commit posterior las publicaría. Se detiene antes de que llegue a pasar.
if [[ -f "$TEMPLATE_FILE" ]] && grep -qE '^aws_access_key_id=ASIA[A-Z0-9]{16}$' "$TEMPLATE_FILE" \
   && ! grep -q 'XXXX' "$TEMPLATE_FILE"; then
    echo "[error] credenciales-aws.example contiene credenciales reales." >&2
    echo "        Ese archivo se sube a git y el repositorio es público." >&2
    echo "        Moverlas a credenciales-aws.txt y restaurar la plantilla:" >&2
    echo "          cp credenciales-aws.example credenciales-aws.txt" >&2
    echo "          git checkout -- credenciales-aws.example" >&2
    exit 1
fi

# Prioridad: argumento, luego el archivo por defecto, y solo si no existe se lee
# la entrada estándar. "-" como argumento fuerza la entrada estándar, para usar
# el script con una tubería aunque exista credenciales-aws.txt.
if [[ "${1:-}" == "-" ]]; then
    INPUT="$(cat)"
elif [[ -n "${1:-}" ]]; then
    [[ -f "$1" ]] || { echo "[error] No existe $1" >&2; exit 1; }
    INPUT="$(cat "$1")"
    echo "Leyendo $1"
elif [[ -f "$DEFAULT_FILE" ]]; then
    INPUT="$(cat "$DEFAULT_FILE")"
    echo "Leyendo $DEFAULT_FILE"
else
    if [[ -t 0 ]]; then
        echo ""
        echo "No existe $DEFAULT_FILE."
        echo "Pegar el bloque de AWS Details -> AWS CLI y terminar con Ctrl+D:"
        echo ""
    fi
    INPUT="$(cat)"
fi

[[ -z "$INPUT" ]] && { echo "[error] No se recibió ninguna línea." >&2; exit 1; }

extract() {
    # Acepta "clave=valor" y "clave = valor"; se queda con la primera aparición.
    printf '%s\n' "$INPUT" \
        | sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p" \
        | head -n1
}

KEY_ID=$(extract aws_access_key_id)
SECRET=$(extract aws_secret_access_key)
TOKEN=$(extract aws_session_token)

# La plantilla trae valores de ejemplo: si siguen ahí, no se completó el archivo
if [[ "$KEY_ID" == *XXXX* || "$SECRET" == REEMPLAZAR* || "$TOKEN" == REEMPLAZAR* ]]; then
    echo "[error] credenciales-aws.txt todavía tiene los valores de la plantilla." >&2
    echo "        Pegar ahí el bloque de AWS Details -> AWS CLI del laboratorio." >&2
    exit 1
fi

MISSING=""
[[ -z "$KEY_ID" ]] && MISSING="$MISSING aws_access_key_id"
[[ -z "$SECRET" ]] && MISSING="$MISSING aws_secret_access_key"
[[ -z "$TOKEN"  ]] && MISSING="$MISSING aws_session_token"

if [[ -n "$MISSING" ]]; then
    echo "[error] Faltan claves en el bloque pegado:$MISSING" >&2
    exit 1
fi

# Las credenciales temporales de STS empiezan por ASIA
case "$KEY_ID" in
    ASIA*) ;;
    *) echo "[aviso] El access key no empieza por ASIA: puede no ser temporal." >&2 ;;
esac

mkdir -p "$AWS_DIR"
chmod 700 "$AWS_DIR"

# Se conservan los demás perfiles: solo se reemplaza el bloque de este.
if [[ -f "$CREDS" ]]; then
    awk -v prof="[$PROFILE]" '
        /^[[:space:]]*\[.*\][[:space:]]*$/ { skip = ($0 == prof) }
        !skip { print }
    ' "$CREDS" > "$CREDS.tmp"
else
    : > "$CREDS.tmp"
fi

{
    # Una línea en blanco solo si ya había contenido
    [[ -s "$CREDS.tmp" ]] && echo ""
    echo "[$PROFILE]"
    echo "aws_access_key_id=$KEY_ID"
    echo "aws_secret_access_key=$SECRET"
    echo "aws_session_token=$TOKEN"
} >> "$CREDS.tmp"

mv "$CREDS.tmp" "$CREDS"
chmod 600 "$CREDS"

# La región vive en config, que es donde la busca el CLI
if [[ ! -f "$CONFIG" ]] || ! grep -q "^\[profile $PROFILE\]" "$CONFIG"; then
    printf '\n[profile %s]\nregion=%s\noutput=json\n' "$PROFILE" "$REGION" >> "$CONFIG"
    chmod 600 "$CONFIG"
fi

echo ""
echo "Perfil '$PROFILE' actualizado en $CREDS"

# Un Git Bash abierto antes de instalar el CLI no tiene su ruta en el PATH
if ! command -v aws > /dev/null 2>&1 && [[ -x "/c/Program Files/Amazon/AWSCLIV2/aws.exe" ]]; then
    export PATH="$PATH:/c/Program Files/Amazon/AWSCLIV2"
fi

if command -v aws > /dev/null 2>&1; then
    echo "Verificando la sesión..."
    if aws sts get-caller-identity --profile "$PROFILE" --output text \
        --query '[Account, Arn]' 2>/dev/null; then
        echo ""
        echo "Usar con: aws --profile $PROFILE <comando>"
    else
        echo "[aviso] La verificación falló. ¿El laboratorio sigue iniciado?" >&2
    fi
else
    echo "[aviso] El AWS CLI no está instalado; no se pudo verificar la sesión." >&2
fi
