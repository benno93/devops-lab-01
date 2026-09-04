
# devops-lab-01 – Nativer Betrieb (Ist-Zustand)

Backend und Frontend laufen direkt auf der Lab-VM, ohne Container,
Kubernetes oder Pipeline. Das ist bewusst der Status quo *vor* der
DevOps-Einführung – inklusive aller manuellen Reibungspunkte.

## Voraussetzungen (einmalig auf der VM)

```bash
sudo apt update
sudo apt install -y python3-venv python3-pip nginx git
```

## Repo auf die VM holen

```bash
git clone ssh://git@devops-lab-01.local:222/henning/devops-lab-01.git
cd devops-lab-01
```

(Läuft der Clone direkt auf der VM, auf der auch Gitea steckt, geht
alternativ auch `ssh://git@localhost:222/...`.)

## Backend starten

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Damit der Prozess eine SSH-Sitzung überlebt (bewusst noch ohne
Supervisor/systemd-Unit – das ist Teil des Ist-Zustands):

```bash
nohup python app.py > ../backend.log 2>&1 &
```

Test:

```bash
curl http://localhost:5001/api/health
curl http://localhost:5001/api/status
```

## Frontend / nginx als Reverse Proxy

nginx läuft nach der Installation bereits als Systemdienst. Eigene
Site-Konfiguration anlegen, statt die Default-Config zu verändern:

```bash
sudo tee /etc/nginx/sites-available/devops-lab-01 > /dev/null <<'EOF'
server {
    listen 8080;

    location /api/ {
        proxy_pass http://127.0.0.1:5001/api/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location / {
        root   /home/<dein-user>/devops-lab-01/frontend;
        index  index.html;
    }
}
EOF

sudo ln -s /etc/nginx/sites-available/devops-lab-01 /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

`<dein-user>` durch deinen tatsächlichen Linux-User auf der VM ersetzen.

Test:

```bash
curl http://localhost:8080/
curl http://localhost:8080/api/status
```

Vom Mac aus im Browser: `http://devops-lab-01.local:8080`

## Ablauf bei einer Codeänderung (Ist-Zustand, komplett manuell)

```bash
git pull

# Backend neu starten
pkill -f "python app.py"
cd backend && source .venv/bin/activate
nohup python app.py > ../backend.log 2>&1 &
cd ..

# Frontend: index.html wird sofort ausgeliefert (statische Datei);
# Aenderungen an nginx.conf/Site-Config brauchen:
sudo nginx -t && sudo systemctl reload nginx
```

Kein automatischer Build, kein Test vor dem Deploy, kein Rollback,
keine Umgebungstrennung (Dev/Staging/Prod), keine Genehmigung – genau
diese Lücken sind der Ausgangspunkt für Kapitel 2 der Fallstudie und
werden durch die spätere CI/CD-Pipeline geschlossen.
