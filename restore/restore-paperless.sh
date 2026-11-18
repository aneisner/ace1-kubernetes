#!/usr/bin/env bash
# restore-paperless.sh: baut k3s mit Paperless-ngx auf einem frischen
# Debian-13-Rechner wieder auf.
#
# Voraussetzungen (die du mitbringen musst, das Skript kann sie nicht
# erfinden):
#   1. ein frisches Debian 13 mit sudo-Rechten und Internetzugang
#   2. das Git-Repository mit den YAML-Dateien (REPO_DIR)
#   3. das Secrets-Backup: homelab-ca-secret.yaml und
#      paperless-secrets.yaml (SECRETS_DIR)
#   4. ein Dump der Datenbank im Format "pg_dump -Fc" (DUMP_FILE)
#
# Aufruf:
#   cp restore.conf.example restore.conf    # Werte anpassen
#   ./restore-paperless.sh --dry-run        # nur prüfen, nichts ändern
#   ./restore-paperless.sh                  # ausführen
#
# Ein zweiter Lauf macht nichts kaputt: helm upgrade --install und
# kubectl apply sind wiederholbar, vorhandene Secrets bleiben
# unberührt, der Dump wird nur in eine leere Datenbank eingespielt.
# Auf einem Rechner, auf dem Paperless schon Dokumente hat, bricht das
# Skript ab, außer du setzt FORCE=1.
set -euo pipefail

# --dry-run: nur prüfen, ob alle Eingaben da sind, nichts verändern
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

# Einstellungen laden: restore.conf neben dem Skript (oder der Pfad aus
# der Variablen CONF). ". Datei" liest die Datei in diese Shell ein.
CONF="${CONF:-$(dirname "$0")/restore.conf}"
if [ ! -f "$CONF" ]; then
  echo "FEHLER: $CONF fehlt (restore.conf.example kopieren)"
  exit 1
fi
# shellcheck disable=SC1090
. "$CONF"

# Pflichtvariablen: ${NAME:?} bricht ab, wenn NAME leer oder nicht gesetzt ist
: "${K3S_VERSION:?}" "${HELM_VERSION:?}" "${METALLB_VERSION:?}"
: "${TRAEFIK_VERSION:?}" "${CERTMANAGER_VERSION:?}"
: "${NODE_NAME:?}" "${NODE_IP:?}" "${METALLB_RANGE:?}"
: "${TRAEFIK_IP:?}" "${SITE_HOST:?}"
: "${REPO_DIR:?}" "${SECRETS_DIR:?}" "${DUMP_FILE:?}" "${STORAGE:?}"
FORCE="${FORCE:-0}"
START=$(date +%s)

# Hilfsfunktionen. log schreibt eine fette Überschrift (macht die Ausgabe
# lesbar), die gibt eine rote Fehlermeldung aus und beendet das Skript.
log() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
die() { printf '\033[31mFEHLER: %s\033[0m\n' "$*" >&2; exit 1; }

# wait_for "Beschreibung" Sekunden Befehl...
# Wiederholt den Befehl alle 5 Sekunden, bis er gelingt, und bricht nach
# der Höchstzeit ab. Kubernetes braucht nach vielen Schritten ein paar
# Sekunden, bis etwas bereit ist; so warten wir, statt blind zu schlafen.
wait_for() {
  local what="$1" max="$2" i=0
  shift 2
  until "$@" >/dev/null 2>&1; do
    i=$((i+5))
    [ "$i" -ge "$max" ] && die "Zeitüberschreitung bei: $what"
    sleep 5
  done
}

# Abkürzungen: kc für kubectl, need prüft, ob eine Datei da ist,
# sql fragt die Paperless-Datenbank im Pod postgres-0
kc() { kubectl "$@"; }
need() { [ -f "$1" ] || die "Datei fehlt: $1"; }
sql() {
  kc exec -n paperless postgres-0 -- \
    psql -U paperless -d paperless -Atc "$1"
}

# ------------------------------------------------------------------
# 0. Vorabprüfung (läuft immer, auch bei --dry-run)
# Alles, was wir brauchen, muss da sein, bevor wir etwas verändern.
# Besser jetzt abbrechen als nach drei Minuten Installation.
preflight() {
  log "0. Vorabprüfung"
  [ -d "$REPO_DIR" ] || die "REPO_DIR nicht gefunden: $REPO_DIR"
  need "$REPO_DIR/ca.yaml"
  need "$REPO_DIR/metallb-config.yaml"
  need "$REPO_DIR/traefik-values.yaml"
  need "$SECRETS_DIR/homelab-ca-secret.yaml"
  need "$SECRETS_DIR/paperless-secrets.yaml"
  need "$DUMP_FILE"
  case "$STORAGE" in
    nfs) need "$REPO_DIR/paperless/10-storage-nfs.yaml" ;;
    local) ;;
    *) die "STORAGE muss nfs oder local sein" ;;
  esac
  command -v sudo >/dev/null || die "sudo fehlt"
  # Läuft hier schon ein Paperless mit Daten? Dann nicht weitermachen.
  if command -v kubectl >/dev/null 2>&1 \
     && kubectl get ns paperless >/dev/null 2>&1; then
    DOCS=$(sql "select count(*) from documents_document" 2>/dev/null || echo 0)
    if [ "${DOCS:-0}" != "0" ] && [ "$FORCE" != "1" ]; then
      die "Hier läuft schon Paperless mit $DOCS Dokumenten (FORCE=1 erzwingt es)"
    fi
  fi
  echo "Alle Dateien vorhanden. k3s $K3S_VERSION, Knoten $NODE_NAME" \
       "($NODE_IP), Speicher: $STORAGE"
  echo "Dump: $(sha256sum "$DUMP_FILE" | cut -d' ' -f1)  $DUMP_FILE"
}

# ------------------------------------------------------------------
# Schritt 1: k3s installieren. Die Konfiguration schreiben wir vorher,
# weil k3s sie beim Start liest:
#  - Traefik und servicelb aus: wir bringen eigene mit (Traefik per
#    Helm, MetalLB für die Adressen)
#  - tls-san: Namen und Adresse, unter denen der API-Server erreichbar ist
#  - secrets-encryption: Secrets liegen verschlüsselt in der Datenbank
# Die Version ist festgelegt (INSTALL_K3S_VERSION), damit der Restore
# denselben Stand baut wie das Original.
step_k3s() {
  log "1. k3s $K3S_VERSION"
  sudo apt-get update -qq
  sudo apt-get install -y -qq curl ca-certificates openssl >/dev/null
  if ! command -v k3s >/dev/null 2>&1; then
    sudo mkdir -p /etc/rancher/k3s
    sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<EOF
write-kubeconfig-mode: "0600"
disable:
  - traefik
  - servicelb
tls-san:
  - $NODE_NAME
  - $NODE_IP
secrets-encryption: true
EOF
    curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh
    sudo INSTALL_K3S_VERSION="$K3S_VERSION" sh /tmp/k3s-install.sh
  else
    echo "k3s ist schon installiert: $(k3s --version | head -1)"
  fi
  # Der kubectl von k3s liest ~/.kube/config nicht von selbst, darum
  # kopieren wir die Zugangsdatei und setzen KUBECONFIG.
  wait_for "k3s-Zugangsdatei" 120 sudo test -s /etc/rancher/k3s/k3s.yaml
  mkdir -p "$HOME/.kube"
  sudo cat /etc/rancher/k3s/k3s.yaml > "$HOME/.kube/config"
  chmod 600 "$HOME/.kube/config"
  export KUBECONFIG="$HOME/.kube/config"
  wait_for "Knoten Ready" 180 sh -c "kubectl get nodes | grep -q ' Ready'"
  kc get nodes
}

# Schritt 2: Helm als Archiv laden und vor der Installation die
# Prüfsumme kontrollieren
step_helm() {
  log "2. Helm $HELM_VERSION"
  if command -v helm >/dev/null 2>&1 \
     && helm version --short | grep -q "^v${HELM_VERSION}"; then
    echo "Helm ist schon da: $(helm version --short)"
    return
  fi
  local tgz="helm-v${HELM_VERSION}-linux-amd64.tar.gz" tmp
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/$tgz" "https://get.helm.sh/$tgz"
  curl -fsSL -o "$tmp/$tgz.sha256sum" "https://get.helm.sh/$tgz.sha256sum"
  (cd "$tmp" && sha256sum -c "$tgz.sha256sum")
  tar -xzf "$tmp/$tgz" -C "$tmp"
  sudo install "$tmp/linux-amd64/helm" /usr/local/bin/helm
  helm version --short
}

# Schritt 3: MetalLB verteilt Adressen aus einem Bereich an Dienste vom
# Typ LoadBalancer. Den Bereich aus restore.conf setzen wir mit sed in
# die Datei aus dem Repository ein.
step_metallb() {
  log "3. MetalLB $METALLB_VERSION"
  helm repo add metallb https://metallb.github.io/metallb >/dev/null 2>&1 || true
  helm repo update >/dev/null
  kc create namespace metallb-system --dry-run=client -o yaml | kc apply -f -
  kc label namespace metallb-system --overwrite \
    pod-security.kubernetes.io/enforce=privileged
  helm upgrade --install metallb metallb/metallb \
    --version "$METALLB_VERSION" -n metallb-system
  kc rollout status deployment/metallb-controller \
    -n metallb-system --timeout=300s
  sed -E "s|(- )[0-9.]+-[0-9.]+|\1${METALLB_RANGE}|" \
    "$REPO_DIR/metallb-config.yaml" > /tmp/metallb-config.yaml
  wait_for "MetalLB-Webhook" 120 kubectl apply -f /tmp/metallb-config.yaml
  kc get ipaddresspools,l2advertisements -n metallb-system
}

# Schritt 4: Traefik ist der Ingress, also der Eingang für HTTPS.
# Er bekommt die feste Adresse TRAEFIK_IP.
step_traefik() {
  log "4. Traefik $TRAEFIK_VERSION"
  helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
  helm repo update >/dev/null
  sed -E "s|(loadBalancerIPs:).*|\1 ${TRAEFIK_IP}|" \
    "$REPO_DIR/traefik-values.yaml" > /tmp/traefik-values.yaml
  helm upgrade --install traefik traefik/traefik \
    --version "$TRAEFIK_VERSION" -n traefik --create-namespace \
    -f /tmp/traefik-values.yaml
  kc rollout status deployment/traefik -n traefik --timeout=300s
  kc get svc -n traefik
}

# Schritt 5: cert-manager stellt Zertifikate aus. Entscheidend: Wir
# spielen die GESICHERTE CA ein. Eine neu erzeugte CA hätte einen
# anderen Fingerabdruck, und keines deiner Geräte würde ihr vertrauen.
# Zur Sicherheit vergleichen wir am Ende die Fingerabdrücke.
step_certmanager() {
  log "5. cert-manager $CERTMANAGER_VERSION und die gesicherte CA"
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm upgrade --install cert-manager jetstack/cert-manager \
    --version "$CERTMANAGER_VERSION" -n cert-manager \
    --create-namespace --set crds.enabled=true
  kc rollout status deployment/cert-manager-webhook \
    -n cert-manager --timeout=300s
  # Nur einspielen, wenn es das Secret noch nicht gibt: Die Exportdatei
  # enthält uid und resourceVersion des alten Clusters. Ein zweites
  # "apply" bricht mit einem Konflikt ab, und ein vorhandenes Secret
  # wollen wir ohnehin nie überschreiben.
  if kc get secret homelab-ca-secret -n cert-manager >/dev/null 2>&1; then
    echo "homelab-ca-secret existiert schon, bleibt unverändert."
  else
    kc apply -f "$SECRETS_DIR/homelab-ca-secret.yaml"
  fi
  # Erst jetzt die Aussteller aus dem Repository anwenden
  wait_for "cert-manager-Webhook" 120 kubectl apply -f "$REPO_DIR/ca.yaml"
  wait_for "ClusterIssuer homelab-ca" 120 \
    sh -c "kubectl get clusterissuer homelab-ca | grep -q True"
  # Beweis: Ist die CA im Cluster die gesicherte? Fingerabdrücke vergleichen.
  local fp="openssl x509 -noout -fingerprint -sha256" a b
  a=$(kc get secret homelab-ca-secret -n cert-manager \
        -o jsonpath='{.data.tls\.crt}' | base64 -d | $fp)
  b=$(grep 'tls.crt' "$SECRETS_DIR/homelab-ca-secret.yaml" \
        | awk '{print $2}' | base64 -d | $fp)
  echo "CA im Cluster: $a"
  echo "CA im Backup:  $b"
  [ "$a" = "$b" ] || die "Die CA im Cluster ist NICHT die gesicherte."
}

# Schritt 6: Namespace, Secrets (Passwörter), Speicher, Netzwerkregeln
# und die Datenbank. STORAGE=nfs nimmt die NAS-Freigabe, local legt
# leere lokale Volumes an (nur für Tests).
step_postgres() {
  log "6. Namespace, Secrets, Speicher und Postgres"
  kc apply -f "$REPO_DIR/paperless/00-namespace.yaml"
  # Auch hier: vorhandene Passwörter nicht überschreiben (siehe Schritt 5)
  if kc get secret postgres-secret paperless-secret \
       -n paperless >/dev/null 2>&1; then
    echo "Secrets in paperless existieren schon, bleiben unverändert."
  else
    kc apply -f "$SECRETS_DIR/paperless-secrets.yaml"
  fi
  if [ "$STORAGE" = nfs ]; then
    kc apply -f "$REPO_DIR/paperless/10-storage-nfs.yaml"
  else
    echo "STORAGE=local: leere lokale Volumes statt NAS (nur für Tests)"
    kc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: paperless-media, namespace: paperless}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources: {requests: {storage: 5Gi}}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: paperless-consume, namespace: paperless}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources: {requests: {storage: 1Gi}}
EOF
  fi
  kc apply -f "$REPO_DIR/paperless/70-networkpolicies.yaml"
  kc apply -f "$REPO_DIR/paperless/20-postgres.yaml"
  kc rollout status statefulset/postgres -n paperless --timeout=300s
  wait_for "Postgres bereit" 120 \
    kubectl exec -n paperless postgres-0 -- pg_isready -U paperless
}

# Schritt 7: Dump einspielen. Das passiert nur bei leerer Datenbank,
# damit ein zweiter Lauf nichts überschreibt. pg_restore läuft im Pod
# über den lokalen Socket, dafür ist kein Passwort nötig.
step_restore() {
  log "7. Dump einspielen"
  local tables
  tables=$(sql "select count(*) from information_schema.tables
                where table_schema='public'")
  if [ "$tables" != "0" ]; then
    echo "Datenbank nicht leer ($tables Tabellen): Restore übersprungen."
  else
    kc cp "$DUMP_FILE" paperless/postgres-0:/tmp/restore.dump
    kc exec -n paperless postgres-0 -- \
      pg_restore -U paperless -d paperless --no-owner /tmp/restore.dump
    kc exec -n paperless postgres-0 -- rm -f /tmp/restore.dump
  fi
  DOCS=$(sql "select count(*) from documents_document")
  echo "Dokumente in der Datenbank: $DOCS"
}

# Schritt 8: Redis, Paperless und der Ingress. Erst jetzt, weil
# Paperless die fertige Datenbank braucht.
step_app() {
  log "8. Paperless starten"
  kc apply -f "$REPO_DIR/paperless/30-redis.yaml" \
           -f "$REPO_DIR/paperless/40-paperless.yaml" \
           -f "$REPO_DIR/paperless/50-ingress.yaml"
  if [ "$STORAGE" = nfs ] && [ -f "$REPO_DIR/paperless/60-backup.yaml" ]; then
    kc apply -f "$REPO_DIR/paperless/60-backup.yaml"
  fi
  kc rollout status deployment/paperless -n paperless --timeout=600s
  wait_for "Zertifikat paperless-tls" 180 \
    sh -c "kubectl get certificate paperless-tls -n paperless | grep -q True"
}

# Schritt 9: Prüfung von außen. Wir rufen die Seite per HTTPS mit der
# gesicherten CA auf. --resolve ordnet den Namen der Adresse zu, ohne
# dass DNS eingerichtet sein muss. 200, 301 oder 302 gelten als gesund
# (Paperless leitet auf die Anmeldeseite um).
step_check() {
  log "9. Prüfung"
  kc get pods -A | grep -vE 'Completed' || true
  kc get secret homelab-ca-secret -n cert-manager \
    -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/ca.crt
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --cacert /tmp/ca.crt \
           --resolve "$SITE_HOST:443:$TRAEFIK_IP" "https://$SITE_HOST" \
         || echo "000")
  echo "HTTPS auf https://$SITE_HOST (über $TRAEFIK_IP)" \
       "mit der gesicherten CA: HTTP $code"
  case "$code" in
    200|301|302) echo "OK" ;;
    *) die "Unerwartete Antwort ($code): Zertifikat oder Dienst prüfen" ;;
  esac
  echo "Dokumente in der Datenbank: ${DOCS:-?}"
}

# Hauptablauf: erst prüfen, bei --dry-run hier enden, sonst alle Schritte
# der Reihe nach. Wegen "set -e" bricht das Skript beim ersten Fehler ab.
preflight
if [ "$DRY" = 1 ]; then
  log "Trockenlauf beendet: nichts geändert, alle Eingaben vorhanden"
  exit 0
fi
export KUBECONFIG="$HOME/.kube/config"
step_k3s; step_helm; step_metallb; step_traefik; step_certmanager
step_postgres; step_restore; step_app; step_check
log "Fertig nach $(( $(date +%s) - START )) Sekunden"
