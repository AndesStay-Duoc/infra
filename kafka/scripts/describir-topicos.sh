#!/usr/bin/env bash
#
# Qué forma tienen los tópicos: particiones, réplicas, ISR y configuraciones efectivas.
#
# Es la evidencia de que los dos tópicos del caso están con tres particiones y tres réplicas, y
# de que cada uno lleva la política de retención que le toca. Mirar el compose no sirve: dice lo
# que se pidió, no lo que el clúster tiene.
#
# Uso:
#   ./describir-topicos.sh                      todos los tópicos del sistema
#   ./describir-topicos.sh reservations.events  solo ese
#
set -euo pipefail

BROKER="${KAFKA_BOOTSTRAP:-kafka1:29092}"
CONTENEDOR="${KAFKA_CONTENEDOR:-andesstay-kafka1}"
# Sin argumentos se describen los cuatro tópicos del sistema.
if [[ $# -gt 0 ]]; then
    TOPICOS=("$@")
else
    TOPICOS=(reservations.events audit.timeline reservations.events.DLT audit.timeline.DLT)
fi

kafka() { docker exec -i "$CONTENEDOR" "$@"; }

for t in "${TOPICOS[@]}"; do
    echo
    echo "═══ $t ═══"
    # --describe sin más da particiones, líder, réplicas e ISR. Si un ISR tiene menos de tres
    # entradas, hay un broker que no está al día y conviene saberlo antes de la demostración.
    kafka kafka-topics --describe --bootstrap-server "$BROKER" --topic "$t" || {
        echo "  (no existe)"
        continue
    }
    echo "  ── configuración ──"
    kafka kafka-configs --describe --bootstrap-server "$BROKER" \
        --entity-type topics --entity-name "$t" \
        | tr ',' '\n' | grep -E "retention|cleanup|insync|segment" || true
done
echo
