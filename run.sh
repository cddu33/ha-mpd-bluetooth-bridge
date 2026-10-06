#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
# (ce shebang n'est pas reconnu par shellcheck : la directive ci-dessus lui
# dit d'analyser le reste du fichier comme du bash, sans quoi tout le
# fichier remontait une seule erreur SC1008 "shebang non reconnu" au lieu
# des vrais diagnostics.)
# ============================================================
# run.sh — Script de démarrage de l'add-on
# ============================================================
# Rôle : préparer la config MPD avec le bon sink Bluetooth, s'assurer
# que l'enceinte configurée est connectée, puis lancer MPD. Une boucle
# de fond surveille la connexion Bluetooth et la rétablit automatiquement
# si l'enceinte se déconnecte (mise en veille, coupure, etc.).
#
# La ligne "#!/usr/bin/with-contenv bashio" (au lieu d'un simple bash)
# permet d'utiliser directement les fonctions "bashio::..." fournies
# par l'image de base des add-ons Home Assistant, notamment pour lire
# les options définies dans config.yaml.

set -euo pipefail
# -e : arrête immédiatement le script si une commande échoue de façon
# inattendue (évite de continuer dans un état incohérent).
# -u : arrête le script si une variable non définie est utilisée.
# -o pipefail : dans un pipe (cmd1 | cmd2), remonte l'échec de cmd1 même
# si cmd2 réussit (sans ça, seul le code de sortie de cmd2 compte).
# Suggéré par un lecteur sur le forum officiel HA (2026-08-22) ; vérifié
# avant application que bashio active déjà ces trois options en interne
# (voir lib/bashio sur github.com/hassio-addons/bashio) et qu'aucune
# variable de ce script n'est lue avant d'être assignée.

# shellcheck source=/dev/null
source /opt/btui/lib/btui.sh
mkdir -p "${BTUI_STATE_DIR}"
# Fonctions partagées avec la page d'appairage (2.5.0) : noms des sinks et
# cartes PulseAudio, décalage de synchro, fichiers d'état de /tmp/btui
# (groupes démarrés, décalages en cours). Une seule définition pour les
# deux, plutôt que deux copies qui finiraient par diverger. Charger ce
# fichier ne lance rien (constantes et fonctions, plus une valeur par
# défaut de PULSE_SERVER, voir btui.sh).

mkdir -p /var/lib/mpd/playlists /var/lib/mpd/music
# Recréé au démarrage du conteneur (pas seulement à la construction de
# l'image) : sur le premier essai, MPD plantait avec "Failed to open
# '/var/lib/mpd/database': No such file or directory" — ces dossiers
# doivent exister au moment où MPD démarre, pas seulement au moment du
# build de l'image (un volume ou une réinitialisation du système de
# fichiers du conteneur peut repartir de zéro).

# --- 1. Lecture de la configuration utilisateur ---
BT_MAC=$(bashio::config 'bluetooth_mac')
# Adresse MAC de l'enceinte, saisie par l'utilisateur dans l'onglet
# "Configuration" de l'add-on (ex: AA:BB:CC:DD:EE:FF), ou écrite
# automatiquement par la page d'appairage (2.4.0, voir étape 1ter). Peut
# être vide depuis 2.4.0 (première installation, avant tout appairage) :
# voir le mode configuration, étape 1quater.

SPEAKER_NAME=$(sanitize_conf_string "$(bashio::config 'speaker_name')")
# Nom cosmétique de l'enceinte, affiché côté MPD (n'affecte pas le
# fonctionnement). Par défaut "Bluetooth Speaker" si non renseigné.
# Filtré avec sanitize_conf_string (btui.sh) avant même d'être assigné :
# speaker_name a le schema libre "str" dans config.yaml (contrairement à un
# nom posé depuis la page d'appairage, voir require_name dans action.cgi),
# et sert plus bas à envsubst pour générer mpd.conf (étape 3) — un "\"" ou
# un retour à la ligne non filtré y casserait la directive `name "..."`
# générée, voire y injecterait des lignes de configuration.

RECONNECT_INTERVAL=$(bashio::config 'reconnect_interval')
# Intervalle (en secondes) entre deux vérifications de la connexion
# Bluetooth par la boucle de surveillance (voir étape 5). Par défaut 30s.

ENABLE_MPD=$(bashio::config 'enable_mpd')
# Par défaut true (voir config.yaml) : préserve le chemin MPD/Music
# Assistant existant. La connexion Bluetooth (étapes 1 à 4bis) reste
# nécessaire dans tous les cas — seule la génération de mpd.conf et le
# lancement de MPD (étapes 3 et 6) sont conditionnés par cette option.

DEFAULT_VOLUME=$(bashio::config 'default_volume')
# Volume (%) restauré automatiquement si le sink PulseAudio de l'enceinte
# est détecté muet ou à 0% (voir ensure_audio_sink, étape 4bis). Par défaut
# 70 (voir config.yaml).

MPD_PASSWORD_DIRECTIVE=""
if bashio::config.has_value 'mpd_password'; then
    # shellcheck disable=SC2089
    # (faux positif : cette variable est un texte de données écrit tel
    # quel dans mpd.conf par envsubst, pas une commande/un argument shell
    # réinterprété plus loin — les guillemets qu'elle contient n'y sont
    # jamais ni perdus ni ré-évalués.)
    MPD_PASSWORD_DIRECTIVE="password \"$(sanitize_conf_string "$(bashio::config 'mpd_password')" | tr -d '@')@read,add,control,admin\""
fi
# Vide par défaut (mpd_password non renseigné) : aucune ligne ajoutée à
# mpd.conf, comportement inchangé (voir mpd.conf.template, étape 3).
# Filtrée comme SPEAKER_NAME ci-dessous (sanitize_conf_string) avant
# d'être écrite dans mpd.conf, PLUS le "@" retiré en plus : MPD lit le
# texte après le DERNIER "@" de la ligne comme la liste de permissions
# (ici "read,add,control,admin", accès complet, pas de rôles séparés dans
# cette version) — un "@" laissé dans le mot de passe lui-même romprait
# ce découpage.

RENDERER_VOLUME=100
if bashio::config.has_value 'renderer_volume'; then
    RENDERER_VOLUME=$(bashio::config 'renderer_volume')
fi
RENDERER_INITIAL_DB=$(awk -v v="${RENDERER_VOLUME}" 'BEGIN { printf "%.2f", (v - 100) * 0.4 }')
# Volume de départ de chaque renderer DLNA, en décibels. Sans cette option,
# gmediarender démarre à 0 dB (curseur à 100) et, depuis 2.4.1, il est
# relancé à chaque reconnexion de l'enceinte : le volume repartait donc à
# 100 à chaque fois (GitHub issue #9). L'échelle UPnP de gmediarender est
# de 0,4 dB par graduation (curseur 80 = -8 dB, mesuré sur le Pi le
# 2026-10-04) : ce calcul place donc le curseur de Home Assistant
# exactement sur renderer_volume. Valeur par défaut 100 = 0.00 dB, donc
# l'ancien comportement exact : option facultative dans le schema, et
# repli à 100 si une configuration existante ne la contient pas. Distinct
# de default_volume (sink PulseAudio), volontairement : réutiliser
# default_volume (70 par défaut) aurait rendu tout le monde nettement moins
# fort après la mise à jour.

# --- 1ter. Page d'appairage Bluetooth (ingress, 2.4.0) ---
# Petit serveur web (httpd de busybox-extras) qui sert la page ouverte
# depuis le panneau "Bluetooth Audio" de Home Assistant (voir webui/) :
# scan, appairage, et choix de l'enceinte écrit directement dans la
# configuration de l'add-on. Lancé AVANT toute connexion Bluetooth et même
# sans enceinte configurée : c'est justement cette page qui permet d'en
# appairer une sans terminal.
#
# Sécurité — le point le plus important de cette étape : l'add-on tourne
# en host_network (voir config.yaml), donc écouter sur 0.0.0.0 exposerait
# cette page, sans aucune authentification, à tout le réseau local. On
# écoute donc UNIQUEMENT sur l'adresse interne par laquelle le Supervisor
# joint l'add-on (en host_network, bashio::addon.ip_address renvoie la
# passerelle du réseau interne hassio), sur le port attribué par le
# Supervisor (ingress_port: 0 dans config.yaml). httpd.conf n'accepte en
# plus que le proxy ingress lui-même (172.30.32.2). Côté navigateur, on
# passe par la session Home Assistant (panneau réservé aux administrateurs).
INGRESS_IP=$(bashio::addon.ip_address) || INGRESS_IP=""
INGRESS_PORT=$(bashio::addon.ingress_port) || INGRESS_PORT=""
if bashio::var.has_value "${INGRESS_IP}" && bashio::var.has_value "${INGRESS_PORT}"; then
    mkdir -p /tmp/btui
    bashio::log.info "Starting the pairing web UI on ${INGRESS_IP}:${INGRESS_PORT} (Home Assistant ingress only)..."
    busybox-extras httpd -f -p "${INGRESS_IP}:${INGRESS_PORT}" -h /opt/btui/www -c /opt/btui/httpd.conf &
    # "-f" (premier plan) + "&" : même principe que gmediarender plus bas,
    # le processus reste un enfant du conteneur au lieu de se détacher.
else
    # Jamais bloquant : sans page d'appairage, le pont audio lui-même
    # (connexion, MPD, media_player) doit continuer de fonctionner
    # exactement comme avant pour une enceinte déjà configurée.
    bashio::log.error "Could not read the ingress address/port from the Supervisor: pairing web UI not started." || true
fi

# httpd a déjà été lancé (ou non) ci-dessus avec SUPERVISOR_TOKEN dans son
# environnement : c'est ce qui permet à chaque CGI qu'il lance par requête
# de parler au Supervisor (voir action.cgi, qui le capture puis le retire
# à son tour). Ce script-ci, en revanche, n'appelle jamais l'API du
# Supervisor lui-même : on le retire donc maintenant de SON environnement,
# pour qu'il n'atterrisse pas, sans raison, dans celui de bluetoothctl,
# pactl, gmediarender ou mpd lancés plus loin.
unset SUPERVISOR_TOKEN

# --- 1quater. Mode configuration (aucune enceinte choisie, 2.4.0) ---
# bluetooth_mac peut désormais rester vide (voir schema dans config.yaml) :
# c'est l'état d'une première installation, avant d'avoir appairé une
# enceinte depuis la page ci-dessus. Tout ce qui suit (sink PulseAudio,
# MPD, gmediarender, boucles de surveillance) n'a aucun sens sans
# enceinte : on s'arrête là, en gardant le conteneur (et donc la page
# d'appairage) en vie. extra_speakers est ignoré dans ce mode. Choisir une
# enceinte depuis la page écrit la configuration puis redémarre l'add-on,
# qui repasse alors par le chemin normal ci-dessous.
# bashio::config.has_value plutôt qu'un test sur ${BT_MAC} : si l'option
# est carrément retirée de la configuration (champ facultatif vidé dans
# l'interface de Home Assistant), bashio::config renvoie la chaîne "null"
# et non une chaîne vide (vérifié dans lib/config.sh de bashio) — un test
# sur ${BT_MAC} laisserait alors passer une adresse "null".
if ! bashio::config.has_value 'bluetooth_mac'; then
    bashio::log.warning "No speaker configured yet (bluetooth_mac is empty): open the \"Bluetooth Audio\" panel in the Home Assistant sidebar to scan for, pair and select a speaker."
    exec tail -f /dev/null
fi

bashio::log.info "Target speaker: ${SPEAKER_NAME} (${BT_MAC})"

# --- 1bis. Enceintes supplémentaires (multi-enceintes, 2.3.0) ---
# `extra_speakers` est une liste optionnelle d'objets {mac, name} (voir
# config.yaml) — vide par défaut, donc ce bloc ne change rien pour qui ne
# l'utilise pas. On construit un tableau SPEAKERS_MAC[]/SPEAKERS_NAME[] qui
# commence TOUJOURS par la "première" enceinte historique (bluetooth_mac/
# speaker_name), pour que l'indice 0 reste celle utilisée par MPD plus bas
# (étape 3/6) sans rien changer à ce chemin existant.
SPEAKERS_MAC=("${BT_MAC}")
SPEAKERS_NAME=("${SPEAKER_NAME}")
SPEAKERS_LATENCY=("$(bashio::config 'speaker_latency_offset_ms' 0)")
EXTRA_SPEAKERS_COUNT=$(bashio::config 'extra_speakers|length')
for ((i = 0; i < EXTRA_SPEAKERS_COUNT; i++)); do
    SPEAKERS_MAC+=("$(bashio::config "extra_speakers[${i}].mac")")
    SPEAKERS_NAME+=("$(bashio::config "extra_speakers[${i}].name")")
    SPEAKERS_LATENCY+=("$(bashio::config "extra_speakers[${i}].latency_offset_ms" 0)")
done
if ((EXTRA_SPEAKERS_COUNT > 0)); then
    bashio::log.info "${EXTRA_SPEAKERS_COUNT} extra speaker(s) configured (${#SPEAKERS_MAC[@]} total)."
fi

# Décalage de synchro de chaque enceinte (2.5.0, voir apply_latency_offset
# dans btui.sh) : SPEAKERS_LATENCY[] garde la valeur de la configuration au
# démarrage, mais la valeur EN COURS vit dans BTUI_LATENCY_FILE, que la
# page d'appairage modifie en direct sans redémarrer l'add-on. C'est ce
# fichier que relit la boucle de surveillance (étape 5) — relire
# SPEAKERS_LATENCY[] y annulerait à chaque passage un réglage fait depuis
# la page. Une valeur hors bornes (impossible via le schema, mais on ne
# prend pas le risque de faire planter jq plus bas) retombe à 0.
echo '{}' >"${BTUI_LATENCY_FILE}"
for i in "${!SPEAKERS_MAC[@]}"; do
    if ! [[ "${SPEAKERS_LATENCY[i]}" =~ ^[0-9]+$ ]] || ((SPEAKERS_LATENCY[i] > BTUI_LATENCY_MAX)); then
        SPEAKERS_LATENCY[i]=0
    fi
    latency_set_runtime "${SPEAKERS_MAC[i]}" "${SPEAKERS_LATENCY[i]}" || true
done

# --- 1quinquies. Groupes synchronisés (2.5.0) ---
# `sync_groups` est une liste optionnelle d'objets {name, speakers} (voir
# config.yaml) — vide par défaut, donc ce bloc ne change rien pour qui ne
# l'utilise pas. Chaque groupe valide deviendra un sink PulseAudio combiné
# (étape 4ter) et un renderer gmediarender de plus (étape 5bis).
# Tableaux parallèles GROUPS_*[], indicés comme sync_groups dans la
# configuration : un groupe ignoré garde sa place (sink vide, raison dans
# GROUPS_ERROR[]), pour que l'indice reste celui du nom de sink
# bab_sync_<indice>. Un groupe mal formé n'arrête jamais l'add-on : il est
# ignoré avec un message dans le journal ET sur la page d'appairage
# (groups.json), et tout le reste démarre normalement.

# speaker_index <mac> — indice de l'enceinte dans SPEAKERS_MAC[] (casse
# ignorée) ; code 1 si elle n'est pas configurée.
speaker_index() {
    local j
    for j in "${!SPEAKERS_MAC[@]}"; do
        if [ "${SPEAKERS_MAC[j]^^}" = "${1^^}" ]; then
            echo "${j}"
            return 0
        fi
    done
    return 1
}

GROUPS_NAME=()
GROUPS_MEMBERS=()
# Adresses MAC (majuscules) des membres, séparées par des espaces.
GROUPS_SINK=()
GROUPS_ERROR=()
SYNC_GROUPS_COUNT=$(bashio::config 'sync_groups|length')
for ((i = 0; i < SYNC_GROUPS_COUNT; i++)); do
    group_name=$(bashio::config "sync_groups[${i}].name")
    group_speakers=$(bashio::config "sync_groups[${i}].speakers")
    group_error=""
    group_members=()
    read -ra group_parts <<<"${group_speakers//,/ }"
    for member in "${group_parts[@]}"; do
        member="${member^^}"
        if ! valid_mac "${member}"; then
            bashio::log.warning "Sync group \"${group_name}\": \"${member}\" is not a valid MAC address, ignored." || true
        elif ! speaker_index "${member}" >/dev/null; then
            bashio::log.warning "Sync group \"${group_name}\": ${member} is not a configured speaker (bluetooth_mac or extra_speakers), ignored." || true
        elif [[ " ${group_members[*]} " != *" ${member} "* ]]; then
            group_members+=("${member}")
        fi
    done
    if [ -z "${group_name}" ] || [ "${group_name}" = "null" ]; then
        group_error="This group has no name."
    elif ((${#group_members[@]} < 2)); then
        group_error="A synchronized group needs at least two speakers configured in this add-on."
    else
        # Nom unique (casse ignorée) : l'UUID DLNA d'un groupe est dérivé
        # de son nom (étape 5bis), deux groupes du même nom seraient
        # fusionnés en une seule entité par Home Assistant.
        for ((j = 0; j < i; j++)); do
            if [ "${GROUPS_NAME[j],,}" = "${group_name,,}" ]; then
                group_error="Another group already uses this name."
            fi
        done
    fi
    GROUPS_NAME+=("${group_name}")
    GROUPS_MEMBERS+=("${group_members[*]}")
    GROUPS_ERROR+=("${group_error}")
    if [ -n "${group_error}" ]; then
        GROUPS_SINK+=("")
        bashio::log.error "Sync group \"${group_name}\" ignored: ${group_error}" || true
    else
        GROUPS_SINK+=("bab_sync_${i}")
        bashio::log.info "Sync group \"${group_name}\": ${#group_members[@]} speakers (${group_members[*]})." || true
    fi
done

# write_groups_state — écrit BTUI_GROUPS_FILE pour la page d'appairage :
# ce que run.sh a réellement démarré, avec la raison des groupes ignorés.
write_groups_state() {
    local i tmp="${BTUI_GROUPS_FILE}.$$.tmp"
    local -a entries=()
    for i in "${!GROUPS_NAME[@]}"; do
        entries+=("$(jq -cn \
            --arg name "${GROUPS_NAME[i]}" \
            --arg members "${GROUPS_MEMBERS[i]}" \
            --arg sink "${GROUPS_SINK[i]}" \
            --arg error "${GROUPS_ERROR[i]}" \
            '{
                name: $name,
                members: ($members | split(" ") | map(select(. != ""))),
                sink: (if $sink == "" then null else $sink end),
                error: (if $error == "" then null else $error end)
            }')")
    done
    printf '%s\n' "${entries[@]}" | jq -cs '.' >"${tmp}" && mv -f "${tmp}" "${BTUI_GROUPS_FILE}"
}
write_groups_state || bashio::log.warning "Could not write the sync groups state for the pairing web UI." || true

# --- 1sexies. Pré-calcul de l'UUID et du port DLNA de chaque enceinte et
# de chaque groupe synchronisé (2.4.1, étendu aux groupes en 2.6.0) ---
# Fait une seule fois ici, dans l'ordre des enceintes puis des groupes,
# plutôt que dans la boucle de démarrage du renderer (ancienne étape 5bis) :
# depuis cette version, c'est monitor_speaker (étape 5) qui démarre/arrête/
# relance le renderer de SA PROPRE enceinte (voir issue #6 — l'entité
# media_player restait "disponible" alors que l'enceinte était éteinte,
# gmediarender continuant de répondre sur le réseau quoi qu'il arrive). Il
# lui faut donc connaître à l'avance l'UUID et le port de son enceinte,
# calculés une seule fois pour éviter qu'une reconnexion ne fasse changer
# l'un ou l'autre en cours de route. Les groupes n'existaient pas encore
# quand ce mécanisme a été introduit côté amont (ils n'ont donc jamais eu
# de port fixe) : on leur applique ici exactement la même logique, dans le
# même tableau used_ports, pour éviter qu'un groupe et une enceinte ne se
# disputent un port au démarrage (même bug que l'enceinte visait à corriger).
SPEAKERS_UUID=()
SPEAKERS_PORT=()
used_ports=()
for i in "${!SPEAKERS_MAC[@]}"; do
    mac_hash=$(echo -n "${SPEAKERS_MAC[i]}" | md5sum | cut -c1-32)
    SPEAKERS_UUID+=("${mac_hash:0:8}-${mac_hash:8:4}-${mac_hash:12:4}-${mac_hash:16:4}-${mac_hash:20:12}")
    if ((i == 0)); then
        port=49494
    else
        port=$((49500 + 16#${mac_hash:0:4} % 10000))
        while [[ " ${used_ports[*]} " == *" ${port} "* ]]; do
            port=$((port + 1))
        done
    fi
    used_ports+=("${port}")
    SPEAKERS_PORT+=("${port}")
done

GROUPS_UUID=()
GROUPS_PORT=()
for i in "${!GROUPS_SINK[@]}"; do
    if [ -z "${GROUPS_SINK[i]}" ]; then
        GROUPS_UUID+=("")
        GROUPS_PORT+=("")
        continue
    fi
    group_hash=$(echo -n "sync_group:${GROUPS_NAME[i],,}" | md5sum | cut -c1-32)
    GROUPS_UUID+=("${group_hash:0:8}-${group_hash:8:4}-${group_hash:12:4}-${group_hash:16:4}-${group_hash:20:12}")
    port=$((49500 + 16#${group_hash:0:4} % 10000))
    while [[ " ${used_ports[*]} " == *" ${port} "* ]]; do
        port=$((port + 1))
    done
    used_ports+=("${port}")
    GROUPS_PORT+=("${port}")
done

# --- 2. Calcul du nom du sink PulseAudio correspondant ---
# PulseAudio nomme les sinks Bluetooth en remplaçant les ":" par des "_"
# et en les collant au format bluez_sink.<MAC>.a2dp_sink.
# Exemple : AA:BB:CC:DD:EE:FF  ->  AA_BB_CC_DD_EE_FF
# Fonctions sink_for_mac/card_for_mac (plutôt qu'un calcul en ligne) car
# nécessaires pour CHAQUE enceinte du tableau ci-dessus depuis le
# multi-enceintes, pas seulement la première. Déplacées telles quelles
# dans btui.sh en 2.5.0 (sourcé en tête de ce script), pour servir aussi à
# la page d'appairage.

BLUETOOTH_SINK=$(sink_for_mac "${BT_MAC}")
# Reste celui de la PREMIÈRE enceinte uniquement : c'est ce que MPD utilise
# (étape 3), et MPD ne gère qu'une seule enceinte dans cette version (voir
# schema de extra_speakers dans config.yaml pour le détail de ce choix).
# Pas de BLUETOOTH_CARD équivalent : chaque appel à ensure_audio_sink
# (étape 4bis) recalcule card_for_mac à la volée pour SA propre enceinte,
# dans la boucle multi-enceintes — une variable globale pour la carte de la
# première enceinte seule n'a plus d'usage depuis le passage au
# multi-enceintes (2.3.0) et était restée sans effet (shellcheck SC2034).

bashio::log.info "Computed PulseAudio sink: ${BLUETOOTH_SINK}"

# --- 3. Génération du fichier mpd.conf final (si MPD activé) ---
# On remplace ${BLUETOOTH_SINK}, ${SPEAKER_NAME} et ${MPD_PASSWORD_DIRECTIVE}
# dans le modèle par les vraies valeurs calculées ci-dessus, et on écrit le
# résultat dans /etc/mpd.conf. Attention à la syntaxe : envsubst ne
# reconnaît QUE `$VAR`/`${VAR}` (pas de `{{VAR}}` façon Jinja/Mustache — un
# bug de ce type, avec le template utilisant {{BLUETOOTH_SINK}}, avait fait
# échouer silencieusement toute lecture audio lors du développement
# initial : MPD tentait de se connecter à un sink qui n'existait pas).
if bashio::var.true "${ENABLE_MPD}"; then
    # shellcheck disable=SC2090
    # (même faux positif que plus haut : envsubst lit MPD_PASSWORD_DIRECTIVE
    # comme du texte brut, pas comme une commande shell à reconstruire.)
    export BLUETOOTH_SINK SPEAKER_NAME MPD_PASSWORD_DIRECTIVE
    envsubst '${BLUETOOTH_SINK} ${SPEAKER_NAME} ${MPD_PASSWORD_DIRECTIVE}' < /etc/mpd.conf.template > /etc/mpd.conf
    bashio::log.info "/etc/mpd.conf generated."
else
    bashio::log.info "enable_mpd is false: skipping mpd.conf generation."
fi

# --- 4. Connexion (ou reconnexion) Bluetooth à l'enceinte ---
# Fonction réutilisée aussi bien au démarrage que dans la boucle de
# surveillance plus bas. Paramétrée par mac/name (2.3.0, multi-enceintes) :
# une seule définition, appelée pour chaque enceinte du tableau
# SPEAKERS_MAC[]/SPEAKERS_NAME[], au lieu d'une copie par enceinte.
connect_speaker() {
    local mac="$1" name="$2"
    bashio::log.info "Connecting to ${name} (${mac})..."
    # "|| true" sur les trois lignes ci-dessous : avec "set -e" en tête de
    # script, la moindre commande qui renvoie un code non nul (y compris
    # bashio::log.* lui-même, ou "bluetoothctl power on" seul, qui n'était
    # pas protégé jusqu'ici contrairement à "connect" juste en dessous) tue
    # tout le conteneur immédiatement — sans le moindre message d'erreur,
    # juste après le log "Connecting to...". C'est exactement le crash
    # silencieux et systématique observé en 2026-09 (voir vault, incident
    # du 2026-09-01) : un échec de connexion à l'enceinte ne doit jamais
    # faire tomber le script, seulement être loggé et retenté par la boucle
    # de surveillance (étape 5).
    bluetoothctl power on || true
    if bluetoothctl connect "${mac}"; then
        bashio::log.info "${name} connected." || true
    else
        bashio::log.warning "Failed to connect to ${name} — will retry in the monitoring loop." || true
    fi
}

# --- 4bis. Garde-fou : forcer le profil et le volume audio si besoin ---
# Cas observé en conditions réelles : après une série rapprochée de
# déconnexions/reconnexions Bluetooth (typiquement une enceinte à
# batterie faible), BlueZ finit par rapporter la connexion comme stable
# ("Connected: yes"), mais le profil de la carte PulseAudio correspondante
# reste bloqué sur "off" au lieu de repasser sur "a2dp_sink" — le sink
# audio n'existe alors plus du tout, et MPD n'a nulle part où streamer,
# sans qu'aucune erreur visible n'apparaisse côté Bluetooth. Ce n'est pas
# un bug de ce script mais un comportement du module PulseAudio Bluetooth
# lui-même : on ne peut pas empêcher que ça arrive, seulement le détecter
# et s'en remettre automatiquement.
ensure_audio_sink() {
    local sink="$1" card="$2"
    # Paramétrée par sink/card (2.3.0, multi-enceintes) : DEFAULT_VOLUME
    # reste une variable globale partagée entre toutes les enceintes — un
    # seul réglage de config pour toutes (voir config.yaml), pas de volume
    # par enceinte dans cette version, pour rester simple.
    # Sortie capturée PUIS cherchée, jamais "commande | grep -q" (2.4.0) :
    # avec "set -o pipefail" en tête de script, grep -q s'arrête dès la
    # première correspondance, la commande en amont peut alors être tuée par
    # SIGPIPE en écrivant la suite de sa sortie, et tout le pipe est lu comme
    # un échec alors que la ligne cherchée était bien là. Même règle dans
    # monitor_speaker plus bas, et même précaution que webui/lib/btui.sh.
    local sinks
    sinks=$(pactl list short sinks 2>/dev/null) || true
    if ! grep -q "${sink}" <<<"${sinks}"; then
        # Le sink attendu n'existe pas : on force le profil. Sans effet si la
        # carte PulseAudio n'a pas encore été créée par BlueZ (juste après une
        # connexion très récente) — la boucle de surveillance réessaiera au
        # prochain passage.
        if pactl set-card-profile "${card}" a2dp_sink 2>/dev/null; then
            bashio::log.warning "Bluetooth audio sink was missing, forced PulseAudio profile back to a2dp_sink."
        fi
        return
    fi

    # Le sink existe mais peut être silencieux (muet, ou volume à 0%) sans
    # qu'aucune erreur ne remonte côté Bluetooth ou PulseAudio — signalé par
    # un utilisateur (GitHub issue #1) : ce volume/mute au niveau du sink
    # (matériel) est un réglage distinct du volume interne de gmediarender
    # (qui ne contrôle que son propre flux, voir étape 5bis) — rien dans ce
    # script ne le touchait jusqu'ici. Deux vérifications séparées :
    # `set-sink-volume` seul ne démute pas un sink déjà muet.
    local mute
    mute=$(pactl get-sink-mute "${sink}" 2>/dev/null) || true
    if grep -q "^Mute: yes" <<<"${mute}"; then
        if pactl set-sink-mute "${sink}" 0 2>/dev/null; then
            bashio::log.warning "Bluetooth audio sink was muted, unmuted it."
        fi
    fi

    # Volume brut du premier canal, extrait avant le premier "/" de la
    # sortie de `get-sink-volume` : plus fiable qu'un grep sur "0%", qui
    # matcherait aussi "100%" (qui se termine littéralement par "0%").
    local raw_volume
    raw_volume=$(pactl get-sink-volume "${sink}" 2>/dev/null \
        | awk -F'/' '/Volume:/ { gsub(/[^0-9]/, "", $1); print $1; exit }') || true
    if [ "${raw_volume:-}" = "0" ]; then
        if pactl set-sink-volume "${sink}" "${DEFAULT_VOLUME}%" 2>/dev/null; then
            bashio::log.warning "Bluetooth audio sink was silent (0% volume), reset to ${DEFAULT_VOLUME}%."
        fi
    fi
    # N'écrase jamais un volume non nul choisi par l'utilisateur (ex. 20%) :
    # seul le silence total (0% ou muet) déclenche une correction, pas de
    # reset périodique intrusif à chaque passage de la boucle.
}

# On tente une première connexion avant même de démarrer MPD, pour que
# le sink existe déjà quand MPD essaiera de s'y attacher.
# Boucle sur SPEAKERS_MAC[]/SPEAKERS_NAME[] (2.3.0, multi-enceintes) : avec
# une seule enceinte configurée (cas par défaut), ce tableau ne contient que
# l'indice 0 et cette boucle se comporte exactement comme l'appel unique
# d'avant.
for i in "${!SPEAKERS_MAC[@]}"; do
    # "|| true" : filet de sécurité supplémentaire, au cas où connect_speaker
    # retournerait quand même un code non nul pour une raison non couverte
    # ci-dessus — un appel de fonction "nu" comme celui-ci est justement ce
    # qui déclenche "set -e" si son code de sortie est non nul.
    connect_speaker "${SPEAKERS_MAC[i]}" "${SPEAKERS_NAME[i]}" || true
done
sleep 2
# Laisse le temps à PulseAudio d'enregistrer la/les carte(s) Bluetooth après
# la connexion avant de vérifier/forcer leur profil.
for i in "${!SPEAKERS_MAC[@]}"; do
    ensure_audio_sink "$(sink_for_mac "${SPEAKERS_MAC[i]}")" "$(card_for_mac "${SPEAKERS_MAC[i]}")"
    # Décalage de synchro (2.5.0) : appliqué même à 0, pour effacer une
    # valeur plus ancienne que PulseAudio aurait gardée pour cette carte
    # (module-card-restore la mémorise d'un démarrage à l'autre).
    if apply_latency_offset "${SPEAKERS_MAC[i]}" "${SPEAKERS_LATENCY[i]}"; then
        if ((SPEAKERS_LATENCY[i] > 0)); then
            bashio::log.info "Sync offset of ${SPEAKERS_NAME[i]}: ${SPEAKERS_LATENCY[i]} ms." || true
        fi
    elif ((SPEAKERS_LATENCY[i] > 0)); then
        bashio::log.warning "Could not apply the sync offset of ${SPEAKERS_NAME[i]} yet (not connected?), will retry in the monitoring loop." || true
    fi
done

# --- 4ter. Groupes synchronisés : sinks combinés (2.5.0) ---
# Un groupe = un sink PulseAudio "combiné" (module-combine-sink) qui
# alimente tous ses membres à partir d'un seul flux. C'est lui qui fait la
# synchro : il corrige en continu la dérive d'horloge entre les enceintes
# (en rééchantillonnant très légèrement chaque sortie, écart plafonné à
# 1 %) et aligne leurs latences déclarées, décalage de synchro compris
# (voir apply_latency_offset dans btui.sh). Ni DLNA ni MPD ne permettent de
# synchroniser plusieurs lecteurs côté Music Assistant (vérifié le
# 2026-09-13 dans le code de son fournisseur MPD et dans sa documentation
# des groupes) : c'est donc ici, sous les lecteurs, que ça se fait.
#
# Trois comportements du module, vérifiés dans son code source, dictent la
# suite :
# - il REFUSE de se charger si l'un des sinks membres n'existe pas : on le
#   charge avec les membres présents, puis on le recharge quand un membre
#   manquant apparaît (ensure_sync_group) ;
# - une fois chargé, un membre qui disparaît (déconnexion Bluetooth) puis
#   réapparaît sous le même nom est réintégré tout seul ;
# - il ne se met JAMAIS en veille de lui-même : il compte pour ça sur
#   module-suspend-on-idle, que le PulseAudio partagé de HAOS ne charge pas
#   (vérifié dans rootfs/etc/pulse/system.pa du plugin audio). Sans rien
#   faire, un groupe enverrait donc du silence en permanence à ses
#   enceintes : CPU occupé, radio Bluetooth sollicitée, enceintes qui ne se
#   mettent jamais en veille. D'où la mise en veille gérée par ce script
#   (étape 5, watch_sync_groups), limitée à NOS sinks : charger
#   suspend-on-idle changerait le comportement de tout le serveur audio de
#   HAOS, pour tous les add-ons.
# Les modules chargés vivent dans ce serveur audio partagé, pas dans le
# conteneur : ils survivent à un redémarrage de l'add-on, d'où le ménage au
# démarrage (unload_stale_sync_groups).

# combine_module_for <sink> — affiche "index<TAB>membres" (membres séparés
# par des virgules) du module qui porte ce sink ; rien s'il n'est pas
# chargé. L'espace après le nom évite que bab_sync_1 corresponde aussi à
# bab_sync_10 : ensure_sync_group passe toujours sink_name en premier.
combine_module_for() {
    LC_ALL=C pactl list short modules 2>/dev/null | awk -v key="sink_name=$1 " '
        $2 == "module-combine-sink" && index($0, key) {
            slaves = $0; sub(/.*slaves=/, "", slaves); sub(/[ \t].*/, "", slaves)
            print $1 "\t" slaves; exit
        }' || true
}

# unload_stale_sync_groups — décharge les sinks combinés laissés par un
# démarrage précédent, y compris ceux de groupes supprimés depuis de la
# configuration. Ne touche qu'aux sinks dont le nom commence par
# "bab_sync_" (ceux de cet add-on).
unload_stale_sync_groups() {
    local module
    for module in $(LC_ALL=C pactl list short modules 2>/dev/null \
        | awk '$2 == "module-combine-sink" && index($0, "sink_name=bab_sync_") { print $1 }' || true); do
        pactl unload-module "${module}" 2>/dev/null || true
    done
}

# Piège sur arrêt (2.7.0) : décharge les sinks combinés si l'add-on est
# arrêté ou désinstallé PENDANT cette phase de démarrage (Bluetooth en
# cours de connexion, page d'appairage seule en mode configuration...).
# Docker envoie SIGTERM dans les trois cas (stop, redémarrage,
# désinstallation) ; sans ce piège, les sinks "bab_sync_*" déjà chargés à
# ce stade resteraient dans le serveur PulseAudio PARTAGÉ de l'hôte
# jusqu'à son propre redémarrage (inertes, mais visibles avec
# `pactl list short modules`). Ce piège ne couvre PAS un arrêt survenant
# une fois MPD lancé (étape 6) : "exec" y remplace ce script par le
# processus MPD lui-même, qui ne connaît rien de nos sinks et ne peut pas
# hériter ce piège — voir la note dans cette étape, et la section Sécurité
# du README pour la limite documentée (sinon activer enable_mpd à false,
# couvert par la boucle d'attente de l'étape 6, qui garde ce piège actif
# en permanence).
trap 'unload_stale_sync_groups; exit 0' TERM INT

# ensure_sync_group <indice> — crée le sink combiné du groupe s'il manque,
# ou le recharge si un membre absent lors du chargement est apparu depuis
# — seulement quand aucun flux ne joue sur le groupe, pour ne jamais couper
# une lecture. Appelée au démarrage puis à chaque passage de
# monitor_sync_groups (étape 5).
ensure_sync_group() {
    local i="$1"
    local sink="${GROUPS_SINK[i]}" name="${GROUPS_NAME[i]}"
    local mac slave module_line module loaded description new_member=false
    local -a members present=()
    read -ra members <<<"${GROUPS_MEMBERS[i]}"
    for mac in "${members[@]}"; do
        slave=$(sink_for_mac "${mac}")
        if [ -n "$(pulse_sink_state "${slave}")" ]; then
            present+=("${slave}")
        fi
    done

    module_line=$(combine_module_for "${sink}")
    if [ -n "${module_line}" ]; then
        module="${module_line%%$'\t'*}"
        loaded=",${module_line#*$'\t'},"
        for slave in "${present[@]}"; do
            if [[ "${loaded}" != *",${slave},"* ]]; then
                new_member=true
            fi
        done
        if [ "${new_member}" = false ]; then
            return 0
        fi
        if (($(sink_input_count "${sink}") > 0)); then
            return 0
        fi
        pactl unload-module "${module}" 2>/dev/null || true
    fi
    if ((${#present[@]} == 0)); then
        return 0
    fi

    # Nom lisible du sink (visible avec pactl) : apostrophes, guillemets et
    # antislash retirés (sanitize_conf_string, btui.sh), ils casseraient la
    # syntaxe des arguments du module. Le nom affiché dans Home Assistant
    # vient de gmediarender (étape 5bis) et n'est pas concerné.
    description=$(sanitize_conf_string "${name}")
    if ! pactl load-module module-combine-sink \
        "sink_name=${sink}" \
        "slaves=$(IFS=,; echo "${present[*]}")" \
        "sink_properties=\"device.description='${description}'\"" >/dev/null 2>&1; then
        bashio::log.warning "Could not create the audio output of sync group \"${name}\", will retry in the monitoring loop." || true
        return 0
    fi
    # En veille dès sa création : réveillé à la demande (watch_sync_groups).
    pactl suspend-sink "${sink}" 1 2>/dev/null || true
    bashio::log.info "Sync group \"${name}\" ready with ${#present[@]} of ${#members[@]} speaker(s)." || true
}

unload_stale_sync_groups
for i in "${!GROUPS_SINK[@]}"; do
    if [ -n "${GROUPS_SINK[i]}" ]; then
        ensure_sync_group "${i}" || true
    fi
done

# --- 5. Boucle de surveillance Bluetooth (tourne en tâche de fond) ---
# Vérifie périodiquement (intervalle configurable, voir RECONNECT_INTERVAL)
# si l'enceinte est toujours connectée ; si elle ne l'est plus (mise en
# veille, hors de portée...), on relance une connexion automatiquement,
# sans intervention manuelle.
# Paramétrée par mac/name/sink/card (2.3.0, multi-enceintes) : UNE instance
# de cette boucle est lancée en tâche de fond PAR enceinte (voir plus bas),
# chacune surveillant uniquement la sienne — la déconnexion/reconnexion
# d'une enceinte n'a donc aucune raison de se mélanger avec celle d'une
# autre côté logique applicative (la contention possible reste au niveau du
# radio Bluetooth physique lui-même, voir vault : test du 2026-09-06).
monitor_speaker() {
    local mac="$1" name="$2" sink="$3" card="$4" uuid="$5" port="$6"
    local renderer_pid=""
    # renderer_pid est une variable LOCALE à cette fonction : chaque appel de
    # monitor_speaker tourne dans son propre processus (le "&" au moment de
    # l'appel, plus bas), donc le renderer_pid d'une enceinte ne peut pas se
    # mélanger avec celui d'une autre, même si le nom de la variable est le
    # même partout.

    is_connected() {
        local i
        i=$(bluetoothctl info "${mac}" 2>/dev/null) || true
        grep -q "Connected: yes" <<<"${i}"
    }

    start_renderer() {
        # Corrige la GitHub issue #6 : avant cette version, gmediarender
        # tournait en continu quelle que soit la connexion Bluetooth, donc
        # HA voyait toujours un renderer qui répond et gardait l'entité
        # "disponible" même enceinte éteinte. Démarré ici (donc uniquement
        # quand on sait l'enceinte connectée) plutôt que dans une boucle à
        # part comme avant 2.4.1.
        bashio::log.info "Starting the DLNA renderer for ${name} (uuid=${uuid}, port=${port})..." || true
        gmediarender \
            --gstout-audiosink=pulsesink \
            --gstout-audiodevice="${sink}" \
            --gstout-initial-volume-db="${RENDERER_INITIAL_DB}" \
            --friendly-name="${name}" \
            --uuid="${uuid}" \
            --port="${port}" \
            --logfile=stdout \
            &
        renderer_pid=$!
    }

    stop_renderer() {
        # Appelé uniquement quand l'enceinte est détectée déconnectée : c'est
        # cet arrêt qui rend le renderer injoignable et qui doit faire passer
        # l'entité media_player à "indisponible" côté Home Assistant.
        if [ -n "${renderer_pid}" ] && kill -0 "${renderer_pid}" 2>/dev/null; then
            kill "${renderer_pid}" 2>/dev/null || true
            wait "${renderer_pid}" 2>/dev/null || true
            bashio::log.warning "Stopped the DLNA renderer for ${name} while disconnected." || true
        fi
        renderer_pid=""
    }

    # Démarrage initial : on vérifie l'état réel plutôt que de supposer que
    # la connexion faite plus haut (avant le lancement de cette boucle en
    # tâche de fond) a réussi — une enceinte éteinte au démarrage de l'add-on
    # ne doit pas se voir attribuer un renderer qui tournerait dans le vide.
    if is_connected; then
        start_renderer
    else
        bashio::log.warning "${name} not connected at startup, DLNA renderer not started yet." || true
    fi

    while true; do
        sleep "${RECONNECT_INTERVAL}"
        # Sortie capturée puis cherchée (2.4.0, voir ensure_audio_sink) : le
        # pipe "bluetoothctl info | grep -q" sous pipefail signalait une
        # enceinte pourtant connectée comme déconnectée toutes les ~30 s,
        # puis relançait une connexion qui échouait forcément (constaté sur
        # un Raspberry Pi 4 le 2026-09-12, BlueZ 5.66 de l'image Alpine 3.18).
        if is_connected; then
            # Reconnectée depuis le dernier passage (ou renderer mort tout
            # seul, ex. crash de gmediarender) : le relancer.
            if [ -z "${renderer_pid}" ] || ! kill -0 "${renderer_pid}" 2>/dev/null; then
                start_renderer
            fi
        else
            bashio::log.warning "${name} disconnected, attempting to reconnect..." || true
            stop_renderer
            connect_speaker "${mac}" "${name}" || true
            sleep 2
            if is_connected; then
                start_renderer
            fi
        fi
        # Vérifié à chaque passage, pas seulement après une reconnexion :
        # le profil PulseAudio peut rester bloqué sur "off" alors que
        # Bluetooth se dit déjà connecté depuis un moment (voir 4bis).
        ensure_audio_sink "${sink}" "${card}"
        # Décalage de synchro (2.5.0) : réappliqué à chaque passage (pactl
        # n'est appelé que si la valeur a changé), car la carte PulseAudio
        # est recréée à chaque reconnexion. Valeur EN COURS relue dans
        # BTUI_LATENCY_FILE, que la page d'appairage modifie en direct.
        apply_latency_offset "${mac}" "$(latency_for_mac "${mac}")" || true
    done
}
for i in "${!SPEAKERS_MAC[@]}"; do
    monitor_speaker \
        "${SPEAKERS_MAC[i]}" \
        "${SPEAKERS_NAME[i]}" \
        "$(sink_for_mac "${SPEAKERS_MAC[i]}")" \
        "$(card_for_mac "${SPEAKERS_MAC[i]}")" \
        "${SPEAKERS_UUID[i]}" \
        "${SPEAKERS_PORT[i]}" &
    # Le "&" final lance cette boucle en arrière-plan : le script continue
    # immédiatement à l'étape suivante sans attendre qu'elle se termine
    # (elle ne se termine jamais, c'est voulu) — une par enceinte.
done

# --- 5ter. Surveillance et mise en veille des groupes synchronisés (2.5.0) ---
# Deux boucles de fond, lancées seulement s'il y a au moins un groupe :
# - monitor_sync_groups, au même rythme que la surveillance Bluetooth,
#   (re)crée les sinks combinés au besoin (membre revenu, serveur audio
#   redémarré...) ;
# - watch_sync_groups réveille un groupe dès qu'un flux arrive dessus, et
#   le remet en veille quelques secondes après le dernier (pourquoi : voir
#   4ter). Elle réagit aux événements de PulseAudio (pactl subscribe)
#   plutôt qu'à un sondage régulier : réveil immédiat, et rien de consommé
#   entre deux événements.

SYNC_GROUP_IDLE_SECONDS=5
# Délai avant la mise en veille après le dernier flux : évite de couper
# puis réveiller le groupe entre deux morceaux.

ACTIVE_GROUP_SINKS=()
for i in "${!GROUPS_SINK[@]}"; do
    if [ -n "${GROUPS_SINK[i]}" ]; then
        ACTIVE_GROUP_SINKS+=("${GROUPS_SINK[i]}")
    fi
done

# wake_sync_group <sink> — sort le groupe de veille si un flux l'attend.
# Un flux qui arrive sur un sink mis en veille à la main (pactl
# suspend-sink) est bien accepté, mais reste bloqué tant que le sink n'est
# pas réveillé : PulseAudio ne le fait pas de lui-même dans ce cas.
wake_sync_group() {
    local sink="$1"
    if [ "$(pulse_sink_state "${sink}")" = "SUSPENDED" ] && (($(sink_input_count "${sink}") > 0)); then
        pactl suspend-sink "${sink}" 0 2>/dev/null || true
    fi
}

# sleep_sync_group <sink> — met le groupe en veille s'il n'a plus de flux.
sleep_sync_group() {
    local sink="$1" state
    state=$(pulse_sink_state "${sink}")
    if [ -n "${state}" ] && [ "${state}" != "SUSPENDED" ] && (($(sink_input_count "${sink}") == 0)); then
        pactl suspend-sink "${sink}" 1 2>/dev/null || true
    fi
}

monitor_sync_groups() {
    local i
    while true; do
        sleep "${RECONNECT_INTERVAL}"
        for i in "${!GROUPS_SINK[@]}"; do
            if [ -n "${GROUPS_SINK[i]}" ]; then
                ensure_sync_group "${i}" || true
                # Filet de sécurité si un événement a été manqué (pendant un
                # redémarrage du serveur audio, par exemple).
                wake_sync_group "${GROUPS_SINK[i]}" || true
                sleep_sync_group "${GROUPS_SINK[i]}" || true
            fi
        done
    done
}

watch_sync_groups() {
    local line sink
    while true; do
        # "pactl subscribe" s'arrête si le serveur audio redémarre : on le
        # relance après une courte pause.
        LC_ALL=C pactl subscribe 2>/dev/null | while read -r line; do
            case "${line}" in
                *"'new' on sink-input"* | *"'change' on sink-input"*)
                    for sink in "${ACTIVE_GROUP_SINKS[@]}"; do
                        wake_sync_group "${sink}" || true
                    done
                    ;;
                *"'remove' on sink-input"*)
                    (
                        sleep "${SYNC_GROUP_IDLE_SECONDS}"
                        for sink in "${ACTIVE_GROUP_SINKS[@]}"; do
                            sleep_sync_group "${sink}" || true
                        done
                    ) &
                    ;;
            esac
        done || true
        sleep 5
    done
}

if ((${#ACTIVE_GROUP_SINKS[@]} > 0)); then
    monitor_sync_groups &
    watch_sync_groups &
fi

# --- 5bis. Media_player natif des groupes synchronisés (renderer DLNA/UPnP) ---
# Depuis 2.4.1, gmediarender n'est plus démarré ici pour chaque ENCEINTE :
# c'est monitor_speaker (étape 5, fonctions start_renderer/stop_renderer)
# qui le démarre, l'arrête et le relance pour SA propre enceinte, selon
# l'état réel de la connexion Bluetooth — voir la GitHub issue #6 (l'entité
# media_player restait "disponible" côté Home Assistant même enceinte
# éteinte, gmediarender continuant de répondre sur le réseau quoi qu'il
# arrive). L'UUID et le port de chaque enceinte restent calculés une seule
# fois (étape 1sexies, SPEAKERS_UUID[]/SPEAKERS_PORT[]) pour qu'ils ne
# changent jamais en cours de route, y compris à travers plusieurs
# déconnexions/reconnexions.
#
# Un GROUPE synchronisé n'a pas d'enceinte unique dont dépendre : son sink
# combiné (étape 4ter, ensure_sync_group) s'adapte déjà aux membres présents
# ou absents, donc son renderer reste démarré en continu ici, comme avant
# 2.4.1 — seules les enceintes individuelles ont besoin du cycle de vie
# géré par monitor_speaker. UUID et port de chaque groupe précalculés au
# même endroit que ceux des enceintes (étape 1sexies, GROUPS_UUID[]/
# GROUPS_PORT[]), avec le même volume de départ (RENDERER_INITIAL_DB).
start_gmediarender() {
    local name="$1" sink="$2" uuid="$3" port="$4"
    bashio::log.info "gmediarender binary found ($(command -v gmediarender)), starting for ${name} with uuid=${uuid} on port ${port}..."
    gmediarender \
        --gstout-audiosink=pulsesink \
        --gstout-audiodevice="${sink}" \
        --gstout-initial-volume-db="${RENDERER_INITIAL_DB}" \
        --friendly-name="${name}" \
        --uuid="${uuid}" \
        --port="${port}" \
        --logfile=stdout \
        &
}

if command -v gmediarender >/dev/null 2>&1; then
    # Une instance de plus par groupe synchronisé (2.5.0), branchée sur son
    # sink combiné (étape 4ter) : c'est ce qui donne un media_player
    # "groupe" dans Home Assistant, et un lecteur dans Music Assistant via
    # son fournisseur DLNA. UUID et port dérivés du nom du groupe (étape
    # 1sexies), préfixés pour ne jamais tomber sur ceux d'une enceinte :
    # stables d'un redémarrage à l'autre, mais un groupe renommé devient une
    # nouvelle entité (documenté dans le README). Lancée même si aucune
    # enceinte du groupe n'est connectée : gmediarender n'ouvre le sink
    # qu'au moment de jouer.
    for i in "${!GROUPS_SINK[@]}"; do
        if [ -n "${GROUPS_SINK[i]}" ]; then
            start_gmediarender "${GROUPS_NAME[i]}" "${GROUPS_SINK[i]}" "${GROUPS_UUID[i]}" "${GROUPS_PORT[i]}"
        fi
    done
else
    bashio::log.error "gmediarender binary NOT FOUND — compilation Dockerfile probablement en échec silencieux, voir le journal de build."
fi
# Garde-fou de diagnostic (2026-08-20) : le premier build de gmediarender
# n'a produit aucune trace dans les logs (ni succès ni erreur) et HA n'a
# détecté aucun nouveau renderer DLNA — cette vérification confirme noir sur
# blanc si le binaire existe réellement avant de creuser plus loin, même si
# le démarrage effectif se fait maintenant dans monitor_speaker.
# Partage volontairement le même sink PulseAudio que MPD (si activé) :
# PulseAudio mixe plusieurs sources sur un même sink nativement, donc les
# deux peuvent en principe coexister sans conflit technique — à vérifier en
# usage réel si les deux jouent en même temps (voir "Inconnues techniques"
# dans le vault du projet).

# --- 6. Lancement du processus principal ---
if bashio::var.true "${ENABLE_MPD}"; then
    bashio::log.info "Starting MPD..."
    exec mpd --no-daemon /etc/mpd.conf
    # "exec" remplace ce script par le processus MPD : MPD devient le
    # processus principal du conteneur (utile pour que le Supervisor sache
    # si l'add-on plante et doive être redémarré). "--no-daemon" empêche
    # MPD de se détacher en arrière-plan, ce qui est nécessaire pour rester
    # le processus principal du conteneur au lieu de le laisser croire
    # que le conteneur s'est arrêté.
    # "exec" efface aussi le piège posé plus haut (sur TERM/INT) : MPD ne
    # décharge donc pas les sinks combinés des groupes synchronisés à son
    # arrêt. Changer cela impliquerait de ne plus garder MPD comme
    # processus principal (par ex. le lancer en tâche de fond puis
    # attendre sa fin ici) — trop risqué pour la détection de plantage par
    # le Supervisor pour le changer sans pouvoir tester sur du matériel
    # réel. Limite documentée dans le README (section Sécurité) : avec
    # enable_mpd actif, désinstaller l'add-on alors que des sync_groups
    # sont configurés peut laisser un sink "bab_sync_*" inerte jusqu'au
    # prochain redémarrage du serveur PulseAudio partagé de l'hôte.
else
    bashio::log.info "enable_mpd is false: MPD not started, keeping the container alive for the Bluetooth connection and the native media_player (gmediarender, étape 5bis)."
    # Pas de "exec tail -f /dev/null" (avant 2.7.0) : on reste nous-mêmes
    # le processus principal du conteneur, ce qui garde actif le piège posé
    # plus haut (sur TERM/INT) pour toute la durée de vie de l'add-on, pas
    # seulement pendant son démarrage — contrairement au cas MPD ci-dessus,
    # "tail" ne représentait la santé de rien de précis que le Supervisor
    # aurait besoin de surveiller, ce changement ne retire donc aucune
    # détection de plantage. "sleep" mis en arrière-plan puis attendu
    # (plutôt qu'au premier plan) : un piège bash n'est garanti de
    # s'exécuter immédiatement que pendant un "wait", pas forcément pendant
    # une commande externe au premier plan. La boucle de surveillance
    # Bluetooth (étape 5) et gmediarender (étape 5bis) continuent de
    # tourner en tâche de fond comme avant.
    trap 'unload_stale_sync_groups; exit 0' TERM INT
    while true; do
        sleep 3600 &
        wait "$!"
    done
fi
