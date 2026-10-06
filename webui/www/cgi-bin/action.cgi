#!/usr/bin/env bash
# ============================================================
# action.cgi — Actions de la page d'appairage (POST)
# ============================================================
# Reçoit un corps JSON {action, ...} et exécute une seule action :
# - scan         : recherche d'enceintes (en arrière-plan, voir btui.sh) ;
# - pair         : appairage + trust + connexion (en arrière-plan) ;
# - forget       : supprime l'appairage d'un appareil ;
# - set_primary  : enregistre l'enceinte comme enceinte principale
#                  (bluetooth_mac/speaker_name), puis redémarre l'add-on ;
# - add_extra    : l'ajoute à extra_speakers, puis redémarre l'add-on ;
# - add_group    : crée un groupe synchronisé {name, macs[]} (2.5.0), puis
#                  redémarre l'add-on ;
# - remove_group : supprime un groupe synchronisé {name}, puis redémarre ;
# - set_latency  : règle le décalage de synchro d'une enceinte {mac, ms},
#                  appliqué EN DIRECT et enregistré SANS redémarrage ;
# - test_ticks   : joue des tics de test sur un groupe {name} (en
#                  arrière-plan).
# Toute donnée venant du navigateur est validée ici avant usage : adresse
# MAC au format strict, nom sans caractère qui casserait la configuration,
# décalage borné.

set -euo pipefail
# Même mode strict que run.sh (voir le commentaire en tête de run.sh).

# shellcheck source=/dev/null
source /opt/btui/lib/btui.sh

require_ingress
require_method POST
read_json_body

action=$(jq -r '.action // ""' <<<"${BTUI_BODY}")
mac=$(jq -r '.mac // ""' <<<"${BTUI_BODY}")
mac="${mac^^}"
# Majuscules : c'est la forme qu'affiche bluetoothctl et celle qu'utilise
# PulseAudio dans le nom du sink (bluez_sink.AA_BB_...), calculé par run.sh
# directement à partir de bluetooth_mac.
name=$(jq -r '.name // ""' <<<"${BTUI_BODY}")

require_mac() {
    if ! valid_mac "${mac}"; then
        http_error "400 Bad Request" "Invalid Bluetooth MAC address."
    fi
}

require_name() {
    # Espaces en début/fin retirés.
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    if [ -z "${name}" ] || ((${#name} > 64)); then
        http_error "400 Bad Request" "The name must be 1 to 64 characters long."
    fi
    # Guillemets et antislash refusés : le nom finit entre guillemets dans
    # /etc/mpd.conf (voir mpd.conf.template, name "${SPEAKER_NAME}"), où ils
    # rendraient la configuration MPD invalide au redémarrage.
    case "${name}" in
        *\"* | *\\*)
            http_error "400 Bad Request" "The name can't contain quotes or backslashes."
            ;;
    esac
    if [[ "${name}" =~ [[:cntrl:]] ]]; then
        http_error "400 Bad Request" "The name can't contain control characters."
    fi
}

require_idle() {
    if job_alive; then
        http_error "409 Conflict" "Another Bluetooth operation is still running, wait for it to finish."
    fi
}

# apply_and_restart <nouvelles options complètes>
apply_and_restart() {
    if ! options_apply "$1"; then
        http_error "502 Bad Gateway" "The Supervisor rejected the new configuration: ${BTUI_API_ERROR}"
    fi
    http_json "200 OK" '{"ok":true,"restarting":true}'
    schedule_restart
}

case "${action}" in
    scan)
        if ! job_start scan ""; then
            http_error "409 Conflict" "Another Bluetooth operation is still running, wait for it to finish."
        fi
        http_json "200 OK" '{"ok":true}'
        ;;

    pair)
        require_mac
        if ! job_start pair "${mac}"; then
            http_error "409 Conflict" "Another Bluetooth operation is still running, wait for it to finish."
        fi
        http_json "200 OK" '{"ok":true}'
        ;;

    forget)
        require_mac
        require_idle
        bluetoothctl remove "${mac}" >/dev/null 2>&1 || true
        devices_update "${mac}"
        if bt_is_paired "${mac}"; then
            http_error "500 Internal Server Error" "Could not forget ${mac}."
        fi
        http_json "200 OK" '{"ok":true}'
        ;;

    set_primary)
        require_mac
        require_name
        require_idle
        # Remplace l'enceinte principale ; si cette enceinte était déjà
        # listée dans extra_speakers, elle en est retirée (sinon run.sh la
        # connecterait deux fois, avec deux media_player identiques) et son
        # décalage de synchro la suit.
        apply_and_restart "$(jq -c --arg mac "${mac}" --arg name "${name}" '
            (if ((.bluetooth_mac // "") | ascii_upcase) == $mac
             then (.speaker_latency_offset_ms // 0)
             else (((.extra_speakers // []) | map(select(((.mac // "") | ascii_upcase) == $mac)) | .[0].latency_offset_ms) // 0)
             end) as $latency
            | .bluetooth_mac = $mac
            | .speaker_name = $name
            | .speaker_latency_offset_ms = $latency
            | .extra_speakers = ((.extra_speakers // []) | map(select(((.mac // "") | ascii_upcase) != $mac)))
        ' <<<"$(options_current_json)")"
        ;;

    add_extra)
        require_mac
        require_name
        require_idle
        options=$(options_current_json)
        primary=$(jq -r '(.bluetooth_mac // "") | ascii_upcase' <<<"${options}")
        if [ -z "${primary}" ]; then
            # En mode configuration (bluetooth_mac vide), run.sh ignore
            # extra_speakers : l'enceinte ajoutée ne servirait à rien.
            http_error "409 Conflict" "Set a primary speaker first."
        fi
        if [ "${primary}" = "${mac}" ]; then
            http_error "409 Conflict" "This speaker is already the primary speaker."
        fi
        if jq -e --arg mac "${mac}" 'any((.extra_speakers // [])[]; (.mac | ascii_upcase) == $mac)' >/dev/null <<<"${options}"; then
            http_error "409 Conflict" "This speaker is already an extra speaker."
        fi
        apply_and_restart "$(jq -c --arg mac "${mac}" --arg name "${name}" \
            '.extra_speakers = ((.extra_speakers // []) + [{mac: $mac, name: $name}])' <<<"${options}")"
        ;;

    add_group)
        require_name
        require_idle
        options=$(options_current_json)
        if [ -z "$(jq -r '.bluetooth_mac // ""' <<<"${options}")" ]; then
            http_error "409 Conflict" "Set a primary speaker first."
        fi
        # Nom unique, sans tenir compte de la casse : run.sh ignore un
        # deuxième groupe du même nom (même UUID DLNA, donc même entité).
        if jq -e --arg name "${name}" 'any((.sync_groups // [])[]; ((.name // "") | ascii_downcase) == ($name | ascii_downcase))' >/dev/null <<<"${options}"; then
            http_error "409 Conflict" "A group with this name already exists."
        fi
        configured=$(jq -r '[(.bluetooth_mac // ""), ((.extra_speakers // [])[] | (.mac // ""))] | map(ascii_upcase | select(. != "")) | .[]' <<<"${options}")
        # Validé explicitement AVANT la boucle, plutôt que de compter sur le
        # filtre "strings" de la boucle ci-dessous pour les écarter : sans
        # ce test, un élément qui n'est pas une chaîne JSON (nombre,
        # booléen, objet) y serait silencieusement ignoré au lieu d'être
        # signalé, contrairement à toute autre entrée invalide de cette
        # action.
        if ! jq -e '(.macs // []) | (type == "array") and (all(.[]; type == "string"))' >/dev/null <<<"${BTUI_BODY}"; then
            http_error "400 Bad Request" "Invalid Bluetooth MAC address."
        fi
        members=()
        while read -r member; do
            member="${member^^}"
            if ! valid_mac "${member}"; then
                http_error "400 Bad Request" "Invalid Bluetooth MAC address."
            fi
            if ! grep -qxF "${member}" <<<"${configured}"; then
                http_error "409 Conflict" "${member} is not a speaker configured in this add-on."
            fi
            if [[ " ${members[*]} " != *" ${member} "* ]]; then
                members+=("${member}")
            fi
        done < <(jq -r '(.macs // [])[]' <<<"${BTUI_BODY}")
        if ((${#members[@]} < 2)); then
            http_error "400 Bad Request" "Pick at least two speakers for a synchronized group."
        fi
        # Même format que celui qu'on taperait dans l'onglet Configuration
        # (voir le schema de sync_groups dans config.yaml).
        speakers=$(printf '%s, ' "${members[@]}")
        apply_and_restart "$(jq -c --arg name "${name}" --arg speakers "${speakers%, }" \
            '.sync_groups = ((.sync_groups // []) + [{name: $name, speakers: $speakers}])' <<<"${options}")"
        ;;

    remove_group)
        # Pas de require_name : un groupe créé à la main dans l'onglet
        # Configuration, avec un nom que la page aurait refusé, doit quand
        # même pouvoir être supprimé d'ici. Comparaison exacte du nom.
        require_idle
        options=$(options_current_json)
        if ! jq -e --arg name "${name}" 'any((.sync_groups // [])[]; .name == $name)' >/dev/null <<<"${options}"; then
            http_error "404 Not Found" "This group is no longer in the configuration."
        fi
        apply_and_restart "$(jq -c --arg name "${name}" \
            '.sync_groups = ((.sync_groups // []) | map(select(.name != $name)))' <<<"${options}")"
        ;;

    set_latency)
        require_mac
        # Pas de require_idle : régler le décalage PENDANT les tics de test
        # (qui occupent le verrou des opérations) est justement le but.
        ms=$(jq -r '.ms | numbers | floor' <<<"${BTUI_BODY}" 2>/dev/null) || ms=""
        if ! [[ "${ms}" =~ ^-?[0-9]{1,6}$ ]]; then
            http_error "400 Bad Request" "The offset must be a number of milliseconds."
        fi
        if ((ms < 0)); then ms=0; fi
        if ((ms > BTUI_LATENCY_MAX)); then ms=${BTUI_LATENCY_MAX}; fi
        ms=$(((ms + BTUI_LATENCY_STEP / 2) / BTUI_LATENCY_STEP * BTUI_LATENCY_STEP))
        if ((ms > BTUI_LATENCY_MAX)); then ms=${BTUI_LATENCY_MAX}; fi

        options=$(options_current_json)
        if [ "$(jq -r '(.bluetooth_mac // "") | ascii_upcase' <<<"${options}")" != "${mac}" ] \
            && ! jq -e --arg mac "${mac}" 'any((.extra_speakers // [])[]; ((.mac // "") | ascii_upcase) == $mac)' >/dev/null <<<"${options}"; then
            http_error "404 Not Found" "This speaker is not configured in the add-on."
        fi
        # Enregistré d'abord : si le Supervisor refuse, rien n'a changé.
        # Sans redémarrage (options_apply seul) : le réglage doit s'entendre
        # tout de suite, pendant que les tics jouent.
        if ! options_apply "$(jq -c --arg mac "${mac}" --argjson ms "${ms}" '
            (if ((.bluetooth_mac // "") | ascii_upcase) == $mac then .speaker_latency_offset_ms = $ms else . end)
            | .extra_speakers = ((.extra_speakers // []) | map(if ((.mac // "") | ascii_upcase) == $mac then .latency_offset_ms = $ms else . end))
        ' <<<"${options}")"; then
            http_error "502 Bad Gateway" "The Supervisor rejected the new configuration: ${BTUI_API_ERROR}"
        fi
        # Fichier d'état en cours : run.sh le relit pour réappliquer le
        # décalage après une reconnexion (voir BTUI_LATENCY_FILE).
        latency_set_runtime "${mac}" "${ms}"
        applied=false
        if apply_latency_offset "${mac}" "${ms}"; then
            applied=true
        fi
        # applied=false : enceinte déconnectée, le décalage sera appliqué
        # par run.sh dès sa reconnexion.
        http_json "200 OK" "$(jq -cn --argjson ms "${ms}" --argjson applied "${applied}" '{ok: true, ms: $ms, applied: $applied}')"
        ;;

    test_ticks)
        sink=""
        if [ -s "${BTUI_GROUPS_FILE}" ]; then
            sink=$(jq -r --arg name "${name}" 'first(.[] | select(.name == $name) | .sink // empty)' "${BTUI_GROUPS_FILE}" 2>/dev/null) || sink=""
        fi
        if [ -z "${sink}" ]; then
            http_error "409 Conflict" "This group is not running: restart the add-on to start it."
        fi
        if [ -z "$(pulse_sink_state "${sink}")" ]; then
            http_error "409 Conflict" "None of this group's speakers is connected right now."
        fi
        if ! command -v gst-launch-1.0 >/dev/null 2>&1; then
            http_error "500 Internal Server Error" "gst-launch-1.0 is missing from the add-on image, check the build log."
        fi
        if ! job_start ticks "${sink}"; then
            http_error "409 Conflict" "Another operation is still running, wait for it to finish."
        fi
        http_json "200 OK" '{"ok":true}'
        ;;

    *)
        http_error "400 Bad Request" "Unknown action."
        ;;
esac
