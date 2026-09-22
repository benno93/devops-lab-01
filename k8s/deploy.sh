#!/usr/bin/env bash
# Deployt devops-lab-01 in einen Namespace (= Umgebung, z. B. staging/production)
# per kubectl. Wird sowohl aus der CI/CD-Pipeline als auch lokal manuell
# aufgerufen - identisches Verhalten an beiden Stellen (kein Sonderfall "nur CI").
#
# Aufruf: k8s/deploy.sh <namespace> <commit-sha> <ghcr-owner>
# Rollback = dasselbe Skript erneut mit einer AELTEREN commit-sha aufrufen.

set -euo pipefail
# -e: Skript bricht sofort ab, sobald irgendein Befehl einen Fehler liefert
#     (verhindert, dass es nach einem fehlgeschlagenen kubectl-Befehl einfach
#     mit dem naechsten Schritt weitermacht).
# -u: Zugriff auf eine nicht gesetzte Variable ist ein Fehler (faengt Tippfehler
#     bei Variablennamen ab, statt sie stillschweigend als leeren String zu lesen).
# -o pipefail: Bei "befehl1 | befehl2" zaehlt auch ein Fehler in befehl1 als
#     Fehler der gesamten Pipe (ohne das wuerde z. B. ein fehlschlagendes sed
#     vor einem erfolgreichen kubectl apply verschluckt).

NAMESPACE="${1:?Namespace fehlt}"
# $1 = erstes Argument des Skriptaufrufs. ":?<text>" laesst das Skript sofort
# mit einer verstaendlichen Fehlermeldung abbrechen, falls das Argument fehlt,
# statt spaeter mit einem leeren/falschen Namespace weiterzumachen.
SHA="${2:?Commit-SHA fehlt}"
# $2 = Commit-SHA. Bestimmt sowohl den Image-Tag (welches Image ausgerollt
# wird) als auch den Wert von APP_VERSION im Deployment.
OWNER="${3:?ghcr-Owner fehlt}"
# $3 = GitHub-Benutzer-/Orgname, unter dem die Images in ghcr.io liegen.

REGISTRY="ghcr.io/${OWNER,,}"
# "${OWNER,,}" wandelt OWNER in Kleinbuchstaben um. ghcr.io erlaubt in
# Image-Namen ausschliesslich Kleinbuchstaben; ein GitHub-Benutzername kann
# aber Grossbuchstaben enthalten (z. B. "Henning") - ohne diese Umwandlung
# wuerde der spaetere Image-Pull mit einem Namensfehler scheitern.

DIR="$(cd "$(dirname "$0")" && pwd)"
# Absoluter Pfad des Ordners, in dem DIESES Skript liegt (also k8s/).
# Dadurch funktioniert das Skript unabhaengig davon, aus welchem Verzeichnis
# heraus es aufgerufen wird (wichtig, weil die Pipeline und ein lokaler
# Aufruf typischerweise aus unterschiedlichen Arbeitsverzeichnissen laufen).

case "$NAMESPACE" in
  staging)    NODEPORT=30080 ;;
  production) NODEPORT=30081 ;;
  *)
    echo "::error::Kein NodePort fuer Namespace '${NAMESPACE}' definiert (nur staging/production vorgesehen)."
    exit 1
    ;;
esac
# NodePort ist - anders als der Namespace - CLUSTERWEIT eindeutig, nicht pro
# Namespace: derselbe Wert darf nur EINMAL im gesamten Cluster vergeben sein.
# Wuerde man in frontend.yaml einen festen nodePort eintragen, wuerde das
# identische Manifest beim zweiten "apply" (in einem ANDEREN Namespace,
# z. B. production nach staging) mit einem Fehler abgelehnt, weil der Port
# schon vom ersten Namespace belegt ist. Deshalb bekommt hier jeder erlaubte
# Namespace explizit seinen EIGENEN, festen Port zugewiesen und wird unten
# wie __REGISTRY__/__TAG__ per sed in frontend.yaml eingesetzt - staging und
# production sind damit dauerhaft unter unterschiedlichen, vorhersehbaren
# URLs erreichbar (http://<VM>:30080 bzw. :30081), unabhaengig von einem
# offenen kubectl-port-forward-Terminal.

TIMEOUT="120s"
# Wie lange maximal auf einen erfolgreichen Rollout gewartet wird, bevor
# Schritt 3 unten als fehlgeschlagen gilt und der Rollback greift.

rollback() {
  # Wird unten an zwei Stellen per "|| rollback" aufgerufen, sobald ein
  # Rollout-Wait oder der Smoke-Test fehlschlaegt.
  echo "::error::Deployment in '${NAMESPACE}' fehlgeschlagen - Rollback auf vorherige Revision"
  # "::error::" ist eine spezielle Ausgabe-Syntax, die GitHub Actions erkennt
  # und im Actions-Log rot/prominent als Fehler hervorhebt.
  for d in backend frontend; do
    kubectl -n "$NAMESPACE" rollout undo "deploy/$d" || true
    # "rollout undo" stellt die vorherige funktionierende Revision des
    # Deployments wieder her (Kubernetes merkt sich alte ReplicaSets).
    # "|| true" verhindert, dass das Skript hier abbricht (wegen "set -e"),
    # falls es z. B. beim allerersten Deployment ueberhaupt noch keine
    # vorherige Revision gibt, zu der zurueckgerollt werden koennte.
  done
  exit 1
  # Beendet das Skript mit Fehlercode 1 -> der aufrufende GitHub-Actions-Job
  # gilt als fehlgeschlagen (rot), damit der Fehlschlag sichtbar bleibt statt
  # nach dem Rollback stillschweigend als "erfolgreich" durchzugehen.
}

# 1) Namespace idempotent anlegen.
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
# "kubectl create namespace" wuerde bei einem bereits vorhandenen Namespace
# (z. B. beim zweiten Deployment) mit einem Fehler abbrechen. Der Umweg ueber
# "--dry-run=client -o yaml | kubectl apply -f -" erzeugt stattdessen nur das
# YAML fuer den Namespace und wendet es per "apply" an - das ist idempotent:
# existiert der Namespace schon, passiert einfach nichts, existiert er noch
# nicht, wird er angelegt. So funktioniert das Skript ohne Sonderfall fuer
# "erstes vs. wiederholtes Deployment".

# 2) Platzhalter ersetzen und anwenden.
# (Backend zuerst: nginx im Frontend-Container loest beim eigenen Start den
# Hostnamen "backend" auf - existiert der Backend-Service zu dem Zeitpunkt
# schon, klappt das zuverlaessiger.)
for f in backend frontend; do
  sed -e "s|__REGISTRY__|${REGISTRY}|g" -e "s|__TAG__|${SHA}|g" -e "s|__NODEPORT__|${NODEPORT}|g" "$DIR/$f.yaml" \
    | kubectl -n "$NAMESPACE" apply -f -
  # sed ersetzt in backend.yaml/frontend.yaml die Platzhalter __REGISTRY__,
  # __TAG__ und (nur in frontend.yaml vorhanden, in backend.yaml kommt der
  # String einfach nicht vor und die Ersetzung greift dort ins Leere) den
  # oben festgelegten __NODEPORT__ durch die tatsaechlichen Werte und gibt
  # das Ergebnis auf stdout aus (die Dateien selbst werden NICHT veraendert).
  # Das Ergebnis wird direkt per Pipe an "kubectl apply -f -" uebergeben
  # ("-f -" heisst: Manifest von stdin lesen statt aus einer Datei) - so
  # landet nirgends eine Zwischendatei mit den konkreten Werten auf der
  # Platte. "-n $NAMESPACE" wendet das Manifest im richtigen Namespace an
  # (statt im Namespace "default").
done

# 3) Auf erfolgreichen Rollout warten.
for d in backend frontend; do
  kubectl -n "$NAMESPACE" rollout status "deploy/$d" --timeout="$TIMEOUT" || rollback
  # "rollout status" blockiert, bis das Rolling Update abgeschlossen ist,
  # also bis genuegend neue Pods die readinessProbe aus backend.yaml/
  # frontend.yaml erfolgreich bestanden haben. Nach spaetestens 120s bricht
  # der Befehl mit einem Fehler ab (z. B. weil ein Pod nicht "ready" wird) -
  # in diesem Fall greift ueber "||" sofort die rollback()-Funktion.
done

# 4) Smoke-Test: Health-Endpoint ueber Frontend-Service -> nginx -> Backend.
kubectl -n "$NAMESPACE" run "smoke-${RANDOM}" --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -fsS --retry 5 --retry-delay 2 --retry-connrefused http://frontend/api/health || rollback
# Selbst wenn Schritt 3 gruen ist (Pods sind "ready"), heisst das nur, dass
# die Probes einzelner Container ok sind - dieser Schritt prueft zusaetzlich
# den TATSAECHLICHEN Weg eines echten Requests durch den ganzen Stack:
# "kubectl run" startet dafuer einen kurzlebigen Wegwerf-Pod IM Cluster
# (mit dem curl-Image), der den Aufruf http://frontend/api/health absetzt -
# also genau die Route, die auch ein echter Client nehmen wuerde:
# Service "frontend" -> nginx -> location /api/ -> proxy_pass zu
# Service "backend" -> Flask-Endpoint /api/health.
#   --rm            loescht den Test-Pod automatisch wieder, egal ob er
#                    erfolgreich war oder nicht (kein Muell im Cluster).
#   -i              haengt kubectl interaktiv an den Pod, damit die
#                    curl-Ausgabe/der Exit-Code direkt im Actions-Log landet.
#   --restart=Never  verhindert, dass Kubernetes den (absichtlich einmaligen)
#                    Test-Pod bei "Fehler" automatisch neu startet.
#   "smoke-${RANDOM}" ein zufaelliger Namensbestandteil, damit zwei
#                    Deployments kurz hintereinander sich nicht mit
#                    demselben Pod-Namen in die Quere kommen.
#   curl -fsS        -f: bei HTTP-Fehlercode (4xx/5xx) selbst mit Fehler
#                    enden statt die Fehlerseite als "Erfolg" zu werten;
#                    -s: keine Fortschrittsanzeige; -S: Fehlermeldungen trotz
#                    -s dennoch ausgeben.
#   --retry ...      nginx/Flask brauchen nach "ready" ggf. noch einen
#                    Moment; bis zu 5 Versuche im 2s-Abstand federn kurze
#                    Verzoegerungen ab, statt beim ersten Versuch sofort
#                    aufzugeben.
# Schlaegt der Aufruf trotzdem fehl, greift wieder rollback().

echo "Deployment ${SHA} in '${NAMESPACE}' erfolgreich - erreichbar unter http://<VM-IP-oder-Hostname>:${NODEPORT}"
# Wird nur erreicht, wenn keiner der vorherigen Schritte "rollback" ausgeloest
# hat - im Actions-Log damit auf den ersten Blick erkennbar, dass wirklich
# alles (inkl. Smoke-Test) durchgelaufen ist.
