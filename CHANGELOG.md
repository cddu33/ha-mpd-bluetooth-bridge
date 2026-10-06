# Changelog

## 2.7.0
- Added an optional **`mpd_password`** option: MPD clients (Music
  Assistant included) must then supply it to connect. Leave it empty to
  keep MPD open to the local network as before. See
  [Security note](README.md#security-note).
- `SUPERVISOR_TOKEN` (provided ambiently by the Supervisor to every
  add-on) is now captured once and removed from the shell's own
  environment right after the pairing page's web server is started (and,
  in each CGI request, right after it's captured for the one Supervisor
  API call that needs it), instead of staying inherited by every
  subprocess the add-on and the pairing page spawn (`bluetoothctl`,
  `pactl`, `jq`, `gst-launch-1.0`...) with no need for it.
- Synchronized groups' combined PulseAudio sinks are now unloaded on
  stop/uninstall too, not just on the next start, when `enable_mpd` is
  off. When it's on, MPD itself (not this script) is the container's
  main process and can't run that cleanup; see
  [Security note](README.md#security-note) for that one remaining case.
- Added a ShellCheck GitHub Actions workflow, and fixed the few findings
  it could cleanly fix (an unrecognized shebang, a handful of `job_set
  done "..."` calls shellcheck misread as the `done` keyword, and a
  genuinely unused `BLUETOOTH_CARD` variable left over from before
  multi-speaker support).

## 2.6.0
- Synchronized the `feature/sync-groups` branch with `master` (2.4.1 and
  2.4.2 below, developed in parallel) and extended their per-speaker DLNA
  port pinning and `renderer_volume` starting-volume handling to
  **synchronized groups** as well, so a group's `media_player` gets the
  same stable port and starting-volume behavior as an individual speaker.
- Fixed `sink_for_mac`/`card_for_mac` not uppercasing the MAC address
  before deriving the PulseAudio sink/card name. `bluetooth_mac` and
  `extra_speakers[].mac` accept lowercase hex, but PulseAudio's Bluetooth
  sink/card names are always uppercase: a lowercase MAC silently pointed
  MPD, `gmediarender` and the self-healing sink/volume checks at a sink
  that never existed, with no audio and no visible error.
- Fixed `speaker_name` being written into `/etc/mpd.conf` unescaped. The
  pairing page already rejects quotes and control characters in a name,
  but a name set directly from the Configuration tab did not go through
  that check, and a `"` or a newline in it could corrupt `mpd.conf` (MPD
  failing to start) or inject extra config lines.
- Fixed a lost-update race in the pairing page's device list: two
  concurrent requests (e.g. two "forget" actions) could each read the
  device list before the other's write landed, and the second write
  would silently discard the first.
- `add_group` now rejects a `macs` list containing a non-string entry
  (number, boolean, object) with a `400` error instead of silently
  dropping it.

## 2.5.0
- Added **synchronized groups**: a new `sync_groups` option, and a
  *Synchronized groups* section on the pairing page, group two or more
  configured speakers so they play the same audio in sync. Each group
  shows up as one more native `media_player` in Home Assistant, and in
  Music Assistant through its DLNA provider. Synchronization happens
  inside the add-on, in a PulseAudio combined sink (`module-combine-sink`)
  that keeps the speakers aligned and corrects clock drift between them:
  neither DLNA nor MPD can synchronize separate players on the Music
  Assistant side, and its "universal groups" aren't synchronized. A
  speaker that drops out rejoins its group by itself once reconnected.
  See [Synchronized groups](README.md#synchronized-groups).
- Added a per-speaker **sync offset** (`speaker_latency_offset_ms`, and
  `latency_offset_ms` in `extra_speakers`, 0-500 ms) for speakers that
  add their own internal delay. It's adjusted live from the pairing page
  while **test ticks** play on the group, without restarting the add-on.
- Groups go to standby by themselves when nothing is playing. HAOS's
  shared PulseAudio server doesn't load `module-suspend-on-idle`, so a
  combined sink would otherwise stream silence to its speakers forever
  (constant CPU and Bluetooth radio load, speakers never going to sleep).
  Only the add-on's own group sinks are touched.
- Music Assistant: extra speakers and groups are reached through its
  **DLNA** provider; MPD still covers the primary speaker only. One MPD
  instance per speaker was considered and dropped: Music Assistant creates
  one player per MPD server, so it would have added nothing over DLNA.
- The pairing page now asks the Supervisor for the add-on's current
  options before changing them, since sync offsets are saved without a
  restart.
- Added `gstreamer-tools` to the image (`gst-launch-1.0`, for the test
  ticks).

## 2.4.2
- Added a **`renderer_volume`** option (1-100, default `100`) setting the
  volume level each speaker's `media_player` starts at, as shown by its
  volume slider in Home Assistant. Since 2.4.1 the renderer is restarted
  every time a speaker reconnects, and it always came back at 100%, so a
  volume you had lowered jumped back up each time the speaker was
  switched off and on again. Set it to the level you want (for example
  `50`) and the `media_player` now starts there on every start and
  reconnect. The default of `100` keeps the previous behavior, so nothing
  changes unless you set it. It is separate from `default_volume`, which
  still only concerns the speaker's PulseAudio sink. Reported in
  [#9](https://github.com/dcybeldesign/ha-mpd-bluetooth-bridge/issues/9).

## 2.4.1
- Fixed the native `media_player` entity staying "available" in Home
  Assistant even after its speaker disconnected. The DLNA renderer used
  to keep running regardless of the Bluetooth connection, so Home
  Assistant kept seeing a device that answered, just with nothing to
  play. Each speaker's renderer now stops as soon as a disconnect is
  detected and restarts once the speaker reconnects, so the entity
  reflects the real connection state. This only covers the native
  `media_player` (DLNA); the optional MPD server is the add-on's main
  process and can't be stopped the same way without stopping the add-on
  itself. Reported in
  [#6](https://github.com/dcybeldesign/ha-mpd-bluetooth-bridge/issues/6).
- Going back to "available" after a reconnect can be slow, or need a
  full Home Assistant **Core** restart, the same discovery limitation
  already described for a newly added speaker, see
  [Multiple speakers](README.md#multiple-speakers).

## 2.4.0
- Added a **pairing page**, contributed by [@cddu33](https://github.com/cddu33)
  in [#4](https://github.com/dcybeldesign/ha-mpd-bluetooth-bridge/pull/4)
  (ingress, administrators only): scan for nearby Bluetooth Classic audio
  devices, pair, trust and connect a speaker, then set it as the primary
  speaker or add it as an extra one. Open it with **Open Web UI** on the
  add-on's Info tab, or turn on **Show in sidebar** there to get a
  **Bluetooth Audio** panel in the sidebar. The add-on writes the chosen
  speaker into its own configuration through the Supervisor
  API and restarts by itself. First-time setup no longer needs the
  Terminal & SSH add-on and a `bluetoothctl` session; that manual
  procedure stays documented as a fallback, for speakers that ask for a
  PIN code, see [Pairing your speaker](README.md#pairing-your-speaker-first-time-setup).
- `bluetooth_mac` can now be left empty: the add-on then starts in setup
  mode (pairing page only, no MPD or `media_player` yet) instead of
  failing config validation.
- The pairing page's web server (busybox `httpd`) listens only on the
  internal Supervisor network and only accepts Home Assistant's ingress
  proxy: with `host_network`, it would otherwise be reachable,
  unauthenticated, from the whole LAN. No additional Supervisor API
  permission is requested (`hassio_api` stays off).
- Added the missing `extra_speakers` description to the Configuration tab.
- Fixed the monitoring loop reporting a connected speaker as disconnected
  every ~30 seconds, then retrying a connection that could only fail. The
  `bluetoothctl` and `pactl` outputs are now captured before being
  searched: piping them into `grep -q` under `pipefail` could make a
  line that was there read as missing.
- Each speaker's native `media_player` now listens on a fixed port: the
  primary speaker always on 49494, as before in practice, and each extra
  speaker on a port derived from its MAC address. Until now, the port
  went to whichever speaker started first, so after a restart with
  several speakers a Home Assistant entity could end up on the wrong
  speaker. Changing the primary speaker still moves the primary entity to
  the new primary speaker, see
  [Multiple speakers](README.md#multiple-speakers). When updating from
  2.3.0, each extra speaker moves to its new port once; its existing
  `media_player` entity follows it on its own, with nothing to
  reconfigure.

## 2.3.0
- Added multi-speaker support
  ([GitHub issue #3](https://github.com/dcybeldesign/ha-mpd-bluetooth-bridge/issues/3)):
  a new `extra_speakers` option (list of `{mac, name}`, editable straight
  from the Configuration tab, no YAML needed) lets you register
  additional Bluetooth speakers alongside the primary one. Each gets its
  own independent Bluetooth connection/monitoring loop, its own
  PulseAudio sink, and its own native `media_player` entity, so you can
  pick which speaker a given stream goes to. This is independently
  selectable outputs, not synchronized multi-room playback — see
  [Multiple speakers](README.md#multiple-speakers). MPD stays attached to
  the primary speaker only. Tested end-to-end on real hardware (two
  speakers, two independent simultaneous streams, verified through both
  Home Assistant and Music Assistant).

## 2.2.0
- Fixed a real-world failure mode reported via
  [GitHub issue #1](https://github.com/dcybeldesign/ha-mpd-bluetooth-bridge/issues/1):
  the speaker's PulseAudio sink could stay muted or at 0% volume
  indefinitely (even across reboots) with no visible error, if nothing
  else on the system had ever set it — the add-on never touched sink
  volume/mute itself, only the `a2dp_sink` profile (see 2.0.1). The
  monitoring loop now also unmutes the sink and restores it to
  `default_volume` whenever it's found silent, without ever overriding a
  volume you've deliberately set as long as it isn't 0%.
- Added `default_volume` option (default `70`): the level restored by the
  fix above. Configurable rather than hardcoded, since a safe volume
  varies a lot by speaker.
- Adopted `set -euo pipefail` in `run.sh` (suggested by a reader on the
  official HA forum): catches more failure modes than `set -e` alone.
  Verified bashio's own internals already run under the same strict mode.

## 2.1.0
- Renamed from **"Bluetooth Speaker MPD Bridge"** to **"Bluetooth Audio
  Bridge"** (slug `bluetooth_audio_bridge`, was `mpd_bluetooth_bridge`):
  the add-on is no longer MPD-only. This is a breaking change for
  existing installs: reinstall under the new slug and re-enter your
  speaker's MAC address. `description` updated to match; the GitHub repo
  URL itself was intentionally kept unchanged to preserve its existing
  stars/history.
- Added a **native `media_player` entity**, independent of MPD: the
  Bluetooth speaker is now exposed as a DLNA/UPnP renderer via
  [gmrender-resurrect](https://github.com/hzeller/gmrender-resurrect)
  (compiled from source, no Alpine package exists for it), auto-discovered
  by Home Assistant's built-in `dlna_dmr` integration over SSDP. Runs
  alongside MPD on the same PulseAudio sink; both can play at once.
  `gmediarender` is now given a `--uuid` derived from `bluetooth_mac`
  (stable per speaker, distinct across speakers): without it, every
  install advertised the same fixed default UUID, so two installs for
  two different speakers would collapse into a single `media_player`
  entity instead of two (found and fixed during real-hardware testing).
- Added `enable_mpd` option (default `true`): lets MPD be turned off
  entirely for users who only want the native `media_player` output. The
  Bluetooth connection and the native `media_player` are unaffected
  either way.
- Added `host_network: true`: required for SSDP multicast discovery of
  the native `media_player` to work, since it doesn't reliably cross
  Docker's default bridge network. Documented in the README with its own
  section, since it gives the add-on the same broad network access as
  add-ons like Tailscale or Terminal & SSH.
- Rewrote README.md / README.fr.md: new capabilities documented, a
  dedicated `host_network` disclosure section, and a Voice PE section
  scoped to what's actually possible today (scripted TTS announcements
  to the native `media_player` work; live conversational replies from a
  Voice PE device do not, that would require changes to the Voice PE's
  own firmware, tracked upstream in
  [home-assistant/discussions#689](https://github.com/orgs/home-assistant/discussions/689)).
  French README switched to the formal "vous" register.

## 2.0.1
- Fixed a real-world failure mode: after a burst of rapid Bluetooth
  disconnects/reconnects (e.g. a low-battery speaker), BlueZ could report
  the connection as stable again while PulseAudio's card profile stayed
  stuck on `off` instead of switching back to `a2dp_sink` — no audio sink
  existed, so MPD had nowhere to output sound, with no visible error on
  the Bluetooth side. The monitoring loop now also checks that the
  expected PulseAudio sink exists and forces the `a2dp_sink` profile back
  if it's missing, self-healing without requiring a manual SSH fix.

## 2.0.0
- Renamed from "MPD JBL Bridge" to **"Bluetooth Speaker MPD Bridge"** (slug
  `mpd_bluetooth_bridge`, was `mpd_jbl_bridge`) — the add-on works with any
  Bluetooth A2DP speaker, not just a JBL. This is a breaking change for
  anyone who had installed the earlier private v1: reinstall under the new
  slug and re-enter your speaker's MAC address.
- Removed all installation-specific defaults (Bluetooth MAC address).
  `bluetooth_mac` is now a required field with MAC-format validation
  (`match(...)` schema) instead of shipping with a real address as default.
- Added `speaker_name` option (cosmetic label shown in MPD for the output).
- Added `reconnect_interval` option (10–300s, default 30s) to control how
  often the add-on checks the Bluetooth connection.
- Added multi-architecture support (`aarch64`, `amd64`, `armv7`, `armhf`,
  `i386`) via `build.yaml`. Primarily developed and tested on a Raspberry
  Pi 4 (aarch64); other architectures use the same mechanism but haven't
  all been verified in real conditions — feedback welcome.
- Added English + French README, MIT license, this changelog.

## 1.0.0
- Initial working version (private, single installation): MPD server
  bridging Music Assistant to a JBL Flip 3 Bluetooth speaker via a
  Raspberry Pi 4's shared PulseAudio server and Bluetooth adapter.
- Fixed during development: base image tag (`3.19` doesn't exist, use
  `3.18`), missing `bluetoothctl` (wrong package, `bluez` not
  `bluez-deprecated`), MPD startup crash from an unused local music
  database, MPD player unreachable from Music Assistant when addressed by
  the host's external IP (Docker hairpin NAT — use the internal add-on
  hostname instead), and the actual root cause of persistent playback
  failure: the config template used `{{VAR}}` (Jinja/Mustache-style)
  placeholders instead of `${VAR}`, which `envsubst` doesn't expand.
