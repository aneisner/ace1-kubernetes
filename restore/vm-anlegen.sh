#!/usr/bin/env bash
# vm-anlegen.sh: legt auf einem Debian-Rechner mit libvirt/KVM eine VM an.
# Das Skript läuft auf dem Mac (oder einem anderen Linux-Rechner) und steuert den Host per SSH.
#
# Aufruf:
#   ./vm-anlegen.sh                 VM anlegen (fragt CPU, RAM, Platte, Netz und Image)
#   ./vm-anlegen.sh liste           vorhandene VMs und ihre Adressen zeigen
#   ./vm-anlegen.sh ip NAME         Adresse und Anmeldebefehl einer VM zeigen
#   ./vm-anlegen.sh loeschen NAME   VM samt Platte löschen
#
# Einstellungen per Umgebungsvariable vor dem Aufruf, zum Beispiel: VM_HOST=andererhost ./vm-anlegen.sh
#   VM_HOST   Rechner, auf dem die VMs laufen (Vorgabe: wsbr0.lan)
#   VM_USER   Benutzer auf dem Host und in der VM (Vorgabe: toni)
#   SSH_KEY   öffentlicher Schlüssel, der in die VM kommt (Vorgabe: ~/.ssh/id_ed25519.pub)
#   BRIDGE    Name der Bridge auf dem Host für die Netzvariante 2 (Vorgabe: bridge0)
#   Ohne Fragen (für andere Skripte): NONINTERACTIVE=1 ASSUME_YES=1 und die Werte per
#   VM_NAME, VM_CPUS, VM_RAM_GB, VM_DISK_GB, VM_NET (1|2), VM_IMG (1|2|3)
#   SSH_KEY_EXTRA  zweiter öffentlicher Schlüssel für die VM (zum Beispiel ein Wegwerf-Schlüssel für Hintergrundjobs)
#   DRY=1     zeigt nur, was auf dem Host laufen würde, und ändert nichts
#
# Voraussetzungen auf dem Host: libvirt, virt-install, qemu-img, curl und sudo-Rechte.

# -e: bei einem Fehler abbrechen, -u: unbekannte Variablen sind ein Fehler,
# -o pipefail: eine Pipe gilt als fehlgeschlagen, wenn irgendein Teil fehlschlägt
set -euo pipefail

# Einstellungen mit Vorgabewerten: ${NAME:-Vorgabe} nimmt die Vorgabe, wenn NAME nicht gesetzt ist
VM_HOST="${VM_HOST:-wsbr0.lan}"
VM_USER="${VM_USER:-toni}"
BRIDGE="${BRIDGE:-bridge0}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519.pub}"
IMG_DIR="/var/lib/libvirt/images"     # Ablageort der Platten auf dem Host
TARGET="$VM_USER@$VM_HOST"

# Eine SSH-Verbindung wiederverwenden: Das Passwort wird nur einmal abgefragt,
# alle weiteren ssh- und scp-Aufrufe laufen über dieselbe Verbindung (60 Sekunden nach dem letzten Aufruf).
SSH_OPTS=(-o ControlMaster=auto -o "ControlPath=/tmp/vm-anlegen-%r@%h" -o ControlPersist=60)

# Hilfsfunktionen -------------------------------------------------------------

# Fehlermeldung ausgeben und beenden
die() { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }

# Frage stellen: ask "Frage" Vorgabe. Die Antwort steht danach in $REPLY.
# Bei leerer Eingabe (nur Enter) gilt die Vorgabe.
# Mit NONINTERACTIVE=1 wird nicht gefragt, es gilt immer die Vorgabe (die wir aus VM_* übernehmen).
ask() {
  local a
  if [ "${NONINTERACTIVE:-0}" = 1 ]; then REPLY="$2"; echo "$1: $2"; return; fi
  read -r -p "$1 [$2]: " a
  REPLY="${a:-$2}"
}

# Prüfen, dass ein Wert eine positive ganze Zahl ist
num() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ] || die "'$1' ist keine positive Zahl"; }

# Auf dem Host einen Befehl mit Terminal ausführen (-t, damit sudo nach dem Passwort fragen kann)
remote() { ssh -t "${SSH_OPTS[@]}" "$TARGET" "$@"; }

# Adresse einer VM anzeigen und den passenden Anmeldebefehl ausgeben
zeige_ip() {
  local ip
  ip=$(remote "sudo virsh domifaddr '$1' --source lease 2>/dev/null | awk '/ipv4/ {print \$4}' | cut -d/ -f1 | head -1" | tr -d '\r')
  if [ -n "$ip" ]; then
    echo "Adresse von $1: $ip"
    echo "Anmelden über den Host:  ssh -J $TARGET $VM_USER@$ip"
  else
    echo "Noch keine Adresse für $1. Die VM startet vielleicht noch; in 30 Sekunden erneut: $0 ip $1"
  fi
}

# Befehl auswählen: ohne Angabe wird eine VM angelegt ---------------------------
case "${1:-anlegen}" in
  liste)
    remote "sudo virsh list --all; echo; sudo virsh net-dhcp-leases default"
    exit 0 ;;
  ip)
    [ -n "${2:-}" ] || die "Aufruf: $0 ip NAME"
    zeige_ip "$2"
    exit 0 ;;
  loeschen)
    NAME="${2:-}"; [ -n "$NAME" ] || die "Aufruf: $0 loeschen NAME"
    if [ "${ASSUME_YES:-0}" != 1 ]; then
      read -r -p "VM '$NAME' auf $VM_HOST samt Platte wirklich löschen? (ja/nein) " a
      [ "$a" = "ja" ] || die "Abgebrochen."
    fi
    # destroy schaltet die VM aus, undefine --remove-all-storage entfernt Definition und Platte
    remote "sudo virsh destroy '$NAME' 2>/dev/null; sudo virsh undefine '$NAME' --remove-all-storage && echo 'gelöscht.'"
    exit 0 ;;
  anlegen) ;;
  *) die "Unbekannter Befehl. Erlaubt: anlegen, liste, ip, loeschen" ;;
esac

# Eingaben ----------------------------------------------------------------------
[ -f "$SSH_KEY" ] || die "Schlüssel $SSH_KEY nicht gefunden. Setze SSH_KEY=/pfad/zu/schluessel.pub"
PUBKEY=$(cat "$SSH_KEY")
# Optional zweiter Schlüssel: kommt als weitere Zeile in authorized_keys (leere Zeile, wenn nicht gesetzt)
EXTRA_KEY_LINE=""
if [ -n "${SSH_KEY_EXTRA:-}" ]; then
  [ -f "$SSH_KEY_EXTRA" ] || die "SSH_KEY_EXTRA nicht gefunden: $SSH_KEY_EXTRA"
  EXTRA_KEY_LINE="      - $(cat "$SSH_KEY_EXTRA")"
fi

echo "VM anlegen auf $VM_HOST (Enter übernimmt die Vorgabe in eckigen Klammern)"
echo
ask "Name der VM" "${VM_NAME:-restore-test2}";  NAME="$REPLY"
[[ "$NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Name nur aus Kleinbuchstaben, Ziffern und Minus"
ask "CPU-Kerne" "${VM_CPUS:-2}";                CPUS="$REPLY";  num "$CPUS"
ask "RAM in GB" "${VM_RAM_GB:-4}";                RAMGB="$REPLY"; num "$RAMGB"
ask "Platte in GB" "${VM_DISK_GB:-30}";            DISK="$REPLY";  num "$DISK"
echo "Netz: 1 = NAT (VM nur über den Host erreichbar, einfach)"
echo "      2 = Bridge $BRIDGE (VM bekommt eine Adresse aus deinem LAN)"
ask "Netz" "${VM_NET:-1}";                     NETSEL="$REPLY"
echo "Image: 1 = Debian 13 (Standard)  2 = Debian 12 (Alternative)  3 = Ubuntu 24.04 (Alternative)"
ask "Image" "${VM_IMG:-1}";                    IMGSEL="$REPLY"

# Auswahl in konkrete Werte übersetzen
case "$NETSEL" in
  1) NETARG="network=default" ;;     # das NAT-Netz von libvirt
  2) NETARG="bridge=$BRIDGE" ;;      # die Bridge des Hosts
  *) die "Netz: 1 oder 2" ;;
esac
# OSID ist der Name im osinfo-Katalog; er hilft libvirt, passende Treiber und Einstellungen zu wählen
case "$IMGSEL" in
  1) IMG="debian-13-genericcloud-amd64.qcow2"; OSID="debian13"; OSFALL="debian12"
     URL="https://cloud.debian.org/images/cloud/trixie/latest/$IMG" ;;
  2) IMG="debian-12-genericcloud-amd64.qcow2"; OSID="debian12"; OSFALL="debian11"
     URL="https://cloud.debian.org/images/cloud/bookworm/latest/$IMG" ;;
  3) IMG="ubuntu-24.04-server-cloudimg-amd64.img"; OSID="ubuntu24.04"; OSFALL="ubuntu22.04"
     URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img" ;;
  *) die "Image: 1, 2 oder 3" ;;
esac

echo
echo "Zusammenfassung: $NAME, $CPUS CPU, ${RAMGB} GB RAM, ${DISK} GB Platte, $NETARG, $IMG, Host $VM_HOST"
if [ "${ASSUME_YES:-0}" != 1 ]; then read -r -p "Anlegen? (j/n) " a; [ "$a" = "j" ] || die "Abgebrochen."; fi

# Dateien erzeugen, die auf den Host kopiert werden ---------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT      # das Arbeitsverzeichnis wird beim Beenden immer gelöscht

# cloud-init: Diese Datei konfiguriert die VM beim ersten Start (Name, Benutzer, SSH-Schlüssel, Pakete)
cat > "$TMP/user-data" <<EOF
#cloud-config
hostname: $NAME
manage_etc_hosts: true
users:
  - name: $VM_USER
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - $PUBKEY
$EXTRA_KEY_LINE
package_update: true
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable --now qemu-guest-agent || true
EOF

# Skript, das auf dem Host (als root) abläuft. Variablen mit \$ werden erst auf dem Host ausgewertet,
# Variablen ohne \ werden schon hier eingesetzt.
cat > "$TMP/remote.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
NAME='$NAME'; CPUS='$CPUS'; RAM=\$(( $RAMGB * 1024 )); DISK='$DISK'
NETARG='$NETARG'; IMG='$IMG'; URL='$URL'; OSID='$OSID'; OSFALL='$OSFALL'; DIR='$IMG_DIR'

command -v virt-install >/dev/null || { echo "virt-install fehlt: sudo apt install virt-install libvirt-daemon-system"; exit 1; }
if virsh dominfo "\$NAME" >/dev/null 2>&1; then echo "Eine VM namens \$NAME gibt es schon."; exit 1; fi

# Basis-Image nur laden, wenn es noch nicht da ist
if [ ! -f "\$DIR/\$IMG" ]; then echo "Lade \$IMG ..."; curl -fL -o "\$DIR/\$IMG" "\$URL"; fi

# Eigene Platte, die auf dem Basis-Image aufbaut (spart Platz); die Größe wird beim ersten Start automatisch genutzt
qemu-img create -q -f qcow2 -F qcow2 -b "\$DIR/\$IMG" "\$DIR/\$NAME.qcow2" "\${DISK}G"
install -m 644 /tmp/\$NAME-user-data "\$DIR/\$NAME-user-data"

# OS-Name aus dem osinfo-Katalog wählen: erst der genaue Name, dann der Vorgänger, zuletzt "generic".
# osinfo-query gibt auch bei unbekanntem Namen Erfolg zurück (nur die Kopfzeilen), darum zählen wir die Zeilen.
OSARG="generic"
for cand in "\$OSID" "\$OSFALL"; do
  if command -v osinfo-query >/dev/null && [ "\$(osinfo-query os short-id="\$cand" -f short-id 2>/dev/null | tail -n +3 | wc -l)" -gt 0 ]; then
    OSARG="\$cand"; break
  fi
done
echo "OS-Eintrag: \$OSARG"

# Die Konfiguration entspricht der, die auf diesem Host nachweislich bootet:
#  - q35 ist der moderne Maschinentyp (der Vorgänger i440fx ließ ein Debian-13-Image beim Booten hängen)
#  - virtio-rng liefert dem Gast Zufallszahlen (sonst kann der Start auf Entropie warten)
#  - Spice-Grafik und virtio-Grafikkarte: im Cockpit sieht man den Bildschirm der VM
#  - Platte und Netzkarte als virtio, weil die schlanken Cloud-Images nur virtio-Treiber haben
virt-install --name "\$NAME" --vcpus "\$CPUS" --memory "\$RAM" --machine q35 \\
  --disk "path=\$DIR/\$NAME.qcow2,bus=virtio" --import --osinfo "\$OSARG" \\
  --network "\$NETARG,model=virtio" \\
  --rng /dev/urandom --graphics spice,listen=127.0.0.1 --video virtio --noautoconsole \\
  --cloud-init user-data="\$DIR/\$NAME-user-data"

# Auf die Adresse warten (bis zu 3 Minuten): der erste Start dauert, bis die VM per DHCP eine Adresse holt
echo "Warte auf die Adresse der VM ..."
IP=""
for i in \$(seq 1 90); do
  # virt-install fährt die VM nach dem ersten cloud-init-Lauf selbst herunter (Ende der "Installation").
  # Weil wir mit --noautoconsole nicht darauf warten, starten wir sie hier wieder.
  if [ "\$(LC_ALL=C virsh domstate "\$NAME")" = "shut off" ]; then echo "VM ist nach dem ersten Start heruntergefahren, starte sie neu ..."; virsh start "\$NAME" >/dev/null; fi
  IP=\$(virsh domifaddr "\$NAME" --source lease 2>/dev/null | awk '/ipv4/ {print \$4}' | cut -d/ -f1 | head -1 || true)
  [ -n "\$IP" ] && break
  sleep 2
done
if [ -n "\$IP" ]; then echo "IP:\$IP"; else echo "IP:unbekannt"; fi
EOF

if [ "${DRY:-0}" = 1 ]; then
  echo "--- user-data ---"; cat "$TMP/user-data"
  echo "--- remote.sh ---"; cat "$TMP/remote.sh"
  exit 0
fi

# Auf den Host kopieren und dort als root ausführen --------------------------------
scp -q "${SSH_OPTS[@]}" "$TMP/user-data" "$TARGET:/tmp/$NAME-user-data"
scp -q "${SSH_OPTS[@]}" "$TMP/remote.sh" "$TARGET:/tmp/$NAME-remote.sh"
OUT=$(remote "sudo bash /tmp/$NAME-remote.sh; rm -f /tmp/$NAME-remote.sh /tmp/$NAME-user-data" | tee /dev/stderr)
IP=$(printf '%s' "$OUT" | tr -d '\r' | awk -F: '/^IP:/ {print $2}' | tail -1)

echo
echo "Fertig. VM '$NAME' läuft (cloud-init braucht noch etwa eine Minute für Pakete und Benutzer)."
if [[ -n "$IP" && "$IP" != unbekannt* ]]; then
  if [ "$NETSEL" = 1 ]; then
    # Bei NAT ist die VM nur über den Host erreichbar: -J springt über den Host
    echo "Anmelden vom Mac aus, über den Host:  ssh -J $TARGET $VM_USER@$IP"
    echo "Dateien kopieren:                     scp -o ProxyJump=$TARGET Datei $VM_USER@$IP:"
  else
    echo "Anmelden:  ssh $VM_USER@$IP"
  fi
else
  echo "Die Adresse ist noch nicht bekannt. In einer Minute:  $0 ip $NAME"
fi
echo "Löschen später:  $0 loeschen $NAME"
