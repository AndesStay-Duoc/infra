#!/usr/bin/env bash
#
# Quién está consumiendo, por dónde va y cuánto le falta.
#
# El lag es la diferencia entre el último offset del tópico y el que el grupo ha confirmado: dice
# si el consumo va al día o se está quedando atrás. Es lo que se mira cuando el sistema parece
# lento y no se sabe si el problema es el productor o el consumidor.
#
# La columna CONSUMER-ID muestra además cómo se reparten las particiones: con tres instancias del
# mismo grupo y un tópico de tres particiones, cada una debería tener la suya.
#
# Uso:
#   ./inspeccionar-grupos.sh                      todos los grupos
#   ./inspeccionar-grupos.sh report-consumer-group solo ese
#
set -euo pipefail

BROKER="${KAFKA_BOOTSTRAP:-kafka1:29092}"
CONTENEDOR="${KAFKA_CONTENEDOR:-andesstay-kafka1}"

kafka() { docker exec -i "$CONTENEDOR" "$@"; }

if [[ $# -gt 0 ]]; then
    GRUPOS=("$@")
else
    echo "═══ Grupos del clúster ═══"
    kafka kafka-consumer-groups --bootstrap-server "$BROKER" --list
    mapfile -t GRUPOS < <(kafka kafka-consumer-groups --bootstrap-server "$BROKER" --list | tr -d '\r')
fi

for g in "${GRUPOS[@]}"; do
    [[ -z "$g" ]] && continue
    echo
    echo "═══ $g ═══"
    kafka kafka-consumer-groups --bootstrap-server "$BROKER" --describe --group "$g" || true

    total=$(kafka kafka-consumer-groups --bootstrap-server "$BROKER" --describe --group "$g" 2>/dev/null \
        | awk 'NR>1 && $6 ~ /^[0-9]+$/ { s += $6 } END { print s+0 }')
    echo "  ── lag total: ${total:-0} ──"
done
echo
