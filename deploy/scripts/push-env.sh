#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AndesStay — lleva el .env compartido a la instancia EC2
#
# Copia AndesStay/secrets/andesstay.env a /opt/andesstay/.env por scp, le aplica
# permisos 600 y, opcionalmente, reinicia el stack.
#
# Es el ÚNICO camino previsto para actualizar las variables en el servidor. La
# copia de OneDrive es la fuente de verdad: editar /opt/andesstay/.env a mano
# hace que el siguiente push-env.sh lo sobrescriba sin aviso.
#
# Uso:
#   bash infra/deploy/scripts/push-env.sh              # copia y reinicia
#   bash infra/deploy/scripts/push-env.sh --no-restart # solo copia
#
# Los datos de conexión salen del propio archivo: EC2_PUBLIC_IP, EC2_SSH_USER y
# EC2_SSH_KEY.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# scripts -> deploy -> infra -> AndesStay
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ENV_FILE="${ENV_FILE:-$PROJECT_ROOT/secrets/andesstay.env}"

REMOTE_DIR="${REMOTE_DIR:-/opt/andesstay}"
RESTART=1

[[ "${1:-}" == "--no-restart" ]] && RESTART=0

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

# ── 1. Localizar y validar el archivo ────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
    die "No existe $ENV_FILE

Crearlo a partir de la plantilla:
  cp $PROJECT_ROOT/secrets/andesstay.env.example $ENV_FILE

y completar los valores. Ver $PROJECT_ROOT/secrets/README.md"
fi

log "Leyendo $ENV_FILE"

# set -a exporta todo lo que se defina a continuación, para poder leer las
# variables sin parsear el archivo a mano.
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# ── 2. Comprobar que no quedaron campos sin completar ────────────────────────
REQUIRED=(
    MYSQL_ROOT_PASSWORD
    MYSQL_APP_PASSWORD
    MYSQL_APP_USER
    MYSQL_DATABASE
    GATEWAY_SECRET
    AZURE_TENANT_ID
    AZURE_CLIENT_ID
    EC2_PUBLIC_IP
    EC2_SSH_KEY
)

MISSING=()
for var in "${REQUIRED[@]}"; do
    [[ -z "${!var:-}" ]] && MISSING+=("$var")
done

if (( ${#MISSING[@]} > 0 )); then
    die "Faltan valores en $ENV_FILE: ${MISSING[*]}"
fi

# Estas dos solo se conocen después de crear los HTTP API, así que su ausencia
# es un aviso y no un error: el stack levanta igual y se vuelve a ejecutar el
# script cuando existan.
for var in PUBLIC_WEB_ORIGIN PUBLIC_API_ORIGIN; do
    if [[ -z "${!var:-}" ]]; then
        printf '\033[1;33m[aviso] %s está vacío. El login y el CORS no funcionarán hasta completarlo.\033[0m\n' "$var"
    elif [[ "${!var}" == */ ]]; then
        die "$var termina en barra. Entra ID y el CORS comparan la cadena exacta: quitar la barra final."
    fi
done

SSH_USER="${EC2_SSH_USER:-ubuntu}"
SSH_KEY="$EC2_SSH_KEY"

[[ -f "$SSH_KEY" ]] || die "No existe la clave SSH: $SSH_KEY"

# OpenSSH rechaza una clave que el resto del sistema pueda leer. En Windows los
# permisos POSIX no aplican, así que el chmod se intenta sin dar error si falla.
chmod 600 "$SSH_KEY" 2>/dev/null || true

# Mismo archivo de huellas que crear-infra.sh: al recrear la instancia, la IP
# puede repetirse con otra huella y el known_hosts general bloquearía la conexión.
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10
          -o UserKnownHostsFile="$HOME/.ssh/known_hosts_andesstay" -o LogLevel=ERROR)
TARGET="$SSH_USER@$EC2_PUBLIC_IP"

# ── 3. Copiar ────────────────────────────────────────────────────────────────
log "Copiando a $TARGET:$REMOTE_DIR/.env"

# Se sube primero al home del usuario: /opt/andesstay puede no ser escribible
# por scp según cómo haya quedado el propietario.
scp "${SSH_OPTS[@]}" "$ENV_FILE" "$TARGET:/tmp/andesstay.env" \
    || die "Falló el scp. Revisar EC2_PUBLIC_IP, el Security Group (puerto 22) y que el laboratorio esté iniciado."

log "Instalando el archivo con permisos restringidos"
ssh "${SSH_OPTS[@]}" "$TARGET" bash -s <<REMOTE
set -euo pipefail
sudo mkdir -p "$REMOTE_DIR"
sudo mv /tmp/andesstay.env "$REMOTE_DIR/.env"
sudo chown "$SSH_USER:$SSH_USER" "$REMOTE_DIR/.env"
sudo chmod 600 "$REMOTE_DIR/.env"
echo "  permisos: \$(stat -c '%a %U' "$REMOTE_DIR/.env")"
REMOTE

# ── 4. Reiniciar ─────────────────────────────────────────────────────────────
if (( RESTART )); then
    log "Aplicando la configuración nueva"

    # "up -d" recrea solo los contenedores cuyas variables cambiaron; los demás
    # siguen corriendo. MySQL conserva su volumen.
    ssh "${SSH_OPTS[@]}" "$TARGET" bash -s <<REMOTE
set -euo pipefail
cd "$REMOTE_DIR"
docker compose --env-file .env -f infra/deploy/compose.yml up -d
echo ""
docker compose --env-file .env -f infra/deploy/compose.yml ps
REMOTE
else
    echo ""
    echo "Archivo copiado sin reiniciar. Para aplicarlo:"
    echo "  ssh -i $SSH_KEY $TARGET"
    echo "  cd $REMOTE_DIR && docker compose --env-file .env -f infra/deploy/compose.yml up -d"
fi

log "Listo"
