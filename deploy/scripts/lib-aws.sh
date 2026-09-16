#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AndesStay — funciones compartidas por los scripts de infraestructura AWS
#
# No se ejecuta directamente: lo cargan crear-infra.sh y destruir-infra.sh con
#   source "$(dirname "$0")/lib-aws.sh"
#
# Resuelve tres cosas que cambian de un equipo a otro:
#   · dónde está el AWS CLI (instalado, o vía Docker si no lo está),
#   · dónde están los repositorios hermanos y la carpeta de secretos,
#   · qué recursos se crearon en una ejecución anterior (archivo de estado).
# ─────────────────────────────────────────────────────────────────────────────

# ── Rutas ────────────────────────────────────────────────────────────────────
# scripts -> deploy -> infra -> carpeta que contiene los ocho repositorios
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$LIB_DIR/.." && pwd)"
INFRA_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$INFRA_DIR/.." && pwd)"

# Registro de los identificadores creados. Está en .gitignore: cada persona y
# cada cuenta AWS tiene el suyo.
STATE_FILE="${STATE_FILE:-$DEPLOY_DIR/.estado-aws.env}"

# Variables compartidas del despliegue. Por defecto en la carpeta secrets,
# hermana de los repositorios; si no existe, se crea en la primera ejecución.
ENV_FILE="${ENV_FILE:-$PROJECT_ROOT/secrets/andesstay.env}"

AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-andesstay}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Nombre común de todos los recursos, para poder encontrarlos por etiqueta
NAME_TAG="${NAME_TAG:-andesstay-app}"

# ── Salida ───────────────────────────────────────────────────────────────────
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m[ok]\033[0m %s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '  \033[1;33m[aviso]\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# ── AWS CLI ──────────────────────────────────────────────────────────────────
# Un Git Bash abierto antes de instalar el CLI no tiene la ruta en el PATH.
if ! command -v aws > /dev/null 2>&1 && [[ -x "/c/Program Files/Amazon/AWSCLIV2/aws.exe" ]]; then
    export PATH="$PATH:/c/Program Files/Amazon/AWSCLIV2"
fi

if command -v aws > /dev/null 2>&1; then
    AWS_MODE="nativo"
elif command -v docker > /dev/null 2>&1 && docker info > /dev/null 2>&1; then
    AWS_MODE="docker"
else
    AWS_MODE="ninguno"
fi

# Invoca el CLI con el perfil y la región del proyecto.
#
# MSYS_NO_PATHCONV=1 evita que Git Bash en Windows reescriba como ruta de disco
# los argumentos que empiezan por "/", como el nombre del parámetro SSM de la
# AMI de Ubuntu. Solo afecta a esta llamada, no al resto del script.
#
# El tr quita los \r que aws.exe agrega en Windows y que rompen comparaciones.
awsx() {
    case "$AWS_MODE" in
        nativo)
            MSYS_NO_PATHCONV=1 aws --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION" "$@" | tr -d '\r'
            return "${PIPESTATUS[0]}"
            ;;
        docker)
            MSYS_NO_PATHCONV=1 docker run --rm -i \
                -v "$HOME/.aws:/root/.aws:ro" \
                public.ecr.aws/aws-cli/aws-cli:latest \
                --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION" "$@" | tr -d '\r'
            return "${PIPESTATUS[0]}"
            ;;
        *)
            die "No se encontró el AWS CLI. En Windows: powershell -ExecutionPolicy Bypass -File infra/deploy/scripts/instalar-aws-cli.ps1"
            ;;
    esac
}

# Devuelve una consulta en texto plano, y cadena vacía en vez de "None".
awsq() {
    local out
    out=$(awsx "$@" --output text 2>/dev/null) || true
    [[ "$out" == "None" ]] && out=""
    printf '%s' "$out"
}

require_session() {
    log "Comprobando la sesión AWS (perfil $AWS_PROFILE_NAME, CLI $AWS_MODE)"
    local salida
    if ! salida=$(awsx sts get-caller-identity --query 'Arn' --output text 2>&1); then
        case "$salida" in
            *ExpiredToken*)
                die "Las credenciales del laboratorio caducaron. Actualizar credenciales-aws.txt y ejecutar: bash scripts/aws-session.sh" ;;
            *"could not be found"*|*"Unable to locate credentials"*)
                die "No existe el perfil $AWS_PROFILE_NAME. Completar credenciales-aws.txt y ejecutar: bash scripts/aws-session.sh" ;;
            *)
                die "La sesión AWS no es válida: $salida" ;;
        esac
    fi
    ok "$salida"
}

# ── Estado ───────────────────────────────────────────────────────────────────
load_state() {
    # shellcheck disable=SC1090
    [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
    return 0
}

# Guarda o reemplaza CLAVE=valor en el archivo de estado
save_state() {
    local key="$1" value="$2"
    touch "$STATE_FILE"
    if grep -q "^${key}=" "$STATE_FILE"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$STATE_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$STATE_FILE"
    fi
    printf -v "$key" '%s' "$value"
}

clear_state_key() {
    [[ -f "$STATE_FILE" ]] && sed -i "/^$1=/d" "$STATE_FILE"
    unset "$1"
}

# ── Archivo de variables del despliegue ──────────────────────────────────────
# Reemplaza CLAVE=valor en el .env. Usa | como delimitador de sed, así que el
# valor no puede contener ese carácter; los secretos se generan en hexadecimal.
set_env_var() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}

get_env_var() {
    grep "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r'
}

# ── Utilidades ───────────────────────────────────────────────────────────────
my_public_ip() {
    curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '\r\n'
}

ssh_opts() {
    printf '%s\n' -i "$1" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$HOME/.ssh/known_hosts_andesstay" \
        -o ConnectTimeout=10 \
        -o ServerAliveInterval=30 \
        -o LogLevel=ERROR
}
