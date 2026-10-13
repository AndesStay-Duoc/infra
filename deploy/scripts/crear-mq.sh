#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AndesStay — instancia ec2-mq: clúster de RabbitMQ, notify y mq
#
# Crea la SEGUNDA instancia del despliegue. La primera, ec2-apps, la crea
# crear-infra.sh y lleva los microservicios de dominio, el BFF y la SPA; esta
# lleva la mensajería y lo que la consume.
#
# Uso:
#   bash scripts/crear-mq.sh              # crea o actualiza ec2-mq
#   bash scripts/crear-mq.sh --solo-infra # instancia y red, sin desplegar
#
# Al terminar imprime MQ_PRIVATE_IP, que es lo que hay que poner en el .env de
# ec2-apps para que reservations publique.
#
# ── POR QUÉ UNA SEGUNDA INSTANCIA ───────────────────────────────────────────
#
# El caso pide un clúster de dos nodos de RabbitMQ. Meterlo en ec2-apps, que ya
# corre siete contenedores con 3,2 GB de techos declarados sobre una t3.medium,
# dejaría a los dos sin margen. Separarlos además refleja la topología real: la
# mensajería es infraestructura, no aplicación.
#
# ── POR QUÉ t3.small Y NO t3.micro ──────────────────────────────────────────
#
# Cuatro contenedores no caben en 1 GB. Los dos nodos del broker y notify ya
# comprometen 920 MB con los techos originales, y ms-andesstay-mq es el cuarto.
# Bajarlos para que entrase deja al broker sin margen y la demostración
# corriendo apoyada en el swap, con el OOM killer como riesgo en el peor momento
# posible. Con 2 GB el reparto es 384+384+384+320 = 1.472 MB, dejando unos
# 320 MB al sistema y a Docker, más el swapfile de 2 GB de provision.sh.
#
# ── POR QUÉ NO LLEVA IP ELÁSTICA ────────────────────────────────────────────
#
# Nadie la alcanza desde internet. ec2-apps le habla por la IP PRIVADA, que es
# estable mientras la instancia exista, y el operador entra por SSH con la IP
# pública efímera, que el script vuelve a leer en cada ejecución. Una IP
# elástica no aportaría nada y el laboratorio las limita.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-aws.sh
source "$SCRIPT_DIR/lib-aws.sh"

SOLO_INFRA=0
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.small}"

while (( $# )); do
    case "$1" in
        --solo-infra) SOLO_INFRA=1; shift ;;
        --tipo)       INSTANCE_TYPE="$2"; shift 2 ;;
        *)            die "Opción desconocida: $1" ;;
    esac
done

NAME_TAG="andesstay-mq"
SG_NAME="andesstay-mq"
INSTALL_DIR="/opt/andesstay"
AMI_PARAM="/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"

# Lo que se sube: el compose de la mensajería, el aprovisionamiento y los dos
# servicios que corren aquí. ms-andesstay-notify y ms-andesstay-mq NO están en
# los arrays de crear-infra.sh a propósito: no se despliegan en ec2-apps.
REPOS_MQ=(infra ms-andesstay-notify ms-andesstay-mq)

ENV_MQ="${ENV_MQ:-$PROJECT_ROOT/secrets/andesstay-mq.env}"

# ═════════════════════════════════════════════════════════════════════════════
# 1. Comprobaciones previas
# ═════════════════════════════════════════════════════════════════════════════
log "Comprobando herramientas y código"

for cmd in ssh scp tar curl; do
    command -v "$cmd" > /dev/null 2>&1 || die "Falta '$cmd'. En Windows, ejecutar desde Git Bash."
done

if (( ! SOLO_INFRA )); then
    for repo in "${REPOS_MQ[@]}"; do
        [[ -d "$PROJECT_ROOT/$repo" ]] || die "No está $PROJECT_ROOT/$repo."
    done
fi
ok "herramientas y los ${#REPOS_MQ[@]} repositorios"

[[ -f "$ENV_MQ" ]] || die "Falta $ENV_MQ.
Tiene que declarar RABBITMQ_USER, RABBITMQ_PASSWORD y RABBITMQ_ERLANG_COOKIE."
ok "variables en $ENV_MQ"

require_session
load_state

# ec2-apps tiene que existir: su Security Group es el ORIGEN de la regla del
# 5672, y sin él la mensajería quedaría abierta a un rango de IP en lugar de a
# un grupo concreto.
[[ -n "${SG_ID:-}" ]] || die "No hay SG_ID en el estado. Ejecutar antes scripts/crear-infra.sh."
ok "Security Group de ec2-apps: $SG_ID"

MY_IP=$(my_public_ip) || die "No se pudo obtener la IP pública de este equipo"
ok "IP del operador: $MY_IP"

VPC_ID=${VPC_ID:-$(awsq ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId')}
AMI_ID=$(awsq ssm get-parameter --name "$AMI_PARAM" --query Parameter.Value)
[[ -n "$AMI_ID" ]] || die "No se pudo resolver la AMI de Ubuntu 24.04"
ok "VPC $VPC_ID, AMI $AMI_ID"

# ═════════════════════════════════════════════════════════════════════════════
# 2. Security Group
# ═════════════════════════════════════════════════════════════════════════════
log "Security Group $SG_NAME"

if [[ -n "${MQ_SG_ID:-}" ]] && [[ -z "$(awsq ec2 describe-security-groups --group-ids "$MQ_SG_ID" --query 'SecurityGroups[0].GroupId')" ]]; then
    warn "el grupo $MQ_SG_ID del estado ya no existe; se busca o se crea"
    clear_state_key MQ_SG_ID
fi

MQ_SG_ID=${MQ_SG_ID:-$(awsq ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId')}

if [[ -z "$MQ_SG_ID" ]]; then
    MQ_SG_ID=$(awsq ec2 create-security-group --group-name "$SG_NAME" \
        --description "AndesStay - mensajeria (RabbitMQ, notify, mq)" \
        --vpc-id "$VPC_ID" --query GroupId)
    ok "creado $MQ_SG_ID"
else
    ok "existente $MQ_SG_ID"
fi
save_state MQ_SG_ID "$MQ_SG_ID"

# Autoriza una regla sin fallar si ya existe.
autorizar() {
    local desc="$1"; shift
    if salida=$(awsx ec2 authorize-security-group-ingress --group-id "$MQ_SG_ID" "$@" 2>&1); then
        ok "$desc"
    elif grep -q "InvalidPermission.Duplicate" <<< "$salida"; then
        info "$desc: ya autorizado"
    else
        die "No se pudo autorizar $desc: $salida"
    fi
}

# 22 solo desde el equipo del operador. El puerto 15672 de la UI de gestión NO
# se abre: el compose lo publica únicamente en loopback y la vía es un túnel SSH.
autorizar "SSH desde $MY_IP" \
    --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$MY_IP/32,Description='SSH operador'}]"

# AMQP desde el Security Group de ec2-apps, no desde un rango de IP. Así la
# autorización sigue siendo válida si la instancia de aplicaciones cambia de IP,
# y el broker no queda expuesto a internet en ningún momento.
autorizar "AMQP 5672 desde ec2-apps" \
    --ip-permissions "IpProtocol=tcp,FromPort=5672,ToPort=5672,UserIdGroupPairs=[{GroupId=$SG_ID,Description='ec2-apps'}]"
autorizar "AMQP 5673 (segundo nodo) desde ec2-apps" \
    --ip-permissions "IpProtocol=tcp,FromPort=5673,ToPort=5673,UserIdGroupPairs=[{GroupId=$SG_ID,Description='ec2-apps'}]"

# ═════════════════════════════════════════════════════════════════════════════
# 3. Instancia
# ═════════════════════════════════════════════════════════════════════════════
log "Instancia EC2 ($INSTANCE_TYPE)"

if [[ -n "${MQ_INSTANCE_ID:-}" ]]; then
    estado=$(awsq ec2 describe-instances --instance-ids "$MQ_INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name')
    [[ -z "$estado" || "$estado" == "terminated" || "$estado" == "shutting-down" ]] && clear_state_key MQ_INSTANCE_ID
fi
MQ_INSTANCE_ID=${MQ_INSTANCE_ID:-$(awsq ec2 describe-instances \
    --filters "Name=tag:Name,Values=$NAME_TAG" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId')}

if [[ -n "$MQ_INSTANCE_ID" ]]; then
    # Se reutiliza la clave con la que se lanzó, igual que hace crear-infra.sh:
    # sin su .pem no hay forma de entrar.
    MQ_KEY_NAME=$(awsq ec2 describe-instances --instance-ids "$MQ_INSTANCE_ID" --query 'Reservations[0].Instances[0].KeyName')
    MQ_KEY_FILE="$HOME/.ssh/$MQ_KEY_NAME.pem"
    [[ -f "$MQ_KEY_FILE" ]] || die "La instancia $MQ_INSTANCE_ID se lanzó con el par '$MQ_KEY_NAME', pero no está $MQ_KEY_FILE."

    estado=$(awsq ec2 describe-instances --instance-ids "$MQ_INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name')
    case "$estado" in
        stopping) info "deteniéndose; se espera y se arranca"
                  awsx ec2 wait instance-stopped --instance-ids "$MQ_INSTANCE_ID"
                  awsx ec2 start-instances --instance-ids "$MQ_INSTANCE_ID" > /dev/null ;;
        stopped)  info "detenida; se arranca"
                  awsx ec2 start-instances --instance-ids "$MQ_INSTANCE_ID" > /dev/null ;;
    esac
    ok "existente $MQ_INSTANCE_ID ($estado), clave $MQ_KEY_NAME"
else
    # Se reutiliza el MISMO par de claves que ec2-apps: son dos instancias del
    # mismo despliegue y una sola clave que custodiar es una menos que perder.
    [[ -n "${KEY_NAME:-}" ]] || die "No hay KEY_NAME en el estado. Ejecutar antes scripts/crear-infra.sh."
    MQ_KEY_NAME="$KEY_NAME"
    MQ_KEY_FILE="$HOME/.ssh/$MQ_KEY_NAME.pem"
    [[ -f "$MQ_KEY_FILE" ]] || die "No está $MQ_KEY_FILE, la clave de ec2-apps."

    # En la misma subred que ec2-apps: misma zona de disponibilidad, así que el
    # tráfico AMQP no cruza zonas ni se factura como tal.
    SUBNET_ID=$(awsq ec2 describe-instances --instance-ids "${INSTANCE_ID:-}" \
        --query 'Reservations[0].Instances[0].SubnetId' 2>/dev/null || true)

    args=(--image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE"
          --key-name "$MQ_KEY_NAME" --security-group-ids "$MQ_SG_ID"
          --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3}'
          --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME_TAG}]"
          --query 'Instances[0].InstanceId')
    [[ -n "$SUBNET_ID" ]] && args+=(--subnet-id "$SUBNET_ID")

    if awsq iam list-instance-profiles --query 'InstanceProfiles[].InstanceProfileName' | tr '\t' '\n' | grep -qx LabInstanceProfile; then
        args+=(--iam-instance-profile Name=LabInstanceProfile)
    fi

    MQ_INSTANCE_ID=$(awsq ec2 run-instances "${args[@]}")
    [[ -n "$MQ_INSTANCE_ID" ]] || die "No se pudo lanzar la instancia"
    ok "lanzada $MQ_INSTANCE_ID ($INSTANCE_TYPE)"
fi
save_state MQ_INSTANCE_ID "$MQ_INSTANCE_ID"
save_state MQ_KEY_NAME "$MQ_KEY_NAME"

info "esperando el estado running..."
awsx ec2 wait instance-running --instance-ids "$MQ_INSTANCE_ID"
ok "running"

MQ_PUBLIC_IP=$(awsq ec2 describe-instances --instance-ids "$MQ_INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress')
MQ_PRIVATE_IP=$(awsq ec2 describe-instances --instance-ids "$MQ_INSTANCE_ID" --query 'Reservations[0].Instances[0].PrivateIpAddress')
[[ -n "$MQ_PRIVATE_IP" ]] || die "La instancia no tiene IP privada"
save_state MQ_PUBLIC_IP "$MQ_PUBLIC_IP"
save_state MQ_PRIVATE_IP "$MQ_PRIVATE_IP"
ok "pública $MQ_PUBLIC_IP, privada $MQ_PRIVATE_IP"

if (( SOLO_INFRA )); then
    log "Infraestructura de mensajería lista (--solo-infra)"
    info "Instancia : $MQ_INSTANCE_ID ($MQ_PUBLIC_IP)"
    info "Privada   : $MQ_PRIVATE_IP"
    exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# 4. Código y aprovisionamiento
# ═════════════════════════════════════════════════════════════════════════════
mapfile -t SSHO < <(ssh_opts "$MQ_KEY_FILE")
TARGET="ubuntu@$MQ_PUBLIC_IP"

log "Esperando que SSH responda en $MQ_PUBLIC_IP"
intentos=0
until ssh "${SSHO[@]}" "$TARGET" 'echo listo' 2>/dev/null | grep -q listo; do
    (( ++intentos > 40 )) && die "SSH no responde tras 7 minutos. Revisar que el 22 esté autorizado para $MY_IP."
    sleep 10
done
ok "conectado"

log "Subiendo el código"
PAQUETE="$(mktemp -d)/andesstay-mq.tgz"
tar czf "$PAQUETE" -C "$PROJECT_ROOT" \
    --exclude='node_modules' --exclude='target' --exclude='.git' --exclude='dist' \
    --exclude='*.pem' --exclude='credenciales-aws.txt' --exclude='.estado-aws.env*' \
    "${REPOS_MQ[@]}"
info "paquete de $(du -h "$PAQUETE" | cut -f1)"
scp "${SSHO[@]}" -q "$PAQUETE" "$TARGET:/tmp/andesstay-mq.tgz"
rm -rf "$(dirname "$PAQUETE")"

ssh "${SSHO[@]}" "$TARGET" "bash -s" <<REMOTE
set -e
sudo mkdir -p $INSTALL_DIR
sudo chown ubuntu:ubuntu $INSTALL_DIR
cd $INSTALL_DIR
rm -rf ${REPOS_MQ[*]}
tar xzf /tmp/andesstay-mq.tgz -C $INSTALL_DIR
rm -f /tmp/andesstay-mq.tgz
REMOTE
ok "código en $INSTALL_DIR"

log "Instalando las variables"
scp "${SSHO[@]}" -q "$ENV_MQ" "$TARGET:/tmp/mq.env"
ssh "${SSHO[@]}" "$TARGET" "bash -s" <<REMOTE
set -e
mv /tmp/mq.env $INSTALL_DIR/mq.env
chmod 600 $INSTALL_DIR/mq.env
REMOTE
ok "$INSTALL_DIR/mq.env con permisos 600"

log "Aprovisionando la instancia (Docker, swap, cortafuegos)"
ssh "${SSHO[@]}" "$TARGET" "SKIP_CLONE=1 bash $INSTALL_DIR/infra/deploy/provision.sh" > /tmp/provision-mq.log 2>&1 \
    || { tail -20 /tmp/provision-mq.log; die "Falló el aprovisionamiento"; }
ok "instancia aprovisionada"

# ═════════════════════════════════════════════════════════════════════════════
# 5. Construcción y arranque
# ═════════════════════════════════════════════════════════════════════════════
log "Construyendo las imágenes en la instancia"

# De una en una, como en ec2-apps: dos mvn package de Spring Boot a la vez no
# caben en 2 GB ni con el swap.
ssh "${SSHO[@]}" "$TARGET" "bash -s" <<'REMOTE'
set -e
cd /opt/andesstay
C="docker compose --env-file mq.env -f infra/mq/compose.yml"
for s in notify mq; do
    ini=$(date +%s)
    $C build "$s" >> /tmp/build-mq.log 2>&1 || { echo "FALLO al construir $s"; tail -25 /tmp/build-mq.log; exit 1; }
    echo "  [ok] $s ($(( $(date +%s) - ini ))s)"
done
REMOTE
ok "imágenes construidas"

log "Levantando el clúster y los consumidores"
ssh "${SSHO[@]}" "$TARGET" "bash -s" <<'REMOTE'
set -e
cd /opt/andesstay
C="docker compose --env-file mq.env -f infra/mq/compose.yml"
$C up -d >> /tmp/up-mq.log 2>&1
echo "  esperando que los contenedores estén sanos..."
for i in $(seq 1 40); do
    sanos=$(docker ps --filter health=healthy --format '{{.Names}}' | grep -c andesstay || true)
    [ "$sanos" -ge 4 ] && break
    sleep 10
done
docker ps --format '{{.Names}}\t{{.Status}}' | grep andesstay | sort
REMOTE
ok "mensajería en ejecución"

# ═════════════════════════════════════════════════════════════════════════════
# 6. Pruebas de humo
# ═════════════════════════════════════════════════════════════════════════════
log "Pruebas de humo"

ssh "${SSHO[@]}" "$TARGET" "bash -s" <<'REMOTE'
set -e
comprobar() { printf '  [%s] %s → %s\n' "$([ "$2" = "$3" ] && echo ok || echo ERROR)" "$1" "$3"; }

nodos=$(docker exec andesstay-rabbitmq1 rabbitmqctl -q cluster_status --formatter json 2>/dev/null \
        | tr ',' '\n' | grep -c 'rabbit@rabbitmq' || echo 0)
printf '  [%s] nodos en el clúster → %s\n' "$([ "$nodos" -ge 2 ] && echo ok || echo ERROR)" "$nodos"

colas=$(docker exec andesstay-rabbitmq1 rabbitmqctl -q list_queues -p andesstay name 2>/dev/null | grep -c '^q\.cmd\.' || echo 0)
printf '  [%s] colas declaradas → %s (9 esperadas)\n' "$([ "$colas" -eq 9 ] && echo ok || echo ERROR)" "$colas"

pol=$(docker exec andesstay-rabbitmq1 rabbitmqctl -q list_policies -p andesstay name 2>/dev/null | grep -c 'ha-colas-cmd' || echo 0)
printf '  [%s] política de espejado → %s\n' "$([ "$pol" -ge 1 ] && echo ok || echo ERROR)" "$pol"

comprobar "notify /actuator/health" UP "$(docker exec andesstay-notify wget -qO- http://127.0.0.1:8085/actuator/health 2>/dev/null | grep -o '"status":"[A-Z]*"' | head -1 | cut -d'"' -f4)"
comprobar "mq /actuator/health"     UP "$(docker exec andesstay-mq     wget -qO- http://127.0.0.1:8086/actuator/health 2>/dev/null | grep -o '"status":"[A-Z]*"' | head -1 | cut -d'"' -f4)"
comprobar "mq exige token"         401 "$(docker exec andesstay-mq wget -qSO- http://127.0.0.1:8086/api/v1/mq/queues 2>&1 | grep -o 'HTTP/1.1 [0-9]*' | head -1 | awk '{print $2}')"
REMOTE

# ═════════════════════════════════════════════════════════════════════════════
# 7. Resumen
# ═════════════════════════════════════════════════════════════════════════════
log "Mensajería desplegada"

cat <<RESUMEN

  Instancia  : $MQ_INSTANCE_ID  ($MQ_PUBLIC_IP)
  IP privada : $MQ_PRIVATE_IP
  SSH        : ssh -i "$MQ_KEY_FILE" ubuntu@$MQ_PUBLIC_IP

  Management UI, por túnel (se publica solo en loopback):
    ssh -i "$MQ_KEY_FILE" -L 15672:localhost:15672 ubuntu@$MQ_PUBLIC_IP

  API de administración de colas, por túnel (exige rol Admin):
    ssh -i "$MQ_KEY_FILE" -L 8086:localhost:8086 ubuntu@$MQ_PUBLIC_IP

  ┌──────────────────────────────────────────────────────────────────────────┐
  │ Para que reservations publique, en el .env de ec2-apps:                  │
  └──────────────────────────────────────────────────────────────────────────┘

      RABBITMQ_HOST=$MQ_PRIVATE_IP

  Y volver a ejecutar scripts/crear-infra.sh para que lo recoja.

RESUMEN
