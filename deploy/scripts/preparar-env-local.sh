#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AndesStay — prepara los .env del arranque LOCAL con Docker
#
# Genera infra/.env e infra/apps/.env a partir de AndesStay/secrets/, que es lo
# que leen los tres compose del arranque local:
#
#   infra/mq/compose.yml      --env-file infra/.env
#   infra/kafka/compose.yml   (no necesita ninguno)
#   infra/apps/compose.yml    --env-file infra/apps/.env
#
# ── POR QUÉ EXISTE ──────────────────────────────────────────────────────────
#
# crear-infra.sh construye secrets/andesstay.env para el despliegue en AWS, pero
# ningún script preparaba los .env del arranque local: había que escribirlos a
# mano leyendo las plantillas y copiando valores de dos archivos distintos. Es
# el punto donde más fácil es quedarse atascado al montar el proyecto en un
# equipo nuevo, y el error no se ve al generar el archivo sino mucho después,
# cuando un contenedor arranca con una variable vacía.
#
# El mapeo no es evidente y es la otra razón de que esto no se haga a ojo: las
# variables de RabbitMQ salen de secrets/andesstay-mq.env y las de MySQL de
# secrets/andesstay.env, y apps/compose.yml necesita de los dos archivos.
#
# Uso, desde cualquier sitio:
#   bash infra/deploy/scripts/preparar-env-local.sh
#
# Los archivos se sobrescriben en cada ejecución: son derivados de secrets/, no
# una fuente de verdad. Lo que se edita a mano es secrets/.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

ENV_MQ="$PROJECT_ROOT/secrets/andesstay-mq.env"
ENV_APP="$PROJECT_ROOT/secrets/andesstay.env"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m[ok]\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

log "Comprobando la carpeta de secretos"

for f in "$ENV_MQ" "$ENV_APP"; do
    [[ -f "$f" ]] || {
        printf '  \033[31m[error]\033[0m No está %s\n' "$f" >&2
        printf '\n  La carpeta secrets/ NO se versiona: vive en AndesStay/secrets y el equipo la\n' >&2
        printf '  comparte aparte. Clonar los repositorios no la trae. Cópiala desde un equipo\n' >&2
        printf '  donde el proyecto ya funcione antes de seguir.\n\n' >&2
        exit 1
    }
done
ok "secrets/andesstay-mq.env y secrets/andesstay.env"

# Lee una variable de un archivo de entorno. Solo la primera coincidencia: si alguien duplicó una
# clave, manda la de arriba, que es lo mismo que haría docker compose.
valor() { grep -m1 "^$1=" "$2" | cut -d= -f2-; }

RABBITMQ_USER=$(valor RABBITMQ_USER "$ENV_MQ")
RABBITMQ_PASSWORD=$(valor RABBITMQ_PASSWORD "$ENV_MQ")
RABBITMQ_ERLANG_COOKIE=$(valor RABBITMQ_ERLANG_COOKIE "$ENV_MQ")
NOTIFY_BACKOFF_LADDER=$(valor NOTIFY_BACKOFF_LADDER "$ENV_MQ")
AZURE_TENANT_ID=$(valor AZURE_TENANT_ID "$ENV_MQ")
AZURE_CLIENT_ID=$(valor AZURE_CLIENT_ID "$ENV_MQ")

MYSQL_ROOT_PASSWORD=$(valor MYSQL_ROOT_PASSWORD "$ENV_APP")
MYSQL_APP_PASSWORD=$(valor MYSQL_APP_PASSWORD "$ENV_APP")
MYSQL_APP_USER=$(valor MYSQL_APP_USER "$ENV_APP")
MYSQL_DATABASE=$(valor MYSQL_DATABASE "$ENV_APP")

log "Comprobando que ningún valor salga vacío"

# Un .env con una clave vacía no falla al generarse: falla mucho después, cuando el broker responde
# ACCESS_REFUSED o MySQL rechaza al usuario de la aplicación. Se corta aquí.
for nombre in RABBITMQ_USER RABBITMQ_PASSWORD RABBITMQ_ERLANG_COOKIE \
              AZURE_TENANT_ID AZURE_CLIENT_ID \
              MYSQL_ROOT_PASSWORD MYSQL_APP_PASSWORD MYSQL_APP_USER MYSQL_DATABASE; do
    [[ -n "${!nombre}" ]] || die "$nombre está vacía en secrets/. Complétala y vuelve a ejecutar."
done
ok "las nueve variables obligatorias tienen valor"

log "Escribiendo infra/.env"

cat > "$PROJECT_ROOT/infra/.env" <<EOF
# Generado por deploy/scripts/preparar-env-local.sh desde ../secrets/.
# NO se versiona y NO se edita a mano: lo que se edita es secrets/.
RABBITMQ_USER=$RABBITMQ_USER
RABBITMQ_PASSWORD=$RABBITMQ_PASSWORD
RABBITMQ_ERLANG_COOKIE=$RABBITMQ_ERLANG_COOKIE
NOTIFY_BACKOFF_LADDER=${NOTIFY_BACKOFF_LADDER:-1000,2000,4000}
AZURE_TENANT_ID=$AZURE_TENANT_ID
AZURE_CLIENT_ID=$AZURE_CLIENT_ID
# MAIL_* se deja sin definir a propósito: mq/compose.yml usa entonces mailpit:1025
# sin autenticación, que es lo correcto en local. Con MAIL_PORT=587 y MAIL_HOST
# vacío, notify apunta a un puerto cerrado y todos los correos acaban en la DLQ.
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
MYSQL_APP_PASSWORD=$MYSQL_APP_PASSWORD
MYSQL_APP_USER=$MYSQL_APP_USER
MYSQL_DATABASE=$MYSQL_DATABASE
EOF
ok "$(grep -c '^[A-Z]' "$PROJECT_ROOT/infra/.env") variables"

log "Escribiendo infra/apps/.env"

cat > "$PROJECT_ROOT/infra/apps/.env" <<EOF
# Generado por deploy/scripts/preparar-env-local.sh desde ../../secrets/.
# NO se versiona y NO se edita a mano: lo que se edita es secrets/.
AZURE_TENANT_ID=$AZURE_TENANT_ID
AZURE_CLIENT_ID=$AZURE_CLIENT_ID
CORS_ALLOWED_ORIGINS=http://localhost:4200
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
MYSQL_APP_PASSWORD=$MYSQL_APP_PASSWORD
MYSQL_APP_USER=$MYSQL_APP_USER
MYSQL_DATABASE=$MYSQL_DATABASE
RABBITMQ_USER=$RABBITMQ_USER
RABBITMQ_PASSWORD=$RABBITMQ_PASSWORD
ANDESSTAY_EVENTS_KAFKA_ENABLED=true
EOF
ok "$(grep -c '^[A-Z]' "$PROJECT_ROOT/infra/apps/.env") variables"

# 600 por el mismo motivo que crear-infra.sh lo hace con el .env de la instancia: llevan
# contraseñas. En Windows el modo no siempre se aplica, y no es motivo para fallar.
chmod 600 "$PROJECT_ROOT/infra/.env" "$PROJECT_ROOT/infra/apps/.env" 2>/dev/null || true

cat <<EOF

  Listo. El arranque local, en este orden --apps declara las redes de mq y kafka
  como externas y no arranca si no existen:

    docker compose --env-file infra/.env -f infra/mq/compose.yml up -d --build
    docker compose -f infra/kafka/compose.yml up -d
    docker compose --env-file infra/apps/.env -f infra/apps/compose.yml up -d --build

EOF
