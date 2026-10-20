# syntax=docker.io/docker/dockerfile:1

# Global build args, usable on the FROM lines below. A global ARG must be
# re-declared inside a stage before that stage can reference it, which is why
# `runner` repeats `ARG PORT`.
# Debian (glibc) rather than Alpine (musl), so prebuilt native modules such as
# sharp load without a compatibility shim.
# Pin by digest for reproducible builds, e.g.
#   --build-arg NODE_VERSION=22-bookworm-slim@sha256:<digest>
ARG NODE_VERSION=22-bookworm-slim
ARG PORT=3000

FROM node:${NODE_VERSION} AS base

# ---------------------------------------------------------------------------
# Install dependencies only when needed
# ---------------------------------------------------------------------------
FROM base AS deps
WORKDIR /app

# Globs so a project only needs the lockfile for its own package manager.
COPY package.json yarn.lock* package-lock.json* pnpm-lock.yaml* ./

RUN if [ -f yarn.lock ]; then \
      yarn install --frozen-lockfile; \
    elif [ -f package-lock.json ]; then \
      npm ci; \
    elif [ -f pnpm-lock.yaml ]; then \
      corepack enable pnpm && pnpm install --frozen-lockfile; \
    else \
      echo "No lockfile found. Commit a yarn.lock, package-lock.json or pnpm-lock.yaml." >&2; \
      exit 1; \
    fi

# ---------------------------------------------------------------------------
# Rebuild the source code only when needed
# ---------------------------------------------------------------------------
FROM base AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .

ENV NEXT_TELEMETRY_DISABLED=1

RUN --mount=type=cache,target=/app/.next/cache \
    if [ -f yarn.lock ]; then \
      yarn build; \
    elif [ -f package-lock.json ]; then \
      npm run build; \
    elif [ -f pnpm-lock.yaml ]; then \
      corepack enable pnpm && pnpm build; \
    else \
      echo "No lockfile found. Commit a yarn.lock, package-lock.json or pnpm-lock.yaml." >&2; \
      exit 1; \
    fi

# Keep the runner's COPY of ./public working for projects without static assets.
RUN mkdir -p /app/public

# ---------------------------------------------------------------------------
# Production image, copy all the files and run next
# ---------------------------------------------------------------------------
FROM base AS runner
ARG PORT
WORKDIR /app

# tini: reaps zombies and forwards SIGTERM so container drains are graceful.
RUN apt-get update \
    && apt-get install -y --no-install-recommends tini \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 1001 nodejs \
    && useradd --system --uid 1001 --gid nodejs --no-create-home --shell /usr/sbin/nologin nextjs

# HEALTHCHECK_PATH: point at a dedicated route (e.g. /api/health) if you have one.
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=${PORT} \
    HOSTNAME=0.0.0.0 \
    HEALTHCHECK_PATH=/

COPY --from=builder /app/public ./public

# Automatically leverage output traces to reduce image size
# https://nextjs.org/docs/advanced-features/output-file-tracing
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs

EXPOSE ${PORT}

# Debian slim ships neither wget nor curl; Node 22's global fetch does the probe.
HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
    CMD node -e 'fetch("http://127.0.0.1:" + (process.env.PORT || 3000) + (process.env.HEALTHCHECK_PATH || "/")).then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))'

STOPSIGNAL SIGTERM

# server.js is created by next build from the standalone output
# https://nextjs.org/docs/pages/api-reference/config/next-config-js/output
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "server.js"]
