#!/usr/bin/env bash
#
# Crea o repara los tópicos del sistema.
#
# ES LA ÚNICA FUENTE DE VERDAD de la forma de los cuatro tópicos. El contenedor kafka-init del
# compose ejecuta este mismo archivo al levantar el clúster, y cualquier otro lugar que declare
# tópicos (KafkaTopicsConfig en ms-andesstay-reservations) tiene que copiar estos valores, no
# definir los suyos. La justificación de cada número está en docs/contracts/events/kafka.md.
#
# Se usa también a mano en los casos en que kafka-init no basta: un clúster que ya estaba
# levantado, un tópico borrado por error, o una instancia a la que hay que llevar la topología
# sin reiniciar nada.
#
# Es idempotente: --if-not-exists hace que crear un tópico existente no sea un error, y las
# configuraciones se aplican después con kafka-configs --alter, así que también corrige un tópico
# que se creó con la política equivocada. Ni "kafka-topics --create" ni el TopicBuilder de Spring
# tocan un tópico que ya existe; esto sí.
#
# Uso:
#   Desde el host:              bash infra/kafka/scripts/crear-topicos.sh
#   Dentro de kafka-init:       lo lanza el compose
#
set -euo pipefail

BROKER="${KAFKA_BOOTSTRAP:-kafka1:29092,kafka2:29093,kafka3:29094}"
CONTENEDOR="${KAFKA_CONTENEDOR:-andesstay-kafka1}"

# Dentro de un contenedor de Confluent las herramientas están en el PATH y se llaman directo. En
# el host no lo están, y se ejecutan dentro del broker con docker exec. Así el mismo archivo sirve
# para kafka-init y para el operador, y la tabla de abajo no se duplica nunca.
if command -v kafka-topics > /dev/null 2>&1; then
    kafka() { "$@"; }
else
    kafka() { docker exec -i "$CONTENEDOR" "$@"; }
fi

SIETE_DIAS=604800000
CATORCE_DIAS=1209600000
TREINTA_DIAS=2592000000

# nombre | particiones | réplicas | min.insync.replicas | cleanup.policy | retention.ms
#
# Las cuatro filas tienen 3 particiones y 3 réplicas porque el clúster tiene 3 brokers y los
# consumidores corren con concurrencia 3: una partición por hilo, y cada partición sobrevive a la
# caída de dos brokers sin perder datos. min.insync.replicas=2 con acks=all en los productores
# deja escribir con un broker caído y rechaza la escritura antes que confirmarla en una sola copia.
#
# Lo que cambia por flujo es la retención:
#   · reservations.events: registro de hechos recientes que alimenta reportería; 7 días y se borra.
#   · audit.timeline: historial de quién hizo qué; compact,delete conserva el último hecho de cada
#     reserva (la clave es el reservationId) y lo intermedio caduca a los 30 días.
#   · las DLT: evidencia de lo que falló; 14 días, el doble de la ventana de reservations.events,
#     para que un fallo de un viernes siga ahí después de una semana sin revisar. Se borran, no se
#     compactan: dos fallos del mismo evento son dos evidencias distintas y no deben pisarse.
TOPICOS=(
    "reservations.events|3|3|2|delete|$SIETE_DIAS"
    "audit.timeline|3|3|2|compact,delete|$TREINTA_DIAS"
    "reservations.events.DLT|3|3|2|delete|$CATORCE_DIAS"
    "audit.timeline.DLT|3|3|2|delete|$CATORCE_DIAS"
)

for fila in "${TOPICOS[@]}"; do
    IFS='|' read -r nombre particiones replicas minisr politica retencion <<< "$fila"

    echo "── $nombre ──"
    kafka kafka-topics --create --if-not-exists \
        --bootstrap-server "$BROKER" \
        --topic "$nombre" \
        --partitions "$particiones" \
        --replication-factor "$replicas"

    # Se aplican siempre, no solo al crear: así el script también endereza un tópico que ya
    # existía con otra política.
    #
    # Los corchetes no son decoración. kafka-configs separa las entradas de --add-config por
    # comas, así que "cleanup.policy=compact,delete" se leería como cleanup.policy=compact más una
    # entrada "delete" sin valor, y el comando fallaría. Entre corchetes se lee como una lista.
    kafka kafka-configs --alter \
        --bootstrap-server "$BROKER" \
        --entity-type topics --entity-name "$nombre" \
        --add-config "cleanup.policy=[$politica],retention.ms=$retencion,min.insync.replicas=$minisr"
done

echo
echo "═══ Resultado ═══"
for fila in "${TOPICOS[@]}"; do
    IFS='|' read -r nombre _ <<< "$fila"
    kafka kafka-topics --describe --bootstrap-server "$BROKER" --topic "$nombre"
done
