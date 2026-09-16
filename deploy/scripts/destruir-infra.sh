#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AndesStay — detiene o elimina la infraestructura creada en AWS
#
# Dos modos, con consecuencias muy distintas:
#
#   --detener   Detiene la instancia. Conserva el disco con la base de datos, la
#               Elastic IP y los dos HTTP API, así que las URL y los Redirect URI
#               de Entra ID siguen valiendo. Se retoma con crear-infra.sh.
#               Es lo indicado entre sesiones de trabajo.
#
#   (sin opción) ELIMINA todo: los dos HTTP API, la Elastic IP, la instancia con
#               su disco, el Security Group y el par de claves. Es irreversible:
#               la base de datos se pierde, y al volver a crear, el API web tiene
#               otra dirección y hay que registrar Redirect URI nuevos en Entra ID.
#
# Uso, desde Git Bash en la carpeta infra/deploy:
#   bash scripts/destruir-infra.sh --detener
#   bash scripts/destruir-infra.sh            # pide escribir "destruir"
#   bash scripts/destruir-infra.sh --si       # sin confirmación, para automatizar
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# shellcheck source=lib-aws.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-aws.sh"

MODO="destruir"
CONFIRMADO=0

while (( $# > 0 )); do
    case "$1" in
        --detener) MODO="detener"; shift ;;
        --si)      CONFIRMADO=1; shift ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *)         die "Opción desconocida: $1 (ver --help)" ;;
    esac
done

require_session
load_state

ACCOUNT_ID=$(awsq sts get-caller-identity --query Account)
if [[ -n "${ACCOUNT_ID_ESTADO:-}" && "$ACCOUNT_ID_ESTADO" != "$ACCOUNT_ID" ]]; then
    die "El archivo de estado es de la cuenta $ACCOUNT_ID_ESTADO y la sesión es de $ACCOUNT_ID.
Se detiene para no operar sobre una cuenta equivocada."
fi

# ── Localizar recursos: estado primero, nombre o etiqueta después ────────────
log "Buscando los recursos de AndesStay en la cuenta $ACCOUNT_ID"

INSTANCE_ID=${INSTANCE_ID:-}
if [[ -n "$INSTANCE_ID" ]]; then
    estado=$(awsq ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name')
    [[ -z "$estado" || "$estado" == "terminated" ]] && INSTANCE_ID=""
fi
INSTANCE_ID=${INSTANCE_ID:-$(awsq ec2 describe-instances \
    --filters "Name=tag:Name,Values=$NAME_TAG" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId')}

ALLOCATION_ID=${ALLOCATION_ID:-$(awsq ec2 describe-addresses --filters "Name=tag:Name,Values=$NAME_TAG" --query 'Addresses[0].AllocationId')}
API_ID=$(awsq apigatewayv2 get-apis --query "Items[?Name=='andesstay-api'].ApiId | [0]")
WEB_API_ID=$(awsq apigatewayv2 get-apis --query "Items[?Name=='andesstay-web'].ApiId | [0]")
VPC_ID=${VPC_ID:-$(awsq ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId')}
SG_ID=${SG_ID:-$(awsq ec2 describe-security-groups \
    --filters Name=group-name,Values=andesstay-app "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId')}
if [[ -n "$INSTANCE_ID" ]]; then
    KEY_NAME=$(awsq ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].KeyName')
fi
KEY_NAME=${KEY_NAME:-}
KEY_FILE=${KEY_FILE:-${KEY_NAME:+$HOME/.ssh/$KEY_NAME.pem}}

mostrar() { printf '  %-16s %s\n' "$1" "${2:-(no existe)}"; }
mostrar "Instancia"      "$INSTANCE_ID"
mostrar "Elastic IP"     "$ALLOCATION_ID"
mostrar "API datos"      "$API_ID"
mostrar "API web"        "$WEB_API_ID"
mostrar "Security Group" "$SG_ID"
mostrar "Par de claves"  "$KEY_NAME"

# ═════════════════════════════════════════════════════════════════════════════
# Modo detener
# ═════════════════════════════════════════════════════════════════════════════
if [[ "$MODO" == "detener" ]]; then
    [[ -n "$INSTANCE_ID" ]] || die "No hay instancia que detener"

    log "Deteniendo $INSTANCE_ID"
    awsx ec2 stop-instances --instance-ids "$INSTANCE_ID" > /dev/null
    awsx ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
    ok "detenida"

    cat <<TEXTO

  Se conservan el disco con la base de datos, la Elastic IP y los dos HTTP API.
  Las URL y los Redirect URI de Entra ID siguen siendo válidos.

  Para retomar:
    bash scripts/crear-infra.sh --sin-build

  Nota: AWS cobra las Elastic IP aunque la instancia esté detenida. Si la pausa
  va a ser larga, conviene destruir todo en lugar de solo detener.

TEXTO
    exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# Modo destruir
# ═════════════════════════════════════════════════════════════════════════════
if (( ! CONFIRMADO )); then
    cat <<AVISO

  $(printf '\033[1;31m')Esto ELIMINA los recursos listados y no se puede deshacer.$(printf '\033[0m')

    · La base de datos MySQL se pierde junto con el disco de la instancia.
    · Al volver a crear, el API web tendrá otra dirección: habrá que registrar
      Redirect URI nuevos en Entra ID.

  Si solo se quiere pausar el trabajo:  bash scripts/destruir-infra.sh --detener

AVISO
    read -r -p "  Escribir 'destruir' para continuar: " respuesta
    [[ "$respuesta" == "destruir" ]] || { echo "  Cancelado."; exit 0; }
fi

# Primero los API: dejan de enviar tráfico a la instancia
for pair in "andesstay-api:$API_ID" "andesstay-web:$WEB_API_ID"; do
    nombre="${pair%%:*}"; id="${pair#*:}"
    if [[ -n "$id" ]]; then
        log "Eliminando el HTTP API $nombre"
        awsx apigatewayv2 delete-api --api-id "$id" > /dev/null
        ok "$id eliminado"
    fi
done

if [[ -n "$ALLOCATION_ID" ]]; then
    log "Liberando la Elastic IP"
    asociacion=$(awsq ec2 describe-addresses --allocation-ids "$ALLOCATION_ID" --query 'Addresses[0].AssociationId')
    [[ -n "$asociacion" ]] && awsx ec2 disassociate-address --association-id "$asociacion" > /dev/null
    awsx ec2 release-address --allocation-id "$ALLOCATION_ID" > /dev/null
    ok "$ALLOCATION_ID liberada"
fi

if [[ -n "$INSTANCE_ID" ]]; then
    log "Terminando la instancia (el disco se elimina con ella)"
    awsx ec2 terminate-instances --instance-ids "$INSTANCE_ID" > /dev/null
    info "esperando el estado terminated..."
    awsx ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
    ok "$INSTANCE_ID terminada"
fi

if [[ -n "$SG_ID" ]]; then
    log "Eliminando el Security Group"
    # La interfaz de red de la instancia tarda unos segundos en soltarse
    eliminado=0
    for _ in $(seq 1 12); do
        if awsx ec2 delete-security-group --group-id "$SG_ID" > /dev/null 2>&1; then
            eliminado=1; break
        fi
        sleep 10
    done
    (( eliminado )) && ok "$SG_ID eliminado" || warn "no se pudo eliminar $SG_ID; reintentar en un minuto"
fi

if [[ -n "$KEY_NAME" ]]; then
    log "Eliminando el par de claves"
    awsx ec2 delete-key-pair --key-name "$KEY_NAME" > /dev/null
    ok "$KEY_NAME eliminado en AWS"
    if [[ -n "$KEY_FILE" && -f "$KEY_FILE" ]]; then
        rm -f "$KEY_FILE"
        ok "$KEY_FILE eliminado (ya no abre ninguna instancia)"
    fi
fi

# ── Limpieza local ───────────────────────────────────────────────────────────
rm -f "$STATE_FILE"
if [[ -f "$ENV_FILE" ]]; then
    # Los secretos se conservan: son los de la base de datos y del gateway, y se
    # reutilizan en el próximo despliegue. Se vacían solo los datos que dejaron
    # de ser válidos.
    for k in PUBLIC_WEB_ORIGIN PUBLIC_API_ORIGIN EC2_PUBLIC_IP EC2_SSH_KEY; do
        set_env_var "$k" ""
    done
fi

log "Infraestructura eliminada"
cat <<TEXTO

  Pendiente manual en Entra ID: quitar de la App Registration los Redirect URI
  del API web eliminado, ${WEB_ORIGIN:-https://<web-api-id>.execute-api.us-east-1.amazonaws.com}.
  No rompen nada, pero apuntan a una dirección que ya no existe.

TEXTO
