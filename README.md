
# devops-lab-01

Minimales Zwei-Dienste-Beispiel (Backend/Frontend) als Ausgangspunkt fuer den
DevOps-Lab-Aufbau: nativ -> Container -> Registry -> Kubernetes -> Pipeline.

- `backend/`: Flask-API (`/api/health`, `/api/status`), Port 5001
- `frontend/`: nginx, liefert `index.html` aus und reicht `/api/` per
  Reverse Proxy an den Backend-Dienst weiter
