#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AndesStay — instancia ec2-kafka: Zookeeper (3 nodos), Kafka (3 brokers) y Kafka UI
#
# Crea la TERCERA instancia del despliegue. crear-infra.sh crea ec2-apps con los
# microservicios de dominio, el BFF y la SPA; crear-mq.sh crea ec2-mq con el
# clúster de RabbitMQ; esta lleva el streaming.
#
# Uso:
#   bash scripts/crear-kafka.sh              # crea o actualiza ec2-kafka
#   bash scripts/crear-kafka.sh --solo-infra # instancia y red, sin desplegar
#
# Al terminar imprime KAFKA_PRIVATE_IP, que es lo que hay que poner en el .env de
# ec2-apps para que reservations publique y para que report y audit consuman.
#
# ── POR QUÉ UNA TERCERA INSTANCIA ───────────────────────────────────────────
#
# El caso lo pide explícitamente: ec2-apps, ec2-mq y ec2-kafka, un compose por
# cada una. Pero además no cabe de otra forma: siete contenedores de streaming
# junto a los siete de aplicación no entran en una t3.medium, y mezclarlos haría
# que un pico de uno se llevara por delante al otro.
#
# ── POR QUÉ t3.medium ───────────────────────────────────────────────────────
#
# Son seis JVM más Kafka UI. Con los montones acotados en el compose —512 MB por
# broker y 256 MB por nodo de Zookeeper— suman unos 2,3 GB; con los valores por
# defecto pedirían 4,5 GB y no arrancarían. Sobre 4 GB quedan unos 1,5 GB para
# Docker, la interfaz y el sistema, más el swapfile de provision.sh.
#
# ── POR QUÉ ZOOKEEPER Y NO KRaft ────────────────────────────────────────────
#
# Kafka 4.x ya no trae Zookeeper, pero el caso y la pauta de evaluación piden
# explícitamente tres nodos de Zookeeper y tres brokers. De ahí que las imágenes
# estén fijadas en la serie 7.6 de Confluent, que todavía lo soporta.
#
# ── POR QUÉ NO LLEVA IP ELÁSTICA ────────────────────────────────────────────
#
# Nadie la alcanza desde internet. ec2-apps le habla por la IP PRIVADA, que es
# estable mientras la instancia exista, y el operador entra por SSH con la IP
# pública efímera, que el script vuelve a leer en cada ejecución.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-aws.sh
source "$SCRIPT_DIR/lib-aws.sh"

SOLO_INFRA=0
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.medium}"

while (( $# )); do
    case "$1" in
        --solo-infra) SOLO_INFRA=1; shift ;;
        --tipo)       INSTANCE_TYPE="$2"; shift 2 ;;
        *)            die "Opción desconocida: $1" ;;
    esac
done

NAME_TAG="andesstay-kafka"
SG_NAME="andesstay-kafka"
INSTALL_DIR="/opt/andesstay"
AMI_PARAM="/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"

# Solo hace falta infra: el clúster son imágenes de Confluent, no hay nada que
# compilar aquí. Es la diferencia con ec2-mq, que sí sube dos microservicios.
REPOS_KAFKA=(infra)

# ═════════════════════════════════════════════════════════════════════════════
# 1. Comprobaciones previas
# ═════════════════════════════════════════════════════════════════════════════
log "Comprobando herramientas y código"

for cmd in ssh scp tar curl; do
    command -v "$cmd" > /dev/null 2>&1 || die "Falta '$cmd'. En Windows, ejecutar desde Git Bash."
done

for repo in "${REPOS_KAFKA[@]}"; do
    [[ -d "$PROJECT_ROOT/$repo" ]] || die "No está $PROJECT_ROOT/$repo."
done
ok "herramientas y el repositorio de infraestructura"

require_session
load_state

# ec2-apps tiene que existir: su Security Group es el ORIGEN de la regla de los
# puertos 9092-9094, y sin él el clúster quedaría abierto a un rango de IP en
# lugar de a un grupo concreto.
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

if [[ -n "${KAFKA_SG_ID:-}" ]] && [[ -z "$(awsq ec2 describe-security-groups --group-ids "$KAFKA_SG_ID" --query 'SecurityGroups[0].GroupId')" ]]; then
    warn "el grupo $KAFKA_SG_ID del estado ya no existe; se busca o se crea"
    clear_state_key KAFKA_SG_ID
fi

KAFKA_SG_ID=${KAFKA_SG_ID:-$(awsq ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId')}

if [[ -z "$KAFKA_SG_ID" ]]; then
    KAFKA_SG_ID=$(awsq ec2 create-security-group --group-name "$SG_NAME" \
        --description "AndesStay - streaming (Zookeeper, Kafka, Kafka UI)" \
        --vpc-id "$VPC_ID" --query GroupId)
    ok "creado $KAFKA_SG_ID"
else
    ok "existente $KAFKA_SG_ID"
fi
save_state KAFKA_SG_ID "$KAFKA_SG_ID"

autorizar() {
    local desc="$1"; shift
    if salida=$(awsx ec2 authorize-security-group-ingress --group-id "$KAFKA_SG_ID" "$@" 2>&1); then
        ok "$desc"
    elif grep -q "InvalidPermission.Duplicate" <<< "$salida"; then
        info "$desc: ya autorizado"
    else
        die "No se pudo autorizar $desc: $salida"
    fi
}

autorizar "SSH desde $MY_IP" \
    --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$MY_IP/32,Description='SSH operador'}]"

# Los tres brokers desde el Security Group de ec2-apps, no desde un rango de IP.
# Así la autorización sigue valiendo si la instancia de aplicaciones cambia de
# IP, y el clúster no queda expuesto a internet en ningún momento.
autorizar "Kafka 9092-9094 desde ec2-apps" \
    --ip-permissions "IpProtocol=tcp,FromPort=9092,ToPort=9094,UserIdGroupPairs=[{GroupId=$SG_ID,Description='ec2-apps'}]"

# Kafka UI sí se abre, pero SOLO al equipo del operador: es lo que hay que
# mostrar en la presentación y un túnel SSH complicaría la demostración sin
# ganar nada, dado que la interfaz no expone secretos del negocio. Si la IP del
# operador cambia, basta volver a ejecutar el script.
autorizar "Kafka UI 8090 desde $MY_IP" \
    --ip-permissions "IpProtocol=tcp,FromPort=8090,ToPort=8090,IpRanges=[{CidrIp=$MY_IP/32,Description='Kafka UI operador'}]"

# ═════════════════════════════════════════════════════════════════════════════
# 3. Instancia
# ═════════════════════════════════════════════════════════════════════════════
log "Instancia EC2 ($INSTANCE_TYPE)"

if [[ -n "${KAFKA_INSTANCE_ID:-}" ]]; then
    estado=$(awsq ec2 describe-instances --instance-ids "$KAFKA_INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name')
    [[ -z "$estado" || "$estado" == "terminated" || "$estado" == "shutting-down" ]] && clear_state_key KAFKA_INSTANCE_ID
fi
KAFKA_INSTANCE_ID=${KAFKA_INSTANCE_ID:-$(awsq ec2 describe-instances \
    --filters "Name=tag:Name,Values=$NAME_TAG" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId')}

if [[ -n "$KAFKA_INSTANCE_ID" ]]; then
    KAFKA_KEY_NAME=$(awsq ec2 describe-instances --instance-ids "$KAFKA_INSTANCE_ID" --query 'Reservations[0].Instances[0].KeyName')
    KAFKA_KEY_FILE="$HOME/.ssh/$KAFKA_KEY_NAME.pem"
    [[ -f "$KAFKA_KEY_FILE" ]] || die "La instancia $KAFKA_INSTANCE_ID se lanzó con el par '$KAFKA_KEY_NAME', pero no está $KAFKA_KEY_FILE."

    estado=$(awsq ec2 describe-instances --instance-ids "$KAFKA_INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name')
    case "$estado" in
        stopping) info "deteniéndose; se espera y se arranca"
                  awsx ec2 wait instance-stopped --instance-ids "$KAFKA_INSTANCE_ID"
                  awsx ec2 start-instances --instance-ids "$KAFKA_INSTANCE_ID" > /dev/null ;;
        stopped)  info "detenida; se arranca"
                  awsx ec2 start-instances --instance-ids "$KAFKA_INSTANCE_ID" > /dev/null ;;
    esac
    ok "existente $KAFKA_INSTANCE_ID ($estado), clave $KAFKA_KEY_NAME"
else
    # El MISMO par de claves que las otras dos instancias: son tres instancias
    # del mismo despliegue y una sola clave que custodiar.
    [[ -n "${KEY_NAME:-}" ]] || die "No hay KEY_NAME en el estado. Ejecutar antes scripts/crear-infra.sh."
    KAFKA_KEY_NAME="$KEY_NAME"
    KAFKA_KEY_FILE="$HOME/.ssh/$KAFKA_KEY_NAME.pem"
    [[ -f "$KAFKA_KEY_FILE" ]] || die "No está $KAFKA_KEY_FILE, la clave de ec2-apps."

    # En la misma subred que ec2-apps: misma zona de disponibilidad, así que el
    # tráfico no cruza zonas ni se factura como tal.
    SUBNET_ID=$(awsq ec2 describe-instances --instance-ids "${INSTANCE_ID:-}" \
        --query 'Reservations[0].Instances[0].SubnetId' 2>/dev/null || true)

    # 30 GB y no 20: los seis brokers y nodos guardan sus registros en volúmenes,
    # y con la retención de siete días del tópico principal conviene el margen.
    args=(--image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE"
          --key-name "$KAFKA_KEY_NAME" --security-group-ids "$KAFKA_SG_ID"
          --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=30,VolumeType=gp3}'
          --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME_TAG}]"
          --query 'Instances[0].InstanceId')
    [[ -n "$SUBNET_ID" ]] && args+=(--subnet-id "$SUBNET_ID")

    if awsq iam list-instance-profiles --query 'InstanceProfiles[].InstanceProfileName' | tr '\t' '\n' | grep -qx LabInstanceProfile; then
        args+=(--iam-instance-profile Name=LabInstanceProfile)
    fi

    KAFKA_INSTANCE_ID=$(awsq ec2 run-instances "${args[@]}")
    [[ -n "$KAFKA_INSTANCE_ID" ]] || die "No se pudo lanzar la instancia"
    ok "lanzada $KAFKA_INSTANCE_ID ($INSTANCE_TYPE)"
fi
save_state KAFKA_INSTANCE_ID "$KAFKA_INSTANCE_ID"
save_state KAFKA_KEY_NAME "$KAFKA_KEY_NAME"

info "esperando el estado running..."
awsx ec2 wait instance-running --instance-ids "$KAFKA_INSTANCE_ID"
ok "running"

KAFKA_PUBLIC_IP=$(awsq ec2 describe-instances --instance-ids "$KAFKA_INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress')
KAFKA_PRIVATE_IP=$(awsq ec2 describe-instances --instance-ids "$KAFKA_INSTANCE_ID" --query 'Reservations[0].Instances[0].PrivateIpAddress')
[[ -n "$KAFKA_PRIVATE_IP" ]] || die "La instancia no tiene IP privada"
save_state KAFKA_PUBLIC_IP "$KAFKA_PUBLIC_IP"
save_state KAFKA_PRIVATE_IP "$KAFKA_PRIVATE_IP"
ok "pública $KAFKA_PUBLIC_IP, privada $KAFKA_PRIVATE_IP"

if (( SOLO_INFRA )); then
    log "Infraestructura de streaming lista (--solo-infra)"
    info "Instancia : $KAFKA_INSTANCE_ID ($KAFKA_PUBLIC_IP)"
    info "Privada   : $KAFKA_PRIVATE_IP"
    exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# 4. Código y aprovisionamiento
# ═════════════════════════════════════════════════════════════════════════════
mapfile -t SSHO < <(ssh_opts "$KAFKA_KEY_FILE")
TARGET="ubuntu@$KAFKA_PUBLIC_IP"

log "Esperando que SSH responda en $KAFKA_PUBLIC_IP"
intentos=0
until ssh "${SSHO[@]}" "$TARGET" 'echo listo' 2>/dev/null | grep -q listo; do
    (( ++intentos > 40 )) && die "SSH no responde tras 7 minutos. Revisar que el 22 esté autorizado para $MY_IP."
    sleep 10
done
ok "conectado"

log "Subiendo el código"
PAQUETE="$(mktemp -d)/andesstay-kafka.tgz"
tar czf "$PAQUETE" -C "$PROJECT_ROOT" \
    --exclude='node_modules' --exclude='target' --exclude='.git' --exclude='dist' \
    --exclude='*.pem' --exclude='credenciales-aws.txt' --exclude='.estado-aws.env*' \
    --exclude='docs/evidencias' \
    "${REPOS_KAFKA[@]}"
info "paquete de $(du -h "$PAQUETE" | cut -f1)"
scp "${SSHO[@]}" -q "$PAQUETE" "$TARGET:/tmp/andesstay-kafka.tgz"
rm -rf "$(dirname "$PAQUETE")"

ssh "${SSHO[@]}" "$TARGET" "bash -s" <<REMOTE
set -e
sudo mkdir -p $INSTALL_DIR
sudo chown ubuntu:ubuntu $INSTALL_DIR
cd $INSTALL_DIR
rm -rf ${REPOS_KAFKA[*]}
tar xzf /tmp/andesstay-kafka.tgz -C $INSTALL_DIR
rm -f /tmp/andesstay-kafka.tgz
REMOTE
ok "código en $INSTALL_DIR"

# La IP privada se escribe en un .env que el compose lee. Es lo que hace que los
# brokers anuncien una dirección alcanzable desde ec2-apps en vez de localhost:
# sin esto el clúster levanta, Kafka UI lo muestra sano, y los microservicios
# fallan con un error que no menciona a Kafka por ninguna parte.
log "Fijando el oyente anunciado en $KAFKA_PRIVATE_IP"
ssh "${SSHO[@]}" "$TARGET" "bash -s" <<REMOTE
set -e
printf 'KAFKA_ADVERTISED_HOST=%s\n' "$KAFKA_PRIVATE_IP" > $INSTALL_DIR/kafka.env
chmod 600 $INSTALL_DIR/kafka.env
REMOTE
ok "$INSTALL_DIR/kafka.env"

log "Aprovisionando la instancia (Docker, swap, cortafuegos)"
ssh "${SSHO[@]}" "$TARGET" "SKIP_CLONE=1 bash $INSTALL_DIR/infra/deploy/provision.sh" > /tmp/provision-kafka.log 2>&1 \
    || { tail -20 /tmp/provision-kafka.log; die "Falló el aprovisionamiento"; }
ok "instancia aprovisionada"

# ═════════════════════════════════════════════════════════════════════════════
# 5. Arranque
# ═════════════════════════════════════════════════════════════════════════════
log "Levantando Zookeeper, los brokers y Kafka UI"

# No hay nada que construir: son todas imágenes de Confluent y de Provectus.
ssh "${SSHO[@]}" "$TARGET" "bash -s" <<'REMOTE'
set -e
cd /opt/andesstay
C="docker compose --env-file kafka.env -f infra/kafka/compose.yml"
$C up -d >> /tmp/up-kafka.log 2>&1

echo "  esperando a que los tres brokers estén sanos..."
for i in $(seq 1 40); do
    sanos=$(docker ps --filter health=healthy --format '{{.Names}}' | grep -c andesstay-kafka || true)
    [ "$sanos" -ge 3 ] && break
    sleep 10
done
docker ps --format '{{.Names}}\t{{.Status}}' | grep andesstay | sort
REMOTE
ok "clúster en ejecución"

# ═════════════════════════════════════════════════════════════════════════════
# 6. Pruebas de humo
# ═════════════════════════════════════════════════════════════════════════════
log "Pruebas de humo"

ssh "${SSHO[@]}" "$TARGET" "bash -s" <<'REMOTE'
set -e
K() { docker exec -i andesstay-kafka1 "$@"; }

# Tres brokers registrados en Zookeeper. Con menos, el factor de replicación 3
# de los tópicos no se puede satisfacer y la creación falla.
brokers=$(K kafka-broker-api-versions --bootstrap-server kafka1:29092 2>/dev/null \
    | grep -c "^kafka" || true)
printf '  [%s] brokers alcanzables → %s (3 esperados)\n' \
    "$([ "${brokers:-0}" -ge 3 ] && echo ok || echo ERROR)" "${brokers:-0}"

# Los dos tópicos del caso, con tres particiones y tres réplicas cada uno. Es el
# punto concreto que la pauta de la presentación evalúa.
for t in reservations.events audit.timeline; do
    linea=$(K kafka-topics --describe --bootstrap-server kafka1:29092 --topic "$t" 2>/dev/null | head -1)
    parts=$(sed -n 's/.*PartitionCount: *\([0-9]*\).*/\1/p' <<< "$linea")
    reps=$(sed -n 's/.*ReplicationFactor: *\([0-9]*\).*/\1/p' <<< "$linea")
    printf '  [%s] %s → %s particiones, %s réplicas\n' \
        "$([ "${parts:-0}" = 3 ] && [ "${reps:-0}" = 3 ] && echo ok || echo ERROR)" \
        "$t" "${parts:-?}" "${reps:-?}"
done

# Un ISR incompleto significa que hay un broker que no está al día: el clúster
# responde, pero ya no tolera otra caída. Conviene saberlo antes y no durante.
fuera=$(K kafka-topics --describe --bootstrap-server kafka1:29092 --under-replicated-partitions 2>/dev/null | grep -c Partition || true)
printf '  [%s] particiones sin replicar → %s (0 esperadas)\n' \
    "$([ "${fuera:-0}" -eq 0 ] && echo ok || echo ERROR)" "${fuera:-0}"

# Ida y vuelta real: si esto pasa, el clúster acepta escrituras con acks=all y
# las sirve. Es la prueba que ninguna de las anteriores sustituye.
K bash -c 'echo "prueba-de-humo" | kafka-console-producer --bootstrap-server kafka1:29092 --topic reservations.events --property parse.key=false' 2>/dev/null
leido=$(K kafka-console-consumer --bootstrap-server kafka1:29092 --topic reservations.events \
    --from-beginning --max-messages 1 --timeout-ms 15000 2>/dev/null | head -1)
printf '  [%s] ida y vuelta por reservations.events → %s\n' \
    "$([ -n "$leido" ] && echo ok || echo ERROR)" "${leido:-sin respuesta}"

ui=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8090/ || echo 000)
printf '  [%s] Kafka UI → HTTP %s\n' "$([ "$ui" = 200 ] && echo ok || echo ERROR)" "$ui"
REMOTE

# ═════════════════════════════════════════════════════════════════════════════
# 7. Resumen
# ═════════════════════════════════════════════════════════════════════════════
log "Streaming desplegado"

cat <<RESUMEN

  Instancia  : $KAFKA_INSTANCE_ID  ($KAFKA_PUBLIC_IP)
  IP privada : $KAFKA_PRIVATE_IP
  SSH        : ssh -i "$KAFKA_KEY_FILE" ubuntu@$KAFKA_PUBLIC_IP

  Kafka UI   : http://$KAFKA_PUBLIC_IP:8090   (abierto solo para $MY_IP)

  Administración desde la instancia:
    bash infra/kafka/scripts/describir-topicos.sh
    bash infra/kafka/scripts/inspeccionar-grupos.sh

  ┌──────────────────────────────────────────────────────────────────────────┐
  │ Para que reservations publique y report y audit consuman, en el .env de  │
  │ ec2-apps:                                                                │
  └──────────────────────────────────────────────────────────────────────────┘

      KAFKA_HOST=$KAFKA_PRIVATE_IP
      ANDESSTAY_EVENTS_KAFKA_ENABLED=true

  Y volver a ejecutar scripts/crear-infra.sh para que lo recoja.

RESUMEN
