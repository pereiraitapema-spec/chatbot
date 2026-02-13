#!/bin/bash

set -e

# Set UTF-8 encoding to address potential encoding issues in containerized environments
# Use C.UTF-8 which is universally available in all containers
export LANG=${LANG:-C.UTF-8}
export LC_ALL=${LC_ALL:-C.UTF-8}
export PYTHONIOENCODING=${PYTHONIOENCODING:-utf-8}

# Railway / PaaS: prefer PORT from platform, bind to all interfaces
export DIFY_BIND_ADDRESS="${DIFY_BIND_ADDRESS:-0.0.0.0}"
export DIFY_PORT="${PORT:-${DIFY_PORT:-5001}}"

# Parse DATABASE_URL into DB_* variables when set and DB_HOST is not (e.g. Railway Postgres)
if [[ -n "${DATABASE_URL}" ]] && [[ -z "${DB_HOST}" ]]; then
  python3 << 'PYDB'
import os
from urllib.parse import urlparse, unquote
def esc(s):
    return repr(str(s))
db_url = os.environ.get("DATABASE_URL", "")
if db_url:
    parsed = urlparse(db_url)
    u = unquote(parsed.username or "")
    p = unquote(parsed.password or "")
    h = parsed.hostname or ""
    pt = parsed.port or 5432
    d = unquote((parsed.path or "/").strip("/") or "")
    with open("/tmp/railway_db_env", "w") as f:
        f.write("export DB_TYPE=postgresql\n")
        f.write("export DB_USERNAME=" + esc(u) + "\n")
        f.write("export DB_PASSWORD=" + esc(p) + "\n")
        f.write("export DB_HOST=" + esc(h) + "\n")
        f.write("export DB_PORT=" + str(pt) + "\n")
        f.write("export DB_DATABASE=" + esc(d) + "\n")
PYDB
  if [[ -f /tmp/railway_db_env ]]; then
    set -a
    . /tmp/railway_db_env
    set +a
    rm -f /tmp/railway_db_env
    echo "Converted DATABASE_URL to DB_* variables"
  fi
fi

# Parse REDIS_URL into REDIS_* and CELERY_BROKER_URL when set and CELERY_BROKER_URL is not (e.g. Railway Redis)
if [[ -n "${REDIS_URL}" ]] && [[ -z "${CELERY_BROKER_URL}" ]]; then
  python3 << 'PYREDIS'
import os
from urllib.parse import urlparse, unquote
def esc(s):
    return repr(str(s))
r = os.environ.get("REDIS_URL", "")
if r:
    parsed = urlparse(r)
    u = unquote(parsed.username or "")
    p = unquote(parsed.password or "")
    h = parsed.hostname or ""
    pt = parsed.port or 6379
    db = (parsed.path or "/0").strip("/") or "0"
    try:
        dbn = int(db)
    except ValueError:
        dbn = 0
    scheme = "rediss" if parsed.scheme == "rediss" else "redis"
    auth = (":" + p) if p else ""
    at = (u + auth + "@") if (u or auth) else ""
    broker_url = scheme + "://" + at + h + ":" + str(pt) + "/1"
    with open("/tmp/railway_redis_env", "w") as f:
        f.write("export REDIS_HOST=" + esc(h) + "\n")
        f.write("export REDIS_PORT=" + str(pt) + "\n")
        f.write("export REDIS_PASSWORD=" + esc(p) + "\n")
        f.write("export REDIS_USERNAME=" + esc(u) + "\n")
        f.write("export REDIS_DB=" + str(dbn) + "\n")
        f.write("export REDIS_USE_SSL=" + ("true" if scheme == "rediss" else "false") + "\n")
        f.write("export CELERY_BROKER_URL=" + esc(broker_url) + "\n")
PYREDIS
  if [[ -f /tmp/railway_redis_env ]]; then
    set -a
    . /tmp/railway_redis_env
    set +a
    rm -f /tmp/railway_redis_env
    echo "Converted REDIS_URL to REDIS_* and CELERY_BROKER_URL"
  fi
fi

# Improve connection reliability in cloud (e.g. Railway)
export SQLALCHEMY_POOL_PRE_PING="${SQLALCHEMY_POOL_PRE_PING:-true}"
export SQLALCHEMY_POOL_TIMEOUT="${SQLALCHEMY_POOL_TIMEOUT:-60}"

# Wait for database to be reachable before migrations/start (retry loop)
_wait_for_db() {
  [[ -z "${DB_HOST}" ]] && return 0
  local max_attempts="${DB_WAIT_ATTEMPTS:-30}"
  local attempt=1
  while [ "$attempt" -le "$max_attempts" ]; do
    if python3 -c "
import os
import sys
try:
    import psycopg2
    c = psycopg2.connect(
        host=os.environ.get('DB_HOST'),
        port=int(os.environ.get('DB_PORT', 5432)),
        user=os.environ.get('DB_USERNAME'),
        password=os.environ.get('DB_PASSWORD'),
        dbname=os.environ.get('DB_DATABASE'),
        connect_timeout=5
    )
    c.close()
    sys.exit(0)
except Exception as e:
    print(e, file=sys.stderr)
    sys.exit(1)
" 2>/dev/null; then
      echo "Database is ready."
      return 0
    fi
    echo "Waiting for database (attempt $attempt/$max_attempts)..."
    sleep 2
    attempt=$((attempt + 1))
  done
  echo "Database wait timeout." >&2
  return 1
}
_wait_for_db

if [[ "${MIGRATION_ENABLED}" == "true" ]]; then
  echo "Running migrations"
  flask upgrade-db
  # Pure migration mode
  if [[ "${MODE}" == "migration" ]]; then
  echo "Migration completed, exiting normally"
  exit 0
  fi
fi

if [[ "${MODE}" == "worker" ]]; then

  # Get the number of available CPU cores
  if [ "${CELERY_AUTO_SCALE,,}" = "true" ]; then
    # Set MAX_WORKERS to the number of available cores if not specified
    AVAILABLE_CORES=$(nproc)
    MAX_WORKERS=${CELERY_MAX_WORKERS:-$AVAILABLE_CORES}
    MIN_WORKERS=${CELERY_MIN_WORKERS:-1}
    CONCURRENCY_OPTION="--autoscale=${MAX_WORKERS},${MIN_WORKERS}"
  else
    CONCURRENCY_OPTION="-c ${CELERY_WORKER_AMOUNT:-1}"
  fi

  # Configure queues based on edition if not explicitly set
  if [[ -z "${CELERY_QUEUES}" ]]; then
    if [[ "${EDITION}" == "CLOUD" ]]; then
      # Cloud edition: separate queues for dataset and trigger tasks
      DEFAULT_QUEUES="api_token,dataset,priority_dataset,priority_pipeline,pipeline,mail,ops_trace,app_deletion,plugin,workflow_storage,conversation,workflow_professional,workflow_team,workflow_sandbox,schedule_poller,schedule_executor,triggered_workflow_dispatcher,trigger_refresh_executor,retention,workflow_based_app_execution"
    else
      # Community edition (SELF_HOSTED): dataset, pipeline and workflow have separate queues
      DEFAULT_QUEUES="api_token,dataset,priority_dataset,priority_pipeline,pipeline,mail,ops_trace,app_deletion,plugin,workflow_storage,conversation,workflow,schedule_poller,schedule_executor,triggered_workflow_dispatcher,trigger_refresh_executor,retention,workflow_based_app_execution"
    fi
  else
    DEFAULT_QUEUES="${CELERY_QUEUES}"
  fi

  # Support for Kubernetes deployment with specific queue workers
  # Environment variables that can be set:
  # - CELERY_WORKER_QUEUES: Comma-separated list of queues (overrides CELERY_QUEUES)
  # - CELERY_WORKER_CONCURRENCY: Number of worker processes (overrides CELERY_WORKER_AMOUNT)
  # - CELERY_WORKER_POOL: Pool implementation (overrides CELERY_WORKER_CLASS)

  if [[ -n "${CELERY_WORKER_QUEUES}" ]]; then
    DEFAULT_QUEUES="${CELERY_WORKER_QUEUES}"
    echo "Using CELERY_WORKER_QUEUES: ${DEFAULT_QUEUES}"
  fi

  if [[ -n "${CELERY_WORKER_CONCURRENCY}" ]]; then
    CONCURRENCY_OPTION="-c ${CELERY_WORKER_CONCURRENCY}"
    echo "Using CELERY_WORKER_CONCURRENCY: ${CELERY_WORKER_CONCURRENCY}"
  fi

  WORKER_POOL="${CELERY_WORKER_POOL:-${CELERY_WORKER_CLASS:-gevent}}"
  echo "Starting Celery worker with queues: ${DEFAULT_QUEUES}"

  exec celery -A celery_entrypoint.celery worker -P ${WORKER_POOL} $CONCURRENCY_OPTION \
    --max-tasks-per-child ${MAX_TASKS_PER_CHILD:-50} --loglevel ${LOG_LEVEL:-INFO} \
    -Q ${DEFAULT_QUEUES} \
    --prefetch-multiplier=${CELERY_PREFETCH_MULTIPLIER:-1}

elif [[ "${MODE}" == "beat" ]]; then
  exec celery -A app.celery beat --loglevel ${LOG_LEVEL:-INFO}

elif [[ "${MODE}" == "job" ]]; then
  # Job mode: Run a one-time Flask command and exit
  # Pass Flask command and arguments via container args
  # Example K8s usage:
  #   args:
  #   - create-tenant
  #   - --email
  #   - admin@example.com
  #
  # Example Docker usage:
  #   docker run -e MODE=job dify-api:latest create-tenant --email admin@example.com

  if [[ $# -eq 0 ]]; then
    echo "Error: No command specified for job mode."
    echo ""
    echo "Usage examples:"
    echo "  Kubernetes:"
    echo "    args: [create-tenant, --email, admin@example.com]"
    echo ""
    echo "  Docker:"
    echo "    docker run -e MODE=job dify-api create-tenant --email admin@example.com"
    echo ""
    echo "Available commands:"
    echo "  create-tenant, reset-password, reset-email, upgrade-db,"
    echo "  vdb-migrate, install-plugins, and more..."
    echo ""
    echo "Run 'flask --help' to see all available commands."
    exit 1
  fi

  echo "Running Flask job command: flask $*"

  # Temporarily disable exit on error to capture exit code
  set +e
  flask "$@"
  JOB_EXIT_CODE=$?
  set -e

  if [[ ${JOB_EXIT_CODE} -eq 0 ]]; then
    echo "Job completed successfully."
  else
    echo "Job failed with exit code ${JOB_EXIT_CODE}."
  fi

  exit ${JOB_EXIT_CODE}

else
  if [[ "${DEBUG}" == "true" ]]; then
    exec flask run --host=${DIFY_BIND_ADDRESS:-0.0.0.0} --port=${DIFY_PORT:-5001} --debug
  else
    exec gunicorn \
      --bind "${DIFY_BIND_ADDRESS:-0.0.0.0}:${DIFY_PORT:-5001}" \
      --workers ${SERVER_WORKER_AMOUNT:-1} \
      --worker-class ${SERVER_WORKER_CLASS:-gevent} \
      --worker-connections ${SERVER_WORKER_CONNECTIONS:-10} \
      --timeout ${GUNICORN_TIMEOUT:-200} \
      app:app
  fi
fi
