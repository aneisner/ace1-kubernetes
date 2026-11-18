#!/bin/bash
# Verteilt die heruntergeladenen Dateien aus docs/ an die richtigen Stellen.
# Aufruf:  bash $HOME/development/ace1-kubernetes/docs/dateien-verteilen.sh
# Das Skript committet nichts. Es bricht ab, wenn README/REQUIREMENTS im Repo
# noch ungespeicherte Änderungen haben.
set -eu

REPO="$HOME/development/ace1-kubernetes"
DOCS="$REPO/docs"
NOTIZEN="$HOME/k8s-notizen"

cd "$DOCS"
mkdir -p "$NOTIZEN"

if ! git -C "$REPO" diff --quiet -- README.md REQUIREMENTS.md; then
  echo "Abbruch: README.md oder REQUIREMENTS.md im Repo haben ungespeicherte Änderungen."
  echo "Erst ansehen (git diff) und committen oder verwerfen, dann das Skript erneut starten."
  exit 1
fi

verschiebe() {
  if [ -f "$1" ]; then
    mv -f "$1" "$2"
    echo "ok:  $1 -> $2"
  else
    echo "fehlt (übersprungen): $1"
  fi
}

# gehören ins Repo (Hauptverzeichnis)
verschiebe README.md       "$REPO/README.md"
verschiebe REQUIREMENTS.md "$REPO/REQUIREMENTS.md"

# gehören NICHT ins Repo (Lernunterlagen)
verschiebe lernstand.md     "$NOTIZEN/lernstand.md"
verschiebe BUCH-PROJEKT.md  "$NOTIZEN/BUCH-PROJEKT.md"

# bleiben in docs/: Anleitung (md, pdf), fehlersuche-leiter.png, befehle-uebersicht.png
echo
echo "In docs/ bleiben:"
ls -1 "$DOCS" | grep -v '^\.' || true
echo
echo "Änderungen im Repo:"
AENDERUNGEN="$(git -C "$REPO" status --short)"
if [ -z "$AENDERUNGEN" ]; then
  echo "  keine. Es gibt nichts zu committen."
  echo "  (lernstand.md und BUCH-PROJEKT.md liegen bewusst außerhalb des Repos.)"
else
  echo "$AENDERUNGEN"
  echo
  echo "Ansehen und bei Bedarf committen (Nachricht selbst passend wählen):"
  echo "  cd $REPO"
  echo "  git diff"
  echo "  git add <Dateien>"
  echo "  git commit -m \"<was sich geändert hat>\""
fi
