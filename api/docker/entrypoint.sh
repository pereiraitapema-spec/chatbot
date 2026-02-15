#!/bin/bash
set -e

# Locale seguro
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONIOENCODING=utf-8

# Bind
export DIFY_BIND_ADDRESS="${DIFY_BIND_ADDRESS:-0.0.0.0}"
export DIFY_PORT="${PORT:-8000}"

# SEMPRE converter DATABASE_URL → DB_*
if [[ -n "${DATABASE_URL}" ]]; then
  python3 << 'PYDB'
import os
from urllib.parse import urlparse, unquote

u = urlparse(os.environ["DATABASE_URL"])
os.environ["DB_TYPE"] = "postgresql"
os.environ["DB_USERNAME"] = unquote(u.username or "")
os.environ["DB_PASSWORD"] = unquote(u.password or "")
os.environ["DB_HOST"] = u.hostname or ""
os.environ["DB_PORT"] = str(u.port or 5432)
os.environ["DB_DATABASE"] = unquote((u.path or "/")[1:])

for k in ["DB_TYPE","DB_USERNAME","DB_PASSWORD","DB_HOST","DB_PORT","DB_DATABASE"]:
    print(f"export {k}='{os.environ[k]}'")
PYDB
fi

# Converter REDIS_URL
if [[ -n "${REDIS_URL}" ]]; then
  python3 << 'PYREDIS'
import os
from urllib.parse import urlparse, unquote

r = urlparse(os.environ["REDIS_URL"])
os.environ["REDIS_HOST"] = r.hostname or ""
os.environ["REDIS_PORT"] = str(r.port or 6379)
os.environ["REDIS_PASSWORD"] = unquote(r.password or "")
os.environ["REDIS_DB"] = (r.path or "/0").replace("/","") or "0"
os.environ["CELERY_BROKER_URL"] = f"redis://:{os.environ['REDIS_PASSWORD']}@{os.environ['REDIS_HOST']}:{os.environ['REDIS_PORT']}/1"

for k in ["REDIS_HOST","REDIS_PORT","REDIS_PASSWORD","REDIS_DB","CELERY_BROKER_URL"]:
    print(f"export {k}='{os.environ[k]}'")
PYREDIS
fi

# Aguardar banco
python3 << 'PYWAIT'
import os, time, psycopg2
for i in range(30):
    try:
        psycopg2.connect(
            host=os.environ["DB_HOST"],
            port=int(os.environ["DB_PORT"]),
            user=os.environ["DB_USERNAME"],
            password=os.environ["DB_PASSWORD"],
            dbname=os.environ["DB_DATABASE"],
            connect_timeout=5,
        ).close()
        print("Database is ready.")
        break
    except Exception as e:
        print(f"Waiting for database ({i+1}/30)...")
        time.sleep(2)
else:
    raise SystemExit("Database wait timeout")
PYWAIT

# Migrations
if [[ "${MIGRATION_ENABLED}" == "true" ]]; then
  echo "Running migrations"
  flask upgrade-db
fi

# Start API
exec gunicorn \
  --bind "${DIFY_BIND_ADDRESS}:${DIFY_PORT}" \
  --workers 1 \
  --worker-class gevent \
  --timeout 200 \
  app:app
