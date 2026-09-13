#!/usr/bin/env bash
# ============================================================
# status.cgi — État courant de la page d'appairage (GET)
# ============================================================
# Appelé en boucle par index.html (toutes les 2 s pendant une opération,
# toutes les 10 s sinon). Renvoie en JSON :
# - les enceintes déjà configurées dans l'add-on (bluetooth_mac +
#   extra_speakers) avec leur état Bluetooth (Paired/Trusted/Connected) et
#   leur décalage de synchro en cours ;
# - les groupes synchronisés configurés (2.5.0), avec leur état audio ;
# - l'opération en cours ou la dernière terminée (scan, appairage, tics) ;
# - le dernier résultat de scan.
# Ne modifie jamais rien : toutes les actions passent par action.cgi.

set -euo pipefail
# Même mode strict que run.sh (voir le commentaire en tête de run.sh).

# shellcheck source=/dev/null
source /opt/btui/lib/btui.sh

require_ingress
require_method GET

options=$(options_json)

# speaker_json <primary|extra> <mac> <nom configuré>
speaker_json() {
    bt_device_json "${2^^}" | jq -c --arg role "$1" --arg name "$3" \
        --argjson latency "$(latency_for_mac "$2")" \
        '. + {role: $role, device_name: .name, name: $name, latency_offset_ms: $latency}'
}

speakers=()
primary_mac=$(jq -r '.bluetooth_mac // ""' <<<"${options}")
if [ -n "${primary_mac}" ]; then
    speakers+=("$(speaker_json primary "${primary_mac}" "$(jq -r '.speaker_name // ""' <<<"${options}")")")
fi
while IFS=$'\t' read -r mac name; do
    if valid_mac "${mac}"; then
        speakers+=("$(speaker_json extra "${mac}" "${name}")")
    fi
done < <(jq -r '(.extra_speakers // [])[] | [.mac // "", .name // ""] | @tsv' <<<"${options}")

busy=false
if job_alive; then
    busy=true
fi

# État PulseAudio des sinks de groupe, ex: {"bab_sync_0": "SUSPENDED"}.
# "|| sync_sinks" : si pactl échoue, pipefail fait échouer le pipe même si
# jq a bien produit un objet vide.
sync_sinks=$(LC_ALL=C pactl list short sinks 2>/dev/null \
    | awk '$2 ~ /^bab_sync_/ { print $2 "\t" $NF }' \
    | jq -Rnc '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries') || sync_sinks='{}'

# --slurpfile plutôt que --argjson pour la liste des appareils : elle peut
# être longue, et un argument de commande est limité en taille.
job_file="${BTUI_JOB_FILE}"
[ -s "${job_file}" ] || job_file=/dev/null
devices_file="${BTUI_DEVICES_FILE}"
[ -s "${devices_file}" ] || devices_file=/dev/null
groups_file="${BTUI_GROUPS_FILE}"
[ -s "${groups_file}" ] || groups_file=/dev/null

# Groupes : la liste vient de la configuration (ce que l'utilisateur voit
# dans l'onglet Configuration), complétée par ce que run.sh a réellement
# démarré (groups.json) et par l'état du sink. États possibles :
# - restart : pas (encore) démarré, il faut redémarrer l'add-on ;
# - invalid : ignoré par run.sh, la raison est dans "error" ;
# - missing : démarré, mais aucune de ses enceintes n'est connectée ;
# - standby / idle / playing : sink en veille / réveillé / en lecture.
http_json "200 OK" "$(
    printf '%s\n' "${speakers[@]}" | jq -cs \
        --argjson busy "${busy}" \
        --argjson setup_mode "$([ -n "${primary_mac}" ] && echo false || echo true)" \
        --argjson options "${options}" \
        --argjson sinks "${sync_sinks}" \
        --slurpfile job "${job_file}" \
        --slurpfile devices "${devices_file}" \
        --slurpfile started_groups "${groups_file}" \
        '{
            ok: true,
            setup_mode: $setup_mode,
            busy: $busy,
            speakers: .,
            groups: [
                ($options.sync_groups // [])[]
                | . as $group
                | ([($started_groups[0] // [])[] | select(.name == $group.name)] | first) as $started
                | {
                    name: ($group.name // ""),
                    members: (($group.speakers // "") | ascii_upcase | split(",")
                        | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))),
                    error: ($started.error // null),
                    state: (
                        if $setup_mode or $started == null then "restart"
                        elif $started.sink == null then "invalid"
                        else ({RUNNING: "playing", IDLE: "idle", SUSPENDED: "standby"}[$sinks[$started.sink] // ""] // "missing")
                        end)
                }
            ],
            job: (($job[0] // null)
                | if . != null and .state == "running" and ($busy | not)
                  then .state = "error" | .message = "The operation was interrupted, try again."
                  else . end),
            devices: ($devices[0] // [])
        }'
)"
