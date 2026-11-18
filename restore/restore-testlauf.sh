#!/usr/bin/env bash
# restore-testlauf.sh: Restore-Test vom Mac aus, ohne sich in der VM anzumelden.
#
# Ablauf:
#   1. prüft, ob Repository, Secrets-Backup und Dump vorhanden sind
#   2. legt mit vm-anlegen.sh auf dem Host (wsbr0.lan) eine frische VM an
#   3. kopiert Repository, Secrets und Dump in die VM und schreibt restore.conf mit den passenden Adressen
#   4. startet restore-paperless.sh in der VM und zeigt die Ausgabe
#
# Zwei Betriebsarten:
#   Vordergrund (Vorgabe): Das Skript läuft auf dem Mac und zeigt alles live. Mac aus oder Verbindung weg = Abbruch.
#   Hintergrund (--hintergrund): Nur das Anlegen der VM läuft auf dem Mac (dafür braucht es das sudo-Passwort).
#     Alles andere übernimmt ein Job auf dem Host wsbr0.lan. Er läuft weiter, auch wenn du die VPN-Verbindung
#     trennst oder den Mac ausschaltest, und schreibt ein Protokoll auf wsbr0.lan.
#
# Aufruf (im Ordner restore/):
#   ./restore-testlauf.sh                       Vordergrund, VM bleibt danach stehen
#   ./restore-testlauf.sh --loeschen            Vordergrund, VM nach erfolgreichem Test löschen
#   ./restore-testlauf.sh --zweimal             Restore danach ein zweites Mal in derselben VM (Wiederholbarkeit)
#   ./restore-testlauf.sh --hintergrund         Job auf wsbr0.lan starten und sofort zurückkehren
#   ./restore-testlauf.sh --status [NAME]       Stand des letzten (oder des genannten) Hintergrundjobs zeigen
#   ./restore-testlauf.sh --log [NAME]          Protokoll des Jobs live mitlesen (Strg+C beendet nur das Mitlesen)
#   ./restore-testlauf.sh NAME                  eigener VM-Name (Vorgabe: restore-test-<Monat><Tag>-<Uhrzeit>)
#   Die Optionen lassen sich kombinieren, zum Beispiel: ./restore-testlauf.sh --hintergrund --zweimal
#
# Einstellungen per Umgebungsvariable (Vorgaben in Klammern):
#   SECRETS_DIR (~/secrets-backup)  DUMP_FILE (~/paperless-latest.dump)  REPO_DIR (Ordner über restore/)
#   VM_HOST (wsbr0.lan)  VM_USER (toni)  VM_CPUS (2)  VM_RAM_GB (4)  VM_DISK_GB (30)
set -euo pipefail

# Pfade: SCRIPT_DIR ist der Ordner dieses Skripts, REPO_DIR das Repository darüber
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${REPO_DIR:-$(dirname "$SCRIPT_DIR")}"
SECRETS_DIR="${SECRETS_DIR:-$HOME/secrets-backup}"
DUMP_FILE="${DUMP_FILE:-$HOME/paperless-latest.dump}"
VM_HOST="${VM_HOST:-wsbr0.lan}"
VM_USER="${VM_USER:-toni}"
TARGET="$VM_USER@$VM_HOST"
JOBS_DIR="restore-jobs"          # Ordner auf dem Host, relativ zum Home des Benutzers

die() { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }
log() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

# Argumente lesen: Optionen schalten Funktionen ein, alles andere gilt als VM-Name
LOESCHEN=0; ZWEIMAL=0; HINTERGRUND=0; AKTION="start"; NAME=""
for arg in "$@"; do
  case "$arg" in
    --loeschen)    LOESCHEN=1 ;;
    --zweimal)     ZWEIMAL=1 ;;
    --hintergrund) HINTERGRUND=1 ;;
    --status)      AKTION="status" ;;
    --log)         AKTION="log" ;;
    -*) die "Unbekannte Option: $arg" ;;
    *)  NAME="$arg" ;;
  esac
done

# --- Status und Protokoll eines Hintergrundjobs ------------------------------------------------
# Der Job schreibt in ~/restore-jobs/NAME/ auf dem Host: job.log (Protokoll) und job.status (Stand).
# Ohne NAME nehmen wir den zuletzt angelegten Job.
if [ "$AKTION" != "start" ]; then
  FIND='D=$HOME/'"$JOBS_DIR"'; N="'"$NAME"'"; [ -n "$N" ] || N=$(ls -t "$D" 2>/dev/null | head -1); [ -n "$N" ] || { echo "Keine Jobs gefunden."; exit 1; }; D="$D/$N"'
  if [ "$AKTION" = "status" ]; then
    ssh "$TARGET" "$FIND; echo \"Job:    \$N\"; echo \"Stand:  \$(cat \$D/job.status 2>/dev/null || echo unbekannt)\"; echo \"VM:     \$(cat \$D/job.vmip 2>/dev/null)\"; echo; tail -n 15 \$D/job.log"
  else
    ssh -t "$TARGET" "$FIND; tail -n 40 -f \$D/job.log"
  fi
  exit 0
fi

NAME="${NAME:-restore-test-$(date +%m%d-%H%M)}"
LOG="$SCRIPT_DIR/restore-testlauf-$NAME.log"

# tar auf dem Mac (bsdtar) packt Apple-Metadaten ein, die Linux-tar mit Warnungen quittiert.
# Wenn tar diese Optionen kennt, schalten wir die Metadaten ab; auf Linux bleibt die Liste leer.
TAR_OPTS=()
if tar --no-xattrs --no-mac-metadata -cf /dev/null /dev/null 2>/dev/null; then TAR_OPTS=(--no-xattrs --no-mac-metadata); fi

# --- 1. Eingaben prüfen, bevor wir eine VM anlegen
log "1. Eingaben prüfen"
[ -x "$SCRIPT_DIR/vm-anlegen.sh" ]                || die "vm-anlegen.sh fehlt oder ist nicht ausführbar (chmod +x)"
[ -f "$SCRIPT_DIR/restore-paperless.sh" ]         || die "restore-paperless.sh fehlt"
[ -f "$SCRIPT_DIR/restore.conf.example" ]         || die "restore.conf.example fehlt"
[ -f "$SECRETS_DIR/homelab-ca-secret.yaml" ]      || die "Secrets fehlen in $SECRETS_DIR"
[ -f "$SECRETS_DIR/paperless-secrets.yaml" ]      || die "paperless-secrets.yaml fehlt in $SECRETS_DIR"
[ -f "$DUMP_FILE" ]                               || die "Dump fehlt: $DUMP_FILE"
echo "Repository: $REPO_DIR"; echo "Secrets:    $SECRETS_DIR"; echo "Dump:       $DUMP_FILE"; echo "VM-Name:    $NAME"
[ "$HINTERGRUND" = 1 ] && echo "Modus:      Hintergrund (Job auf $VM_HOST)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT      # Arbeitsverzeichnis (enthält im Hintergrundmodus einen Wegwerf-Schlüssel) immer löschen

# Im Hintergrundmodus bekommt die VM zusätzlich einen Wegwerf-Schlüssel. Mit ihm meldet sich der Job auf
# dem Host an der VM an; deinen eigenen Schlüssel müsste man sonst auf den Host kopieren, das wollen wir nicht.
# Der Schlüssel gilt nur für diese Test-VM und wird vom Job am Ende gelöscht.
EXTRA_ENV=()
if [ "$HINTERGRUND" = 1 ]; then
  ssh-keygen -q -t ed25519 -N '' -C "restore-job-$NAME" -f "$TMP/jobkey"
  EXTRA_ENV=(SSH_KEY_EXTRA="$TMP/jobkey.pub")
fi

# --- 2. VM anlegen (ohne Fragen). vm-anlegen.sh fragt nur noch nach dem sudo-Passwort des Hosts.
log "2. VM $NAME anlegen"
# Die Ausgabe zeigen wir live und merken sie uns in einer Datei, denn darin steht die Adresse der VM
# (Zeile "IP:192.168.122.x"). Eine zweite Abfrage per ssh+sudo wäre nicht nötig und würde nochmal nach dem
# Passwort fragen, und zwar unsichtbar, weil die Ausgabe abgefangen wird.
env NONINTERACTIVE=1 ASSUME_YES=1 VM_NAME="$NAME" ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} "$SCRIPT_DIR/vm-anlegen.sh" 2>&1 | tee "$TMP/anlegen.out"
IP=$(tr -d '\r' < "$TMP/anlegen.out" | awk -F: '/^IP:/ {print $2}' | tail -1)
[[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Keine Adresse für $NAME erhalten. Prüfe: ./vm-anlegen.sh ip $NAME"
echo "Adresse der VM: $IP"
PREFIX="${IP%.*}"

# Pfade in der VM: das Repository liegt unter seinem Ordnernamen im Home, die Secrets ebenso.
REPO_VM="\$HOME/$(basename "$REPO_DIR")"
SECRETS_VM="\$HOME/$(basename "$SECRETS_DIR")"

# Skript für die VM, das restore.conf schreibt: Adressen aus dem Netz der VM, lokaler Speicher (kein NAS im Test).
# Es läuft in der VM, die Variablen mit \$ werden erst dort ausgewertet.
cat > "$TMP/conf.sh" <<EOF
set -e
cd $REPO_VM/restore
cp restore.conf.example restore.conf
sed -i \\
  -e 's|^NODE_NAME=.*|NODE_NAME="$NAME"|' \\
  -e 's|^NODE_IP=.*|NODE_IP="$IP"|' \\
  -e 's|^METALLB_RANGE=.*|METALLB_RANGE="$PREFIX.240-$PREFIX.250"|' \\
  -e 's|^TRAEFIK_IP=.*|TRAEFIK_IP="$PREFIX.240"|' \\
  -e 's|^STORAGE=.*|STORAGE="local"|' \\
  -e 's|^REPO_DIR=.*|REPO_DIR="$REPO_VM"|' \\
  -e 's|^SECRETS_DIR=.*|SECRETS_DIR="$SECRETS_VM"|' restore.conf
chmod +x restore-paperless.sh
EOF

# ============================================================================================
# HINTERGRUND: Dateien auf den Host legen, Job dort starten, zurückkehren
# ============================================================================================
if [ "$HINTERGRUND" = 1 ]; then
  log "3. Job auf $VM_HOST vorbereiten"
  # Archive auf dem Mac packen (ein Archiv je Verzeichnis, .git lassen wir weg)
  tar -czf "$TMP/repo.tgz"    ${TAR_OPTS[@]+"${TAR_OPTS[@]}"} --exclude=.git -C "$(dirname "$REPO_DIR")" "$(basename "$REPO_DIR")"
  tar -czf "$TMP/secrets.tgz" ${TAR_OPTS[@]+"${TAR_OPTS[@]}"} -C "$(dirname "$SECRETS_DIR")" "$(basename "$SECRETS_DIR")"
  cp "$DUMP_FILE" "$TMP/paperless-latest.dump"
  echo "$IP" > "$TMP/job.vmip"; echo "LÄUFT (vorbereitet)" > "$TMP/job.status"

  # Das Skript, das auf dem Host läuft. Es verbindet sich direkt mit der VM (gleiches NAT-Netz, kein Sprung nötig).
  cat > "$TMP/job.sh" <<EOF
#!/usr/bin/env bash
# job.sh: läuft auf $VM_HOST im Hintergrund und führt den Restore-Test in der VM $NAME aus.
cd "\$(dirname "\$0")"
STATUS() { echo "\$1" > job.status; }
# Am Ende (egal wie) Secrets, Dump und Wegwerf-Schlüssel auf dem Host löschen: Dort sollen sie nicht liegen bleiben
trap 'rm -f jobkey jobkey.pub repo.tgz secrets.tgz paperless-latest.dump conf.sh' EXIT
vm() { ssh -i ./jobkey -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 $VM_USER@$IP "\$@"; }
echo "Job gestartet: \$(date)  VM: $NAME ($IP)"
STATUS "LÄUFT: warte auf die VM"
for i in \$(seq 1 60); do vm true 2>/dev/null && break; [ "\$i" = 60 ] && { STATUS "FEHLER: VM nicht erreichbar"; exit 1; }; sleep 5; done
vm 'cloud-init status --wait' || true
STATUS "LÄUFT: Dateien kopieren"
cat repo.tgz    | vm 'tar xzf -'
cat secrets.tgz | vm 'tar xzf -'
cat paperless-latest.dump | vm 'cat > paperless-latest.dump'
vm 'bash -s' < conf.sh
STATUS "LÄUFT: Restore (Lauf 1)"
vm "cd $REPO_VM/restore && ./restore-paperless.sh" 2>&1; RC=\$?
if [ \$RC -eq 0 ] && [ "$ZWEIMAL" = 1 ]; then
  echo; echo "== Zweiter Lauf in derselben VM =="
  STATUS "LÄUFT: Restore (Lauf 2)"
  vm "cd $REPO_VM/restore && ./restore-paperless.sh" 2>&1; RC=\$?
  [ \$RC -eq 0 ] && echo "Zweiter Lauf: OK" || echo "Zweiter Lauf: FEHLER (Code \$RC)"
fi
echo
if [ \$RC -eq 0 ]; then
  STATUS "FERTIG: OK (\$(date '+%d.%m. %H:%M'))"
  echo "== ERFOLG: Restore in der VM $NAME ist durchgelaufen =="
else
  STATUS "FEHLER: Restore endete mit Code \$RC (\$(date '+%d.%m. %H:%M'))"
  echo "== FEHLER: Restore endete mit Code \$RC =="
fi
echo "VM bleibt stehen. Löschen später auf dem Mac: ./vm-anlegen.sh loeschen $NAME"
exit \$RC
EOF

  # Auf den Host kopieren und dort starten. setsid + nohup + umgeleitete Ein-/Ausgabe: Der Job gehört danach
  # keiner SSH-Sitzung mehr und läuft weiter, auch wenn du dich abmeldest oder die VPN-Verbindung trennst.
  ssh "$TARGET" "mkdir -p \$HOME/$JOBS_DIR/$NAME && chmod 700 \$HOME/$JOBS_DIR/$NAME"
  chmod 600 "$TMP/jobkey"
  for f in job.sh jobkey jobkey.pub repo.tgz secrets.tgz paperless-latest.dump conf.sh job.vmip job.status; do
    scp -q "$TMP/$f" "$TARGET:$JOBS_DIR/$NAME/$f"
  done
  ssh "$TARGET" "cd \$HOME/$JOBS_DIR/$NAME && chmod 600 jobkey && chmod +x job.sh && setsid nohup ./job.sh > job.log 2>&1 < /dev/null & sleep 1; echo gestartet"

  log "Der Job läuft jetzt auf $VM_HOST im Hintergrund"
  echo "Name:       $NAME  (VM-Adresse $IP)"
  echo "Protokoll:  $VM_HOST:~/$JOBS_DIR/$NAME/job.log"
  echo
  echo "Stand ansehen:     ./restore-testlauf.sh --status"
  echo "Live mitlesen:     ./restore-testlauf.sh --log"
  echo "Dauer:             etwa 5 Minuten (zweimal: etwa 8)"
  echo "Aufräumen später:  ./vm-anlegen.sh loeschen $NAME"
  exit 0
fi

# ============================================================================================
# VORDERGRUND: alles von hier aus, mit Live-Ausgabe
# ============================================================================================
# SSH-Einstellungen für die Test-VM: Sprung über den Host (-J), weil die VM im NAT-Netz liegt.
# Die Host-Schlüssel prüfen wir nicht, weil neue Test-VMs oft die Adresse alter VMs bekommen
# und sonst eine Warnung "REMOTE HOST IDENTIFICATION HAS CHANGED" kommt. Nur für Testmaschinen verwenden!
SSH_OPTS=(-J "$TARGET" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
vm() { ssh "${SSH_OPTS[@]}" "$VM_USER@$IP" "$@"; }

# --- 3. Warten, bis die VM erreichbar und cloud-init fertig ist
log "3. Auf die VM warten"
for i in $(seq 1 40); do
  vm true 2>/dev/null && break
  [ "$i" = 40 ] && die "VM per SSH nicht erreichbar"
  sleep 5
done
vm 'cloud-init status --wait' || true

# --- 4. Dateien kopieren und restore.conf schreiben
log "4. Dateien in die VM kopieren"
# tar über SSH: ohne Zwischendatei. Das .git-Verzeichnis lassen wir weg (nicht nötig und groß).
COPYFILE_DISABLE=1 tar -czf - ${TAR_OPTS[@]+"${TAR_OPTS[@]}"} --exclude=.git -C "$(dirname "$REPO_DIR")" "$(basename "$REPO_DIR")" | vm 'tar xzf -'
COPYFILE_DISABLE=1 tar -czf - ${TAR_OPTS[@]+"${TAR_OPTS[@]}"} -C "$(dirname "$SECRETS_DIR")" "$(basename "$SECRETS_DIR")" | vm 'tar xzf -'
scp -q "${SSH_OPTS[@]}" "$DUMP_FILE" "$VM_USER@$IP:paperless-latest.dump"
vm 'bash -s' < "$TMP/conf.sh"

# --- 5. Restore ausführen. Die Ausgabe geht auf den Bildschirm und ins Protokoll.
# PIPESTATUS[0] ist der Rückgabewert des Restores (nicht von tee).
log "5. Restore läuft (Protokoll: $LOG)"
set +e
vm "cd $REPO_VM/restore && ./restore-paperless.sh" 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}
set -e

# Optional: derselbe Restore noch einmal in derselben VM. Er muss ohne Fehler durchlaufen und darf nichts
# überschreiben (vorhandene Secrets, Datenbank mit Daten). Das Ergebnis hängen wir ans Protokoll an.
if [ "$RC" -eq 0 ] && [ "$ZWEIMAL" = 1 ]; then
  log "5b. Zweiter Lauf in derselben VM (Test der Wiederholbarkeit)"
  set +e
  vm "cd $REPO_VM/restore && ./restore-paperless.sh" 2>&1 | tee -a "$LOG"
  RC=${PIPESTATUS[0]}
  set -e
  [ "$RC" -eq 0 ] && echo "Zweiter Lauf: OK" || echo "Zweiter Lauf: FEHLER (Code $RC)"
fi

# --- 6. Ergebnis und Aufräumen
if [ "$RC" -eq 0 ]; then
  log "ERFOLG: Restore in der VM $NAME ist durchgelaufen"
  grep -E "Fertig nach|Dokumente in der Datenbank|HTTPS auf" "$LOG" | tail -3
  if [ "$LOESCHEN" = 1 ]; then
    log "VM löschen"
    ASSUME_YES=1 "$SCRIPT_DIR/vm-anlegen.sh" loeschen "$NAME"
  else
    echo
    echo "Die VM bleibt stehen: ssh -J $TARGET $VM_USER@$IP"
    echo "Dort liegen noch Secrets und Dump. Löschen mit: ./vm-anlegen.sh loeschen $NAME"
  fi
else
  log "FEHLER: Restore ist mit Code $RC beendet"
  echo "Die VM bleibt zur Fehlersuche stehen: ssh -J $TARGET $VM_USER@$IP"
  echo "Protokoll: $LOG"
  exit "$RC"
fi
