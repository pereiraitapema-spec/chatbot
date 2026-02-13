# base image
FROM python:3.12-slim-bookworm AS base

WORKDIR /app/api

# Install uv
ENV UV_VERSION=0.8.9
RUN pip install --no-cache-dir uv==${UV_VERSION}


FROM base AS packages

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
          g++ \
          libmpfr-dev libmpc-dev

# ⚠️ IMPORTANTE: como o build root_dir é "api", aqui NÃO pode ter "api/..."
COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-dev


# production stage
FROM base AS production

ENV FLASK_APP=app.py
ENV EDITION=SELF_HOSTED
ENV DEPLOY_ENV=PRODUCTION
ENV CONSOLE_API_URL=http://127.0.0.1:5001
ENV CONSOLE_WEB_URL=http://127.0.0.1:3000
ENV SERVICE_API_URL=http://127.0.0.1:5001
ENV APP_WEB_URL=http://127.0.0.1:3000

EXPOSE 5001

# set timezone
ENV TZ=UTC

# Set UTF-8 locale
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV PYTHONIOENCODING=utf-8

WORKDIR /app/api

# Create non-root user
ARG dify_uid=1001
ARG NODE_MAJOR=22
ARG NODE_PACKAGE_VERSION=22.21.0-1nodesource1
ARG NODESOURCE_KEY_FPR=6F71F525282841EEDAF851B42F59B5F99B1BE0B4

RUN groupadd -r -g ${dify_uid} dify && \
    useradd -r -u ${dify_uid} -g ${dify_uid} -s /bin/bash dify && \
    chown -R dify:dify /app

RUN \
    apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o /tmp/nodesource.gpg \
    && gpg --show-keys --with-colons /tmp/nodesource.gpg \
        | awk -F: '/^fpr:/ {print $10}' \
        | grep -Fx "${NODESOURCE_KEY_FPR}" \
    && gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg /tmp/nodesource.gpg \
    && rm -f /tmp/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        nodejs=${NODE_PACKAGE_VERSION} \
        libgmp-dev libmpfr-dev libmpc-dev \
        expat libldap-2.5-0=2.5.13+dfsg-5 perl libsqlite3-0=3.40.1-2+deb12u2 zlib1g=1:1.2.13.dfsg-1 \
        fonts-noto-cjk \
        media-types \
        libmagic1 \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# Copy Python environment and packages
ENV VIRTUAL_ENV=/app/api/.venv
COPY --from=packages --chown=dify:dify ${VIRTUAL_ENV} ${VIRTUAL_ENV}
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

# Download nltk data
RUN mkdir -p /usr/local/share/nltk_data \
    && NLTK_DATA=/usr/local/share/nltk_data python -c "import nltk; from unstructured.nlp.tokenize import download_nltk_packages; nltk.download('punkt'); nltk.download('averaged_perceptron_tagger'); nltk.download('stopwords'); download_nltk_packages()" \
    && chmod -R 755 /usr/local/share/nltk_data

ENV TIKTOKEN_CACHE_DIR=/app/api/.tiktoken_cache

RUN python -c "import tiktoken; tiktoken.encoding_for_model('gpt2')" \
    && chown -R dify:dify ${TIKTOKEN_CACHE_DIR}

# Create /api/docker before any copy
RUN mkdir -p /api/docker

# ⚠️ IMPORTANTE: como o build root_dir é "api", aqui também NÃO pode ter "api/..."
COPY --chown=dify:dify . /app/api/

# Place entrypoint at /api/docker/entrypoint.sh
RUN cp /app/api/docker/entrypoint.sh /api/docker/entrypoint.sh && chmod 755 /api/docker/entrypoint.sh

ARG COMMIT_SHA
ENV COMMIT_SHA=${COMMIT_SHA}
ENV NLTK_DATA=/usr/local/share/nltk_data

USER dify

ENTRYPOINT ["/bin/bash", "/api/docker/entrypoint.sh"]
