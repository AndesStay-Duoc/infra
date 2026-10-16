#!/usr/bin/env bash
#
# Genera carga sostenida sobre las colas para que la Management UI tenga algo que mostrar.
#
# POR QUÉ EXISTE, Y POR QUÉ NO BASTA verificar-colas.sh. Ese script publica trece mensajes y espera
# a que las colas queden quietas para restar contadores: es una medición, y está bien que termine en
# segundos. Pero deja todo en cero, así que quien abra el panel después no ve nada en movimiento y
# concluye que no pasó nada. Son dos necesidades distintas: una comprueba, la otra se mira.
#
# QUÉ MUESTRA CADA MODO. Lo que el panel puede enseñar depende de si el consumidor va más rápido
# que el productor, y eso es justo lo que separa los dos modos:
#
#   sostenida  Publica a ritmo constante con los consumidores en marcha. La PROFUNDIDAD apenas se
#              mueve --el consumidor despacha cada mensaje en milisegundos-- y lo que se ve son las
#              TASAS de la pestaña Overview: publish, deliver y ack subiendo juntas. Es el modo que
#              demuestra que el sistema procesa de forma continua.
#
#   acumular   Detiene notify ANTES de publicar. Sin consumidor, los mensajes se quedan en las colas
#              de trabajo y la columna Ready crece a la vista. Al terminar levanta notify y se ve el
#              vaciado de golpe. Es el modo que hace interesante la pestaña Queues, y además
#              demuestra algo que importa: que un consumidor caído no pierde mensajes, los acumula.
#
# LO QUE NINGÚN MODO PUEDE MOSTRAR, y conviene saberlo antes de buscarlo en el panel: la
# profundidad de una DLQ. DeadLetterConsumer confirma cada mensaje que llega, así que las tres DLQ
# vuelven a cero de inmediato y no hay forma de abrir un mensaje en cuarentena para leerle las
# cabeceras. Esa evidencia --x-andesstay-intentos y x-death-- está en el LOG de notify, que las
# imprime al registrar la cuarentena:
#
#     docker logs andesstay-notify | grep '\[DLQ\]'
#
# El panel sirve para ver el flujo; el log, para ver el contenido de un mensaje concreto.
#
# USO
#
#     ssh -i <clave> ubuntu@<ip-del-broker> 'bash -s' < carga-colas.sh
#     ssh ... 'bash -s' < carga-colas.sh -- --modo acumular --duracion 45
#
#   --modo sostenida|acumular   por omisión sostenida
#   --duracion SEGUNDOS         por omisión 60
#   --tasa MENSAJES_POR_SEGUNDO por omisión 5, repartidos entre los tres flujos
#   --vhost NOMBRE              por omisión andesstay
#
set -euo pipefail

MODO="sostenida"
DURACION=60
TASA=5
VHOST="andesstay"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --modo)     MODO="${2:?Falta el modo}"; shift 2 ;;
        --duracion) DURACION="${2:?Faltan los segundos}"; shift 2 ;;
        --tasa)     TASA="${2:?Faltan los mensajes por segundo}"; shift 2 ;;
        --vhost)    VHOST="${2:?Falta el vhost}"; shift 2 ;;
        -h|--help)  sed -n '2,40p' "$0" 2>/dev/null || true; exit 0 ;;
        *)          echo "Opción desconocida: $1" >&2; exit 2 ;;
    esac
done

[[ "$MODO" == "sostenida" || "$MODO" == "acumular" ]] || { echo "--modo admite 'sostenida' o 'acumular'" >&2; exit 2; }
[[ "$DURACION" =~ ^[0-9]+$ && "$DURACION" -gt 0 ]] || { echo "--duracion debe ser un entero positivo" >&2; exit 2; }
[[ "$TASA" =~ ^[0-9]+$ && "$TASA" -gt 0 ]] || { echo "--tasa debe ser un entero positivo" >&2; exit 2; }

command -v jq >/dev/null || { echo "Falta jq" >&2; exit 1; }

API="http://localhost:15672/api"
FLUJOS=(email housekeeping voucher)
declare -A RK=( [email]=email.send [housekeeping]=housekeeping.ticket [voucher]=voucher.gen )
declare -A COLA=( [email]=q.cmd.email [housekeeping]=q.cmd.housekeeping [voucher]=q.cmd.voucher )

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# Dónde se ejecuta esto
# ─────────────────────────────────────────────────────────────────────────────────────────────────
#
# Este script corre EN la máquina del broker, no en el equipo del operador: lee la contraseña del
# contenedor que ya la tiene, para que no viaje como argumento ni quede en el historial de nadie.
#
# La comprobación mira si el nodo del broker está CORRIENDO aquí. No basta con que el contenedor
# exista: el equipo del operador puede tener uno local de desarrollo, detenido, con el mismo nombre
# que el de la instancia, y entonces cualquier comprobación por nombre a secas da un falso
# positivo. Comprobar si existe `docker` sirve aún menos: un equipo con Docker Desktop lo tiene.
if ! docker inspect -f '{{.State.Running}}' andesstay-rabbitmq1 2>/dev/null | grep -qx true; then
    if docker inspect andesstay-rabbitmq1 > /dev/null 2>&1; then
        cat >&2 <<'FIN'

Aquí hay un contenedor andesstay-rabbitmq1, pero está DETENIDO.

Si querías comprobar el entorno desplegado en AWS, este script va en su máquina:

    ssh -i ~/.ssh/<clave>.pem ubuntu@<ip-de-ec2-mq> 'bash -s' < <este-script>

Si querías comprobar tu broker local, levántalo primero:

    docker compose --env-file mq.env -f infra/mq/compose.yml up -d

FIN
    else
        cat >&2 <<'FIN'

Este script se ejecuta EN la máquina del broker, y aquí no está el contenedor andesstay-rabbitmq1.

Lánzalo así, desde el equipo del operador:

    ssh -i ~/.ssh/<clave>.pem ubuntu@<ip-de-ec2-mq> 'bash -s' < <este-script>

El guion se envía por la entrada estándar y se ejecuta allá, que es donde viven el broker, sus
credenciales y las herramientas que necesita.

FIN
    fi
    exit 1
fi

# Las credenciales se leen del contenedor del broker: no viajan como argumento ni quedan en el
# historial de nadie.
entorno() { docker inspect andesstay-rabbitmq1 --format '{{range .Config.Env}}{{println .}}{{end}}'; }
USUARIO="$(entorno | sed -n 's/^RABBITMQ_DEFAULT_USER=//p')"
CLAVE="$(entorno   | sed -n 's/^RABBITMQ_DEFAULT_PASS=//p')"
[[ -n "$USUARIO" && -n "$CLAVE" ]] || { echo "No se pudieron leer las credenciales del broker" >&2; exit 1; }

api() { curl -sS -u "$USUARIO:$CLAVE" "$@"; }

titulo() { printf '\n\033[1m%s\033[0m\n' "$1"; }
nota()   { printf '    %s\n' "$1"; }

sobre() {
    local flujo="$1" n="$2"
    local payload
    case "$flujo" in
        email)        payload=$(jq -cn --arg n "$n" '{destinatario:"carga@andesstay.cl",
                          subject:("Carga de prueba " + $n), body:"Mensaje del generador de carga."}') ;;
        housekeeping) payload=$(jq -cn '{tipoTarea:"PREPARACION", unitId:1, unidad:"Cabaña Coigüe",
                          fechaRequerida:"2026-11-01", prioridad:"NORMAL", notas:"carga"}') ;;
        voucher)      payload=$(jq -cn '{reservationId:1, destinatario:"carga@andesstay.cl",
                          tipoDocumento:"VOUCHER"}') ;;
    esac
    # Cada mensaje lleva un eventId único: con uno repetido, la idempotencia los trataría como
    # duplicados y el panel mostraría confirmaciones sin trabajo real detrás.
    jq -cn --arg e "carga-$(date +%s)-$flujo-$n" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --argjson p "$payload" \
        '{type:"CARGA", eventId:$e, timestamp:$ts, traceId:$e, correlationId:$e,
          source:"carga-colas", actor:{userId:"generador", role:"Admin", tenant:"andesstay"},
          payload:$p}'
}

publicar() {
    local rk="$1" cuerpo="$2"
    api -X POST -H 'content-type: application/json' \
        -d "$(jq -cn --arg rk "$rk" --arg p "$cuerpo" \
              '{routing_key:$rk, payload:$p, payload_encoding:"string",
                properties:{delivery_mode:2, content_type:"application/json"}}')" \
        "$API/exchanges/$VHOST/cmd.direct/publish" | jq -r '.routed'
}

profundidades() {
    api "$API/queues/$VHOST" \
        | jq -r '[ .[] | select(.name | endswith(".retry") or endswith(".dlq") | not)
                   | "\(.name | sub("^q\\.cmd\\."; ""))=\(.messages // 0)" ] | join("  ")'
}

# ─────────────────────────────────────────────────────────────────────────────────────────────────

titulo "Generador de carga · modo $MODO · ${DURACION}s a ${TASA} msg/s"
nota "abre http://localhost:15672 por el túnel y pon el refresco en 1 segundo"

if [[ "$MODO" == "acumular" ]]; then
    titulo "Deteniendo notify para que los mensajes se acumulen"
    docker stop andesstay-notify >/dev/null
    nota "notify detenido · las colas de trabajo ya no tienen consumidor"
    # Se restablece aunque el script se interrumpa: dejar el consumidor apagado sería dejar el
    # entorno peor de como se encontró.
    trap 'echo; echo "Levantando notify..."; docker start andesstay-notify >/dev/null 2>&1 || true' EXIT
fi

titulo "Publicando"
enviados=0
fallidos=0
fin=$(( $(date +%s) + DURACION ))

while [[ $(date +%s) -lt $fin ]]; do
    for (( i = 0; i < TASA; i++ )); do
        flujo="${FLUJOS[$(( (enviados + i) % 3 ))]}"
        if [[ "$(publicar "${RK[$flujo]}" "$(sobre "$flujo" "$enviados")" )" == "true" ]]; then
            enviados=$(( enviados + 1 ))
        else
            fallidos=$(( fallidos + 1 ))
        fi
    done
    printf '\r    enviados=%-6d fallidos=%-4d  profundidad: %s' \
        "$enviados" "$fallidos" "$(profundidades)"
    sleep 1
done
echo

titulo "Resumen"
nota "mensajes publicados: $enviados"
[[ "$fallidos" -gt 0 ]] && nota "sin ruta (revisa los bindings): $fallidos"
nota "profundidad final: $(profundidades)"

if [[ "$MODO" == "acumular" ]]; then
    titulo "Levantando notify · mira cómo se vacían"
    trap - EXIT
    docker start andesstay-notify >/dev/null
    for _ in $(seq 1 20); do
        printf '\r    profundidad: %-60s' "$(profundidades)"
        sleep 1
    done
    echo
    nota "vaciadas sin perder ninguno: un consumidor caído acumula, no descarta"
fi

titulo "Dónde mirar"
nota "Overview → las gráficas de publish, deliver y ack guardan el histórico reciente"
nota "Queues   → la columna Ready es la profundidad instantánea"
nota "las cabeceras de un mensaje en cuarentena NO se ven en el panel: están en el log"
nota "  docker logs andesstay-notify | grep '\\[DLQ\\]'"
