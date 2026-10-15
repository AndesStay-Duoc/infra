#!/usr/bin/env bash
#
# Enciende, apaga o consulta las instancias de AndesStay.
#
# POR QUÉ EXISTE. Apagar las instancias entre sesiones de trabajo es lo que evita gastar el crédito
# del laboratorio, y hacerlo con una orden suelta tiene dos problemas: stop-instances exige al menos
# un identificador y falla cuando no hay ninguna encendida, y los identificadores cambian si la
# infraestructura se recrea. Aquí se descubren por etiqueta y se tolera la lista vacía.
#
# APAGAR NO ES DESTRUIR. Una instancia detenida no cobra cómputo pero conserva su disco, su
# dirección privada y todo lo instalado, así que encenderla de nuevo deja el entorno donde estaba.
# Para desmontarlo de verdad está destruir-infra.sh, que es irreversible.
#
# LO QUE SIGUE COSTANDO CON TODO APAGADO. El disco de cada instancia y las dos direcciones
# elásticas. Es deliberado: la elástica es lo que hace que la dirección pública no cambie entre
# sesiones, y su coste es una fracción del de una instancia encendida. Liberarlas ahorraría
# céntimos y obligaría a reconfigurar la dirección en cada arranque.
#
# USO
#
#     ./instancias.sh estado      qué hay y en qué estado
#     ./instancias.sh apagar      detiene todo y espera a que esté detenido
#     ./instancias.sh encender    arranca todo y espera a que responda
#
set -euo pipefail

PERFIL="${AWS_PROFILE:-andesstay}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
ETIQUETA="${ANDESSTAY_TAG:-andesstay-*}"

aws_() { aws --profile "$PERFIL" --region "$REGION" "$@"; }

# Los identificadores de las instancias del proyecto en los estados que se indiquen. Se devuelve
# vacío sin fallar: es un resultado legítimo, no un error.
ids_en_estado() {
    aws_ ec2 describe-instances \
        --filters "Name=tag:Name,Values=$ETIQUETA" "Name=instance-state-name,Values=$1" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null \
        | tr -d '\r' | tr '\t' '\n' | grep -v '^$' || true
}

tabla() {
    aws_ ec2 describe-instances \
        --filters "Name=tag:Name,Values=$ETIQUETA" \
                  'Name=instance-state-name,Values=pending,running,stopping,stopped' \
        --query 'Reservations[].Instances[].{Nombre:Tags[?Key==`Name`]|[0].Value,
                 Estado:State.Name,Tipo:InstanceType,IPpub:PublicIpAddress,IPpriv:PrivateIpAddress}' \
        --output table 2>&1 || true
}

sesion_valida() {
    aws_ sts get-caller-identity --query 'Account' --output text >/dev/null 2>&1
}

if ! sesion_valida; then
    cat >&2 <<'FIN'
La sesión de AWS no es válida o ha caducado.

Reinicia el laboratorio en AWS Academy, pega las credenciales nuevas en
deploy/credenciales-aws.txt y ejecuta:

    bash deploy/scripts/aws-session.sh
FIN
    exit 1
fi

case "${1:-estado}" in

estado)
    tabla
    echo
    aws_ ec2 describe-addresses \
        --query 'Addresses[].{IP:PublicIp,Instancia:InstanceId,Nombre:Tags[?Key==`Name`]|[0].Value}' \
        --output table 2>&1 || true
    ;;

apagar)
    mapfile -t IDS < <(ids_en_estado 'running,pending')
    if [[ ${#IDS[@]} -eq 0 ]]; then
        echo "No hay instancias encendidas: nada que apagar."
        tabla
        exit 0
    fi
    echo "Deteniendo ${#IDS[@]} instancia(s): ${IDS[*]}"
    aws_ ec2 stop-instances --instance-ids "${IDS[@]}" \
        --query 'StoppingInstances[].{Id:InstanceId,Antes:PreviousState.Name,Ahora:CurrentState.Name}' \
        --output table
    echo "Esperando a que estén detenidas..."
    aws_ ec2 wait instance-stopped --instance-ids "${IDS[@]}"
    echo "Detenidas."
    tabla
    ;;

encender)
    mapfile -t IDS < <(ids_en_estado 'stopped')
    if [[ ${#IDS[@]} -eq 0 ]]; then
        echo "No hay instancias detenidas: nada que encender."
        tabla
        exit 0
    fi
    echo "Arrancando ${#IDS[@]} instancia(s): ${IDS[*]}"
    aws_ ec2 start-instances --instance-ids "${IDS[@]}" \
        --query 'StartingInstances[].{Id:InstanceId,Antes:PreviousState.Name,Ahora:CurrentState.Name}' \
        --output table
    echo "Esperando a que respondan..."
    aws_ ec2 wait instance-running --instance-ids "${IDS[@]}"
    echo
    tabla
    cat <<'FIN'

Las direcciones públicas son elásticas, así que no cambian. Lo que sí hay que revisar:

  · Tu IP pública puede haber cambiado, y el puerto 22 está abierto solo a ella. Compruébalo
    con  curl -s https://checkip.amazonaws.com  y, si no coincide, autorízala en los dos
    grupos de seguridad.
  · Los contenedores arrancan solos por su política de reinicio, pero notify, mq y
    rabbitmq-init pueden quedarse atrás si el broker tarda. Levántalos con:

        ssh ubuntu@<ip-de-mq> 'cd /opt/andesstay && \
          docker compose --env-file mq.env -f infra/mq/compose.yml up -d --no-build'

    El --env-file NO es opcional: sin él las credenciales del broker quedan en blanco y los
    contenedores se recrean sin poder autenticarse contra el volumen que ya existe.
FIN
    ;;

*)
    echo "Uso: $0 {estado|apagar|encender}" >&2
    exit 2
    ;;
esac
