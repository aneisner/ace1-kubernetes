# ace1-kubernetes

Der Code zum Buch **„Verbrannt und wieder auferstanden: wie der Phönix aus der Asche"** von Antonio Eisner. Es zeigt, wie man Kubernetes (k3s) am Beispiel von Paperless-ngx lernt.

> **Dieses Repository gehört zum Buch.** Die Erklärungen, die Reihenfolge und die Fehler auf dem Weg stehen im Buch. Hier liegen die Dateien, die dort gebaut werden. Ohne das Buch fehlt dir der Zusammenhang.

## Worum es geht

Das Projekt läuft in einem Heimnetz:

- ein Debian-Rechner mit **k3s** (Kubernetes) und Paperless-ngx,
- ein Heimnetz auf Basis von **MikroTik**-Technik,
- ein **UGREEN-NAS** als Speicher für Dokumente und Sicherungen.

## Wichtig: Das ist mein Netz, nicht deins

Alle Adressen, Namen und Freigaben sind Beispiele aus meinem Heimnetz:

- Adressen im Bereich `192.168.88.x`,
- Namen wie `paperless.lan` und `dashboard.lan`,
- die NFS-/SMB-Freigaben auf dem UGREEN-NAS.

Du musst sie an **dein** Netz anpassen. Das gilt auch, wenn du ein anderes NAS verwendest: Die Freigaben in `paperless/10-storage-nfs.yaml` und in `restore/restore.conf.example` änderst du auf deine Adresse und deine Pfade.

## Inhalt

```
metallb-config.yaml      IP-Pool und L2-Advertisement für MetalLB
traefik-values.yaml      Helm-Values für Traefik
ca.yaml                  Eigene CA (cert-manager Issuer)
paperless/               Paperless-ngx, PostgreSQL, Redis, Ingress, Backup
headlamp/                Web-GUI für den Cluster
restore/                 Restore-Skript (Anhang F des Buches)
docs/                    Anleitung und Schaubilder
```

Die nummerierten Dateien wendest du in der Reihenfolge an, die das Buch beschreibt.

## Was nicht hier liegt

Secrets, Kubeconfig-Dateien, der private Schlüssel der eigenen CA und Datenbank-Dumps gehören nicht in ein Repository und sind hier nicht enthalten. Das Buch erklärt, wie du sie selbst sicherst.

## Wie gründlich geprüft wurde

Die Dateien wurden mehrfach geprüft: Zeile für Zeile gegen das Buch gelesen und auf echter Hardware ausgeführt, das Restore-Skript einschließlich eines Testlaufs auf einer frischen virtuellen Maschine. Was ich nicht selbst ausgeführt habe, steht im Buch ausdrücklich als „nicht im Projekt erprobt" (zum Beispiel das Restore mit `STORAGE=nfs`).

Trotzdem können Dateien Fehler enthalten, und Versionen ändern sich. Lies jede Datei, bevor du sie anwendest, und prüfe sie gegen die offizielle Dokumentation.

## Haftung

Du nutzt alles auf eigene Gefahr. Ich übernehme keine Haftung für Schäden, die durch die Verwendung dieser Dateien entstehen, einschließlich Datenverlust, soweit das gesetzlich zulässig ist. Sichere deine Daten, bevor du etwas ausprobierst.

## Lizenz

Der Code in diesem Repository steht unter der [MIT-Lizenz](LICENSE). Du darfst ihn verwenden, ändern und weitergeben. Die Lizenzdatei enthält den Haftungsausschluss.

Die MIT-Lizenz gilt für den Code, nicht für den Buchtext. Alle Rechte am Buch bleiben beim Autor.

Autor: Antonio Eisner · www.linkedin.com/in/etoni
