# DEPLOY.md — Backend "panadería" en un VPS pequeño

## Requisitos
- VPS pequeño (1 vCPU / 1-2 GB RAM alcanza: la generación es CPU-ligera, el cuello
  de botella real es la latencia de red hacia Overpass/Open Topo Data).
- Python 3.10+, `pip install -r requirements.txt` (fastapi, uvicorn, requests).
- Puerto interno para uvicorn (ej. 8000) detrás de un reverse proxy (nginx/caddy)
  que termine TLS y exponga el dominio público.

## Variables de entorno (documentales — el código actual las lee con defaults;
## si se despliega tal cual, editar las constantes en `app.py` antes de arrancar)
| Variable | Dónde | Descripción |
|---|---|---|
| Puerto de uvicorn | flag `--port` al arrancar | interno, detrás del reverse proxy |
| Ruta de storage | `backend/storage/` (relativa al repo) | mover a un disco con espacio si crece mucho |
| Contacto del User-Agent | `app.py`, constante `USER_AGENT` | **reemplazar el placeholder actual antes de cualquier despliegue real** — Nominatim y Overpass exigen un User-Agent identificable con contacto real (email o URL) |

## systemd (ejemplo, `/etc/systemd/system/ciudad-conducible-backend.service`)
```ini
[Unit]
Description=Ciudad Conducible - backend panaderia
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/ciudad-conducible/backend
ExecStart=/opt/ciudad-conducible/backend/.venv/bin/uvicorn app:app --host 127.0.0.1 --port 8000
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ciudad-conducible-backend
```

## Reverse proxy (ejemplo nginx, TLS vía certbot aparte)
```nginx
server {
    listen 443 ssl;
    server_name ciudades.tudominio.com;
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```
El juego apunta a este dominio vía `settings.cfg` (`backend_url`, ver `city_library.gd`).

## Copia de seguridad
Todo el estado vive en `backend/storage/`:
- `app.db` (+ `-wal`/`-shm` si están presentes) — estado de zonas, cuotas, cache de geocode.
- `zones/<zone_id>/map.json` — los archivos servidos.
- `cache/<zone_id>/{overpass_raw.json,elevation_raw.json}` — cache cruda del pipeline (recuperable re-generando, pero ahorra tiempo/cuota de red conservarla).

Backup mínimo: `tar czf backup-$(date +%F).tar.gz backend/storage/` en un cron diario,
subido a almacenamiento externo. Restaurar = detener el servicio, reemplazar
`backend/storage/`, reiniciar — `app.db` es la única fuente de verdad del estado;
los archivos `zones/` deben coincidir con lo que `app.db` cree que existe.

## Escalación (SOLO documentación — nada de esto está implementado; se activa por
## umbral medido, no por ansiedad, y sin romper el contrato `terrain` en ningún caso)

| Señal | Umbral orientativo | Opción de escalación |
|---|---|---|
| Generaciones frías por día | > ~200/día | Mirror propio de Overpass usando extractos regionales de Geofabrik (evita depender del Overpass público, que raciona por IP/carga). Requiere disco (los extractos de un país pesan GBs) y mantenimiento de actualizaciones periódicas. |
| Llamadas a Open Topo Data por día | > ~900/día | (a) Self-host de Open Topo Data (imagen Docker oficial + los datasets SRTM/mapzen que se usan hoy), o (b) migrar el fetcher a AWS Terrain Tiles. En ambos casos el contrato `terrain` (grilla, `height_at`, schema del JSON) debe quedar INTACTO — el cambio es solo de dónde vienen las elevaciones crudas, `citygen.fetch_elevation` es el único punto que se tocaría. |

Ninguna de las dos escalaciones cambia el contrato `map.json` ni el cliente Godot.

## Antes de lanzar (checklist legal ODbL — tareas del HUMANO, no automatizables)

El código ya deja las superficies de atribución listas (verificado en Fase C-4):
menú principal, panel "Ciudades" (línea de pie de página), y pantalla de carga
muestran atribución a OpenStreetMap; la búsqueda atribuye a Nominatim por separado.
Lo que sigue es responsabilidad del humano, no algo que un agente pueda verificar
por ti — revisar contra las guías oficiales de la OSMF antes de cualquier lanzamiento
público:

- [ ] Confirmar que el texto de atribución cumple la [guía oficial de atribución de OSMF](https://osmfoundation.org/wiki/Licence/Attribution_Guidelines) (visibilidad, no ambigüedad sobre qué datos son de OSM).
- [ ] Decidir y documentar si el producto distribuye una "Derived Database" o una "Produced Work" bajo ODbL, y si aplica la cláusula share-alike a algo que se distribuya (el juego en sí, si empaqueta `map.json`s, podría considerarse una Produced Work — confirmar con la guía de la OSMF, no asumir).
- [ ] Verificar el User-Agent real (contacto) configurado en `app.py`/`citygen` antes de cualquier tráfico a Nominatim/Overpass en producción — los términos de uso de ambos servicios lo exigen.
- [ ] Revisar el throttle de Nominatim (1 req/s) contra su [política de uso](https://operations.osmfoundation.org/policies/nominatim/) vigente al momento del lanzamiento (puede cambiar).
- [ ] Si se usa el Overpass público en producción con tráfico real, revisar su [política de uso justo](https://wiki.openstreetmap.org/wiki/Overpass_API#Public_Overpass_API_instances) — es la razón detrás del umbral de escalación de arriba.
- [ ] Confirmar que ningún tiempo récord ni dato de usuario se mezcla con los datos de OSM de forma que oscurezca cuál es cuál (separación de datos propios vs. de terceros).
