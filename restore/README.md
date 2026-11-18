# restore/: Paperless auf einem frischen Rechner wiederherstellen

Dieser Ordner baut k3s mit Paperless-ngx aus dem Repository, dem Secrets-Backup und einem Datenbank-Dump neu auf.

| Datei | Zweck |
|---|---|
| `restore-paperless.sh` | baut k3s, Helm, MetalLB, Traefik, cert-manager und Paperless auf und spielt den Dump ein |
| `restore.conf.example` | Vorlage für die Einstellungen; kopieren nach `restore.conf` |
| `vm-anlegen.sh` | legt auf wsbr0.lan eine Test-VM an (läuft auf dem Mac) |

`restore.conf` steht in `.gitignore` und wird nicht eingecheckt.

## Was du mitbringen musst

1. Ein frisches Debian 13 mit sudo und Internet (Test: VM, Ernstfall: neuer Rechner mit der IP von ace1).
2. Dieses Repository (Pfad: `REPO_DIR`).
3. `homelab-ca-secret.yaml` und `paperless-secrets.yaml` aus dem Secrets-Backup (Pfad: `SECRETS_DIR`).
4. Den neuesten Datenbank-Dump im Format `pg_dump -Fc` (Pfad: `DUMP_FILE`).

Die Secrets und der Dump gehören nie ins Git.

## Ablauf

```
cd restore
cp restore.conf.example restore.conf   # Werte anpassen, siehe Kommentare in der Datei
./restore-paperless.sh --dry-run       # prüft nur, ob alles da ist
./restore-paperless.sh                 # baut alles auf
```

Das Skript meldet am Ende die Zahl der Dokumente in der Datenbank und prüft Paperless per HTTPS mit der gesicherten CA. Die Laufzeit steht in der letzten Zeile.

## Was du anpassen musst

- `NODE_NAME`, `NODE_IP`: im Ernstfall dieselben Werte wie der alte Server (das NAS lässt nur diese Adresse zu).
- `METALLB_RANGE`, `TRAEFIK_IP`, `SITE_HOST`: dein Netz und dein Name.
- `STORAGE`: `nfs` für den Ernstfall, `local` für einen Test ohne NAS.
- `REPO_DIR`, `SECRETS_DIR`, `DUMP_FILE`: wo die Eingaben liegen. Liegt das Skript im Repo unter `restore/`, ist `REPO_DIR` der Ordner darüber.
- Die Versionen: dieselben wie auf dem laufenden System.

## Sicherheitsnetz

- Auf einem Rechner mit laufendem Paperless und Dokumenten bricht das Skript ab (außer mit `FORCE=1`).
- Der Dump wird nur eingespielt, wenn die Datenbank leer ist.
- Stimmt der Fingerabdruck der CA nicht mit dem Backup überein, bricht das Skript ab.
- Ein zweiter Lauf ist ungefährlich.

## Test-VM (vom Mac aus)

```
./vm-anlegen.sh            # fragt Name, CPU, RAM, Platte, Netz und Image
./vm-anlegen.sh liste
./vm-anlegen.sh loeschen NAME
```

Bei NAT erreichst du die VM mit `ssh -J toni@wsbr0.lan toni@<IP der VM>`.
