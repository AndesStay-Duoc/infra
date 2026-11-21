#!/usr/bin/env bash
#
# Crea o repara los tópicos del sistema.
#
# El contenedor kafka-init del compose ya lo hace al levantar el clúster. Este script existe para
# los casos en que eso no basta: un clúster que ya estaba levantado, un tópico borrado por error,
# o una instancia a la que hay que llevar la topología sin reiniciar nada.
#
# Es idempotente: --if-not-exists hace que crear un tópico existente no sea un error, y las
# configuraciones se aplican después con kafka-configs, así que también corrige un tópico que se
# creó con la política equivocada.
#
set -euo pipefail

BROKER="${KAFKA_BOOTSTRAP:-kafka1:29092}"
CONTENEDOR="${KAFKA_CONTENEDOR:-andesstay-kafka1}"

PARTICIONES=3
REPLICAS=3

SIETE_DIAS=604800000
TREINTA_DIAS=2592000000
CATORCE_DIAS=1209600000

kafka() { docker exec -i "$CONTENEDOR" "$@"; }

# nombre · cleanup.policy · retention.ms
TOPICOS=(
    "reservations.events|delete|$SIETE_DIAS"
    "audit.timeline|compact,delete|$TREINTA_DIAS"
    "reservations.events.DLT|delete|$CATORCE_DIAS"
    "audit.timeline.DLT|delete|$CATORCE_DIAS"
)

for fila in "${TOPICOS[@]}"; do
    IFS='|' read -r nombre politica retencion <<< "$fila"

    echo "── $nombre ──"
    kafka kafka-topics --create --if-not-exists \
        --bootstrap-server "$BROKER" \
        --topic "$nombre" \
        --partitions "$PARTICIONES" \
        --replication-factor "$REPLICAS"

    # Se aplican siempre, no solo al crear: así el script también endereza un tópico que ya
    # existía con otra política.
    kafka kafka-configs --alter \
        --bootstrap-server "$BROKER" \
        --entity-type topics --entity-name "$nombre" \
        --add-config "cleanup.policy=$politica,retention.ms=$retencion"
done

echo
echo "═══ Resultado ═══"
kafka kafka-topics --describe --bootstrap-server "$BROKER"
