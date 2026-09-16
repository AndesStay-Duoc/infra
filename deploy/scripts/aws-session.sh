#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AndesStay — carga las credenciales del AWS Learner Lab (WSL, macOS, Linux)
#
# Equivalente de aws-session.ps1 para entornos POSIX. Lee por la entrada
# estándar el bloque de "AWS Details -> AWS CLI" y escribe el perfil en
# ~/.aws/credentials.
#
# Estas credenciales caducan a las ~4 horas y NO se comparten con el equipo:
# cada integrante abre su propio laboratorio y ejecuta este script.
#
# Uso:
#   bash aws-session.sh              # pega el bloque y termina con Ctrl+D
#   pbpaste | bash aws-session.sh    # macOS
#   cat credenciales.txt | bash aws-session.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PROFILE="${AWS_PROFILE_NAME:-andesstay}"
REGION="${AWS_REGION:-us-east-1}"
AWS_DIR="$HOME/.aws"
CREDS="$AWS_DIR/credentials"
CONFIG="$AWS_DIR/config"

if [[ -t 0 ]]; then
    echo ""
    echo "Pegar el bloque de AWS Details -> AWS CLI y terminar con Ctrl+D:"
    echo ""
fi

INPUT="$(cat)"

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

if command -v aws > /dev/null 2>&1; then
    echo "Verificando la sesión..."
    if aws sts get-caller-identity --profile "$PROFILE" --output text \
        --query 'join(`  `, [Account, Arn])' 2>/dev/null; then
        echo ""
        echo "Usar con: aws --profile $PROFILE <comando>"
    else
        echo "[aviso] La verificación falló. ¿El laboratorio sigue iniciado?" >&2
    fi
else
    echo "[aviso] El AWS CLI no está instalado; no se pudo verificar la sesión." >&2
fi
