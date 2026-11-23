#!/usr/bin/env bash
#
# Verifica que las nueve colas reciben mensajes y que ninguno se pierde.
#
# POR QUÉ EXISTE. Mirar la Management UI y ver las nueve colas en cero no prueba nada: una cola
# vacía puede estar vacía porque todo se procesó o porque nunca llegó nada. Y la columna de
# profundidad tampoco distingue un mensaje confirmado de uno perdido, porque los dos dejan la cola
# a cero. Lo que sí lo prueba son los CONTADORES ACUMULADOS del broker, y la identidad que tienen
# que cumplir entre ellos.
#
# LA IDENTIDAD QUE SE COMPRUEBA. Con acknowledge manual y sin reencolado, todo mensaje entregado a
# un consumidor acaba en exactamente uno de dos sitios: confirmado (ack) o rechazado hacia su DLQ
# (nack). El broker no publica un contador de nack, pero sí el de entregas y el de confirmaciones,
# así que el número de rechazos se deduce, y tiene que aparecer como publicaciones en la DLQ:
#
#     entregados(trabajo) - confirmados(trabajo)  ==  publicados(dlq)        [1]
#     en_cola == 0  y  sin_confirmar == 0  en las nueve                      [2]
#
# Un mensaje perdido rompe [1]: habría salido como entrega, no tendría confirmación y tampoco
# aparecería en la DLQ. Un mensaje atascado rompe [2]. Las dos juntas son la prueba, y ninguna de
# las dos se puede leer de un vistazo en la interfaz: hay que restar.
#
# Y como el script controla cuántos mensajes manda, hay una tercera más fuerte que las dos: comparar
# lo que entró con lo que el consumidor vio.
#
#     entregados(trabajo) == los 4 que esta batería manda por flujo                   [0]
#
# DOS TRAMPAS DE MEDICIÓN QUE DAN FALSOS ROJOS. Las dos salieron en la primera ejecución:
#
#   · Los acumulados de la API de gestión se agregan cada collect_statistics_interval, que son
#     5000 ms por omisión. Leerlos en cuanto las colas quedan vacías devuelve números a medias: se
#     vio una DLQ con una entrega y cero publicaciones, y una cola de trabajo con tres entregas de
#     las cuatro que de verdad había tenido. De ahí que la instantánea final espere a que pase ese
#     plazo. La profundidad --en_cola y sin_confirmar-- sí es instantánea; lo que se retrasa son los
#     totales.
#
#   · El contador publish de una cola NO cuenta las llegadas por dead-letter ni las vueltas desde la
#     cola de espera: solo lo que se publicó contra un exchange y se enrutó hasta ella. Así que las
#     llegadas a una DLQ se miden por entregas más lo que quede en cola, nunca por publicaciones, o
#     una DLQ que recibió un mensaje parece no haber recibido ninguno.
#
# LAS SEIS COLAS QUE NUNCA SE LLENAN SOLAS. Las de housekeeping y voucher solo reciben al confirmar
# una reserva, y las tres DLQ solo ante un fallo. En un entorno recién desplegado están en cero de
# forma legítima, lo que hace imposible distinguirlas de una cola mal declarada. Este script les
# manda tráfico a propósito para que dejen de estar en cero por omisión y pasen a estarlo porque
# todo lo que entró salió.
#
# POR QUÉ CUATRO CASOS POR FLUJO Y NO UNO. Un mensaje válido solo demuestra el camino feliz. Los
# otros tres cubren las ramas que es fácil tener rotas sin notarlo: que un error permanente NO gaste
# reintentos, que un duplicado se confirme sin volver a ejecutar el efecto, y que la cola de espera
# suelte el mensaje de vuelta al vencer.
#
# POR QUÉ INYECTA EN LA COLA DE ESPERA EN LUGAR DE PROVOCAR UN FALLO TRANSITORIO. El consumidor de
# housekeeping y el de voucher no tienen dependencia externa que se pueda tirar: su procesamiento
# solo escribe en el log, así que no hay forma de hacerlos fallar de forma transitoria desde fuera.
# Publicar un sobre válido directamente en la cola de espera con su propio plazo prueba lo que
# importa de esa cola --que acepta, retiene, vence y devuelve sin consumidor-- y además lo aísla:
# si el mensaje vuelve, el mecanismo de espera funciona, con independencia de por qué entró.
#
# USO
#
#     ssh -i <clave> ubuntu@<ip-del-broker> 'bash -s' < verificar-colas.sh
#     ssh ... 'bash -s' < verificar-colas.sh -- --transitorio
#
# Se ejecuta EN la máquina del broker, no desde el portátil: así la contraseña del broker se lee del
# contenedor que ya la tiene y no viaja como argumento ni queda en el historial de nadie.
#
#   --transitorio   añade el recorrido completo de reintentos del flujo de correo, apagando el
#                   servidor de correo de prueba y volviéndolo a levantar. Tarda la escalera entera
#                   y toca un contenedor, así que no entra por omisión.
#   --vhost NOMBRE  por omisión andesstay.
#
set -euo pipefail

VHOST="andesstay"
CON_TRANSITORIO=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --transitorio) CON_TRANSITORIO=1; shift ;;
        --vhost)       VHOST="${2:?Falta el nombre del vhost}"; shift 2 ;;
        -h|--help)     sed -n '2,50p' "$0"; exit 0 ;;
        *)             echo "Opción desconocida: $1" >&2; exit 2 ;;
    esac
done

FLUJOS=(email housekeeping voucher)
# Flujo:cola:routing-key del binding en cmd.direct. La routing key tiene que ser la MISMA que
# declara RabbitMQConfig: si no coincide, la publicación sale sin ruta y el script lo detecta en el
# campo "routed" de la respuesta en lugar de dar un falso verde.
declare -A COLA=( [email]=q.cmd.email [housekeeping]=q.cmd.housekeeping [voucher]=q.cmd.voucher )
declare -A RK=(   [email]=email.send  [housekeeping]=housekeeping.ticket [voucher]=voucher.gen )

TODAS=()
for f in "${FLUJOS[@]}"; do
    TODAS+=( "${COLA[$f]}" "${COLA[$f]}.retry" "${COLA[$f]}.dlq" )
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CORRIDA="verif-$(date +%s)"
API="http://localhost:15672/api"

# La escalera de esperas del servicio. Se lee del contenedor y no se da por supuesta porque de
# ella dependen tanto la duración del recorrido transitorio como el número de entregas que el
# balance tiene que esperar.
# El || true no es decorativo: printenv sale con 1 cuando la variable no existe, y dentro de una
# tubería con pipefail activo eso mata el script entero antes de imprimir una sola línea. Es lo
# que pasa hoy en la máquina, cuyo compose es anterior al que mapea NOTIFY_BACKOFF_LADDER: la
# escalera en efecto es la que trae el application.yml, o sea el valor de reserva de aquí abajo.
ESCALERA="$(docker exec andesstay-notify printenv NOTIFY_BACKOFF_LADDER 2>/dev/null | tr -d "\r" || true)"
[[ -n "$ESCALERA" ]] || ESCALERA="1000,2000,4000"
PELDANOS="$(awk -F, '{print NF}' <<<"$ESCALERA")"

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# Credenciales y utilidades
# ─────────────────────────────────────────────────────────────────────────────────────────────────

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

# Se leen del contenedor del broker, que es la única copia que esta máquina necesita tener. No se
# imprimen ni se pasan por la línea de órdenes.
entorno_broker() {
    docker inspect andesstay-rabbitmq1 --format '{{range .Config.Env}}{{println .}}{{end}}'
}
USUARIO="$(entorno_broker | sed -n 's/^RABBITMQ_DEFAULT_USER=//p')"
CLAVE="$(entorno_broker   | sed -n 's/^RABBITMQ_DEFAULT_PASS=//p')"
[[ -n "$USUARIO" && -n "$CLAVE" ]] || { echo "No se pudieron leer las credenciales del broker" >&2; exit 1; }

api() { curl -sS -u "$USUARIO:$CLAVE" "$@"; }

titulo() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()     { printf '  \033[32m✔\033[0m %s\n' "$1"; }
mal()    { printf '  \033[31m✘\033[0m %s\n' "$1"; FALLOS=$((FALLOS + 1)); }
nota()   { printf '    %s\n' "$1"; }
FALLOS=0

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# Comprobaciones previas
# ─────────────────────────────────────────────────────────────────────────────────────────────────

titulo "0 · Comprobaciones previas"

command -v jq >/dev/null || { echo "Falta jq" >&2; exit 1; }

for c in andesstay-rabbitmq1 andesstay-rabbitmq2 andesstay-notify; do
    estado="$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo ausente)"
    [[ "$estado" == "healthy" ]] && ok "$c está healthy" || mal "$c está '$estado'"
done
(( FALLOS == 0 )) || { echo; echo "Se aborta: el entorno no está en pie."; exit 1; }

# Las nueve colas tienen que existir ANTES de publicar: si falta una, la publicación se perdería sin
# ruta y el balance saldría cuadrado por el motivo equivocado.
existentes="$(api "$API/queues/$VHOST" | jq -r '.[].name' | sort)"
faltan=0
for q in "${TODAS[@]}"; do
    grep -qx "$q" <<<"$existentes" || { mal "no existe la cola $q"; faltan=1; }
done
(( faltan == 0 )) && ok "las nueve colas declaradas existen en el vhost $VHOST"

# El consumidor tiene que estar escuchando las de trabajo, y las de espera NO tienen que tenerlo:
# un consumidor en una cola de espera se comería los mensajes antes de que venzan y el reintento
# dejaría de existir sin que nada fallara.
for f in "${FLUJOS[@]}"; do
    n_trab="$(api "$API/queues/$VHOST/${COLA[$f]}"       | jq -r '.consumers // 0')"
    n_esp="$( api "$API/queues/$VHOST/${COLA[$f]}.retry" | jq -r '.consumers // 0')"
    (( n_trab >= 1 )) && ok "${COLA[$f]} tiene $n_trab consumidor(es)" \
                      || mal "${COLA[$f]} no tiene consumidor"
    (( n_esp == 0 ))  && ok "${COLA[$f]}.retry no tiene consumidor, como debe ser" \
                      || mal "${COLA[$f]}.retry tiene $n_esp consumidor(es): la espera no funcionaría"
done

(( FALLOS == 0 )) || { echo; echo "Se aborta: la topología no está como se espera."; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# Instantáneas y publicación
# ─────────────────────────────────────────────────────────────────────────────────────────────────

# name → "en_cola sin_confirmar publicados entregados confirmados"
instantanea() {
    api "$API/queues/$VHOST" | jq -r '
        .[] | [ .name,
                (.messages_ready//0), (.messages_unacknowledged//0),
                (.message_stats.publish//0), (.message_stats.deliver_get//0),
                (.message_stats.ack//0) ] | @tsv'
}

campo() { awk -v q="$2" -v c="$3" '$1==q { print $(c+1) }' "$1"; }

sobre() {
    local tipo="$1" eid="$2"
    jq -cn --arg t "$tipo" --arg e "$eid" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --argjson p "$3" \
        '{type:$t, eventId:$e, timestamp:$ts, traceId:$e, correlationId:$e,
          source:"verificar-colas", actor:{userId:"operador", role:"Admin", tenant:"andesstay"},
          payload:$p}'
}

# Publica por cmd.direct con la routing key del binding. El campo "routed" de la respuesta es la
# comprobación de que el binding existe: sin él el broker descarta el mensaje y devuelve false.
publicar() {
    local rk="$1" cuerpo="$2" etiqueta="$3"
    local ruteado
    ruteado="$(api -X POST -H 'content-type: application/json' \
        -d "$(jq -cn --arg rk "$rk" --arg p "$cuerpo" \
              '{routing_key:$rk, payload:$p, payload_encoding:"string",
                properties:{delivery_mode:2, content_type:"application/json"}}')" \
        "$API/exchanges/$VHOST/cmd.direct/publish" | jq -r '.routed')"
    [[ "$ruteado" == "true" ]] && nota "→ $etiqueta (rk=$rk)" \
                               || mal "$etiqueta: el broker no encontró ruta para rk=$rk"
}

# Publica directamente en la cola de espera, por el exchange por omisión, que mantiene un binding
# implícito a cada cola por su nombre. El plazo va como propiedad del mensaje y es una CADENA de
# milisegundos: pasarlo como número hace que el broker lo ignore y el mensaje se queda ahí para
# siempre, porque esa cola no tiene consumidor que lo saque.
inyectar_espera() {
    local cola="$1" cuerpo="$2" ms="$3" intento="$4"
    local ruteado
    ruteado="$(api -X POST -H 'content-type: application/json' \
        -d "$(jq -cn --arg rk "$cola" --arg p "$cuerpo" --arg ms "$ms" --argjson i "$intento" \
              '{routing_key:$rk, payload:$p, payload_encoding:"string",
                properties:{delivery_mode:2, content_type:"application/json", expiration:$ms,
                            headers:{"x-andesstay-intentos":$i}}}')" \
        "$API/exchanges/$VHOST/amq.default/publish" | jq -r '.routed')"
    [[ "$ruteado" == "true" ]] && nota "→ espera de ${ms} ms en $cola" \
                               || mal "no se pudo inyectar en $cola"
}

# Espera a que el broker se quede quieto. Se mira en_cola y sin_confirmar en las nueve: mientras
# alguno no sea cero hay trabajo en vuelo.
#
# Exige DOS lecturas quietas seguidas, no una. Con una sola, un mensaje que aún no ha salido de la
# cola de espera deja las nueve a cero y la función daría el reposo por bueno con trabajo todavía
# por venir.
reposar() {
    local limite="${1:-45}" i=0 quietas=0 pendiente
    while (( i < limite )); do
        pendiente="$(api "$API/queues/$VHOST" \
            | jq '[ .[] | (.messages_ready//0) + (.messages_unacknowledged//0) ] | add')"
        if [[ "$pendiente" == "0" ]]; then
            quietas=$((quietas + 1))
            (( quietas >= 2 )) && { nota "en reposo tras ${i}s"; return 0; }
        else
            quietas=0
        fi
        sleep 1; i=$((i + 1))
    done
    mal "siguen quedando $pendiente mensaje(s) en vuelo tras ${limite}s"
    return 1
}

# Espera a que el broker AGREGUE los acumulados. La profundidad de una cola es instantánea, pero
# publish, deliver_get y ack se recogen cada collect_statistics_interval --5000 ms por omisión--, y
# una instantánea tomada antes de ese plazo devuelve totales a medias. Se lee el valor real del
# broker en lugar de dar por bueno el de omisión, y se le añade un margen.
asentar() {
    local ms
    ms="$(docker exec andesstay-rabbitmq1 rabbitmqctl environment 2>/dev/null \
          | sed -n 's/.*collect_statistics_interval,\([0-9]*\)}.*/\1/p' | head -n 1)"
    [[ "$ms" =~ ^[0-9]+$ ]] || ms=5000
    local s=$(( ms / 1000 + 3 ))
    nota "esperando ${s}s a que el broker agregue los acumulados (intervalo ${ms} ms)"
    sleep "$s"
}

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# La batería
# ─────────────────────────────────────────────────────────────────────────────────────────────────

titulo "1 · Estado de partida"
reposar 30 || true
asentar
instantanea > "$TMP/antes.tsv"
ok "instantánea tomada de $(wc -l < "$TMP/antes.tsv") colas"

titulo "2 · Caso válido en los tres flujos"
for f in "${FLUJOS[@]}"; do
    eid="$CORRIDA-$f-ok"
    case "$f" in
        email)        p='{"destinatario":"operador@andesstay.cl","subject":"Verificación de colas",
                          "body":"Mensaje de la batería de verificación."}' ;;
        housekeeping) p='{"tipoTarea":"PREPARACION","unitId":1,"unidad":"Cabaña Coigüe",
                          "fechaRequerida":"2026-10-20","prioridad":"NORMAL","notas":"verificación"}' ;;
        voucher)      p='{"reservationId":1,"destinatario":"operador@andesstay.cl",
                          "tipoDocumento":"VOUCHER"}' ;;
    esac
    publicar "${RK[$f]}" "$(sobre "VERIFICACION" "$eid" "$p")" "$f válido"
done
reposar || true

titulo "3 · Duplicado: mismo eventId, el efecto no se repite"
for f in "${FLUJOS[@]}"; do
    eid="$CORRIDA-$f-ok"   # el MISMO de arriba, que es lo que lo hace duplicado
    case "$f" in
        email)        p='{"destinatario":"operador@andesstay.cl","subject":"Verificación de colas",
                          "body":"Mensaje de la batería de verificación."}' ;;
        housekeeping) p='{"tipoTarea":"PREPARACION","unitId":1,"unidad":"Cabaña Coigüe",
                          "fechaRequerida":"2026-10-20","prioridad":"NORMAL","notas":"verificación"}' ;;
        voucher)      p='{"reservationId":1,"destinatario":"operador@andesstay.cl",
                          "tipoDocumento":"VOUCHER"}' ;;
    esac
    publicar "${RK[$f]}" "$(sobre "VERIFICACION" "$eid" "$p")" "$f duplicado"
done
reposar || true

titulo "4 · Error permanente: a la DLQ sin gastar reintentos"
# Cada flujo tiene su propia forma de ser inválido de manera irreparable, y las tres se clasifican
# como permanentes en el consumidor, no en el broker.
for f in "${FLUJOS[@]}"; do
    eid="$CORRIDA-$f-perm"
    case "$f" in
        email)        p='{"destinatario":"esto no es una direccion","subject":"x","body":"y"}' ;;
        housekeeping) p='{"tipoTarea":"INVENTADA","unitId":1}' ;;
        voucher)      p='{"reservationId":1,"destinatario":"operador@andesstay.cl",
                          "tipoDocumento":"INVENTADO"}' ;;
    esac
    publicar "${RK[$f]}" "$(sobre "VERIFICACION" "$eid" "$p")" "$f permanente"
done
reposar || true

titulo "5 · Cola de espera: entra, vence y vuelve"
for f in "${FLUJOS[@]}"; do
    eid="$CORRIDA-$f-espera"
    case "$f" in
        email)        p='{"destinatario":"operador@andesstay.cl","subject":"Vuelta desde la espera",
                          "body":"Este mensaje pasó por la cola de espera."}' ;;
        housekeeping) p='{"tipoTarea":"LIMPIEZA","unitId":2,"unidad":"Cabaña Araucaria",
                          "fechaRequerida":"2026-10-21","prioridad":"ALTA","notas":"vuelta de espera"}' ;;
        voucher)      p='{"reservationId":2,"destinatario":"operador@andesstay.cl",
                          "tipoDocumento":"BOLETA"}' ;;
    esac
    inyectar_espera "${COLA[$f]}.retry" "$(sobre "VERIFICACION" "$eid" "$p")" 2000 1
done
nota "esperando el vencimiento de los tres plazos"
sleep 4
reposar || true

if (( CON_TRANSITORIO )); then
    titulo "6 · Recorrido completo de reintentos del flujo de correo"
    # El servidor de correo es la única dependencia externa que se puede tirar, así que es el único
    # fallo transitorio que se puede provocar de verdad desde fuera del servicio.
    docker stop andesstay-mailpit >/dev/null
    nota "servidor de correo detenido"
    eid="$CORRIDA-email-transitorio"
    publicar "${RK[email]}" "$(sobre "VERIFICACION" "$eid" \
        '{"destinatario":"operador@andesstay.cl","subject":"Transitorio","body":"z"}')" \
        "email transitorio"
    nota "escalera: $ESCALERA ms · $PELDANOS peldaños · $(( PELDANOS + 1 )) intentos"
    # Se muestrea la profundidad de la cola de espera una vez por peldaño, con el plazo de ese
    # peldaño más un margen: es lo que hace visible que el mensaje entra y sale tres veces, en
    # lugar de aparecer y desaparecer entre dos lecturas.
    ciclo=0
    for ms in ${ESCALERA//,/ }; do
        ciclo=$(( ciclo + 1 ))
        sleep 1
        prof="$(api "$API/queues/$VHOST/q.cmd.email.retry" | jq -r '.messages // 0')"
        nota "ciclo $ciclo de $PELDANOS · plazo ${ms} ms · q.cmd.email.retry contiene $prof"
        sleep $(( ms / 1000 + 1 ))
    done
    # Se deja que la escalera se agote del todo ANTES de levantar el correo. Levantarlo durante
    # la ventana haria que el mensaje acabara con exito, que es el OTRO escenario --el de la
    # recuperacion-- y no el que mide este: cuatro intentos y DLQ.
    nota "dejando que la escalera se agote"
    reposar 90 || true
    docker start andesstay-mailpit >/dev/null
    nota "servidor de correo levantado de nuevo"
fi

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# El balance
# ─────────────────────────────────────────────────────────────────────────────────────────────────

titulo "7 · Movimiento por cola"
asentar
instantanea > "$TMP/despues.tsv"
{
    printf 'COLA\tpublicados\tentregados\tconfirmados\tdeducidos_nack\ten_cola\tsin_confirmar\n'
    for q in "${TODAS[@]}"; do
        a_pub=$(campo "$TMP/antes.tsv"   "$q" 3); d_pub=$(campo "$TMP/despues.tsv" "$q" 3)
        a_ent=$(campo "$TMP/antes.tsv"   "$q" 4); d_ent=$(campo "$TMP/despues.tsv" "$q" 4)
        a_ack=$(campo "$TMP/antes.tsv"   "$q" 5); d_ack=$(campo "$TMP/despues.tsv" "$q" 5)
        cola=$(campo "$TMP/despues.tsv"  "$q" 1); unack=$(campo "$TMP/despues.tsv" "$q" 2)
        printf '%s\t+%d\t+%d\t+%d\t%d\t%s\t%s\n' "$q" \
            $(( d_pub - a_pub )) $(( d_ent - a_ent )) $(( d_ack - a_ack )) \
            $(( (d_ent - a_ent) - (d_ack - a_ack) )) "$cola" "$unack"
    done
} | column -t -s $'\t'

titulo "8 · Las identidades"

delta() { echo $(( $(campo "$TMP/despues.tsv" "$1" "$2") - $(campo "$TMP/antes.tsv" "$1" "$2") )); }

# Cuántos mensajes manda esta batería a cada cola de trabajo: el válido, el duplicado, el permanente
# y la vuelta desde la cola de espera.
ESPERADOS=4
ESPERADOS_EMAIL=$ESPERADOS
# El recorrido transitorio añade UN mensaje al flujo de correo, pero no UNA entrega: se entrega
# una vez por intento, y los intentos son los peldaños de la escalera más uno. Con 1000,2000,4000
# son cuatro entregas, de las que TRES acaban en confirmación --publica en la espera y confirma--
# y solo la cuarta en rechazo hacia la DLQ. Por eso la identidad [1] sigue cuadrando: 8 entregas
# menos 6 confirmaciones son los 2 rechazos que la DLQ recibe.
if (( CON_TRANSITORIO )); then
    ESPERADOS_EMAIL=$(( ESPERADOS + PELDANOS + 1 ))
fi

# [0] Lo que entró es lo que el consumidor vio. Es la comprobación directa de que no se perdió nada:
#     el script sabe cuántos mandó, así que una entrega de menos es un mensaje que se evaporó entre
#     el exchange y el consumidor.
for f in "${FLUJOS[@]}"; do
    q="${COLA[$f]}"
    [[ "$f" == email ]] && n=$ESPERADOS_EMAIL || n=$ESPERADOS
    vistos="$(delta "$q" 4)"
    if (( vistos == n )); then
        ok "$q: se mandaron $n y el consumidor recibió $vistos"
    else
        mal "$q: se mandaron $n pero el consumidor recibió $vistos"
    fi
done

# [1] Lo que se entregó y no se confirmó tiene que estar en la DLQ. Es la misma conservación vista
#     desde el otro lado, y la que seguiría valiendo si el tráfico no lo generara este script.
#
#     Las llegadas a la DLQ se miden por ENTREGAS más lo que quede en cola, no por publicaciones: un
#     mensaje que llega por dead-letter no incrementa el publish de la cola destino.
for f in "${FLUJOS[@]}"; do
    q="${COLA[$f]}"
    rechazados=$(( $(delta "$q" 4) - $(delta "$q" 5) ))
    en_dlq=$(( $(delta "$q.dlq" 4) + $(campo "$TMP/despues.tsv" "$q.dlq" 1) ))
    if (( rechazados == en_dlq )); then
        ok "$q: $rechazados rechazo(s) y $en_dlq llegada(s) a la DLQ — cuadra"
    else
        mal "$q: $rechazados rechazo(s) pero $en_dlq llegada(s) a la DLQ — falta cuadrar $(( rechazados - en_dlq ))"
    fi
done

# [2] Nada atascado en ninguna de las nueve.
atascadas=0
for q in "${TODAS[@]}"; do
    c=$(campo "$TMP/despues.tsv" "$q" 1); u=$(campo "$TMP/despues.tsv" "$q" 2)
    (( c == 0 && u == 0 )) || { mal "$q quedó con $c en cola y $u sin confirmar"; atascadas=1; }
done
(( atascadas == 0 )) && ok "las nueve colas quedaron en cero, sin mensajes atascados ni sin confirmar"

# La cola de espera no debe haber entregado NADA a nadie: los mensajes salen por vencimiento, no
# por consumo. Una entrega ahí significa que alguien se suscribió y el reintento se habría comido.
for f in "${FLUJOS[@]}"; do
    q="${COLA[$f]}.retry"
    ent="$(delta "$q" 4)"
    pub="$(delta "$q" 3)"
    if (( pub > 0 && ent == 0 )); then
        ok "$q: $pub entrada(s) y 0 entregas — salieron por vencimiento, como se diseñó"
    elif (( ent > 0 )); then
        mal "$q entregó $ent mensaje(s) a un consumidor: la espera no se está respetando"
    else
        mal "$q no recibió nada: la inyección no llegó"
    fi
done

titulo "9 · El actuator de notify esta protegido"

# POR QUE AQUI NO SE LEEN LAS METRICAS. Las métricas del servicio están detrás de hasRole("Admin"),
# así que leerlas exigiría un token de Entra que este script no puede emitir. Tampoco hace falta:
# toda la contabilidad de las secciones 7 y 8 sale de los contadores del BROKER, no de notify, de
# modo que la prueba de que no se pierde ningún mensaje no depende del servicio que se está
# probando. Eso es deliberado y es mejor así.
#
# Lo que sí se comprueba es que la protección está puesta, que es una propiedad de corrección por
# derecho propio. Antes este paso leía las métricas sin token: desde que se protegieron, imprimía
# "ausente" tres veces y aparentaba comprobar algo que ya no comprobaba.
#
# La imagen de notify no trae curl, solo el wget de busybox, y su actuator escucha en 8085: es el
# mismo par que usa su healthcheck del compose. Se pide el código de estado, no el cuerpo.
codigo_notify() {
    docker exec andesstay-notify sh -c \
        "wget -S -q -O /dev/null http://127.0.0.1:8085$1 2>&1 | sed -n 's|.*HTTP/1.[01] \\([0-9]*\\).*|\\1|p' | head -n 1" \
        2>/dev/null || true
}

salud="$(codigo_notify /actuator/health)"
[[ "$salud" == "200" ]] && ok "/actuator/health responde 200 sin token, como debe" \
                        || mal "/actuator/health devolvio '$salud', se esperaba 200"

metricas="$(codigo_notify /actuator/metrics/notify.messages.processed)"
case "$metricas" in
    401|403) ok "/actuator/metrics exige autenticacion (devolvio $metricas)" ;;
    200)     mal "/actuator/metrics responde 200 SIN token: la proteccion no esta puesta" ;;
    *)       mal "/actuator/metrics devolvio '$metricas', se esperaba 401 o 403" ;;
esac

nota "los contadores de mensajes de las secciones 7 y 8 vienen del broker, no de notify"

titulo "Resultado"
if (( FALLOS == 0 )); then
    printf '  \033[32mLas nueve colas recibieron tráfico y el balance cuadra: no se perdió ningún mensaje.\033[0m\n\n'
    exit 0
fi
printf '  \033[31m%d comprobación(es) fallaron.\033[0m\n\n' "$FALLOS"
exit 1
