# syntax=docker.io/docker/dockerfile:1

# Global build args, usable on the FROM lines below. A global ARG must be
# re-declared inside a stage before that stage can reference it, which is why
# `runner` repeats `ARG PORT`.
# Pin by digest for reproducible builds, e.g.
#   --build-arg NODE_VERSION=22-alpine@sha256:0a7108bf6c7bf5de370ffb1a3ed6be93d405b43ff159f681a8d18c0e2bc2e402
ARG NODE_VERSION=22-alpine
ARG PORT=3000

FROM node:${NODE_VERSION} AS base

# ---------------------------------------------------------------------------
# Install dependencies only when needed
# ---------------------------------------------------------------------------
FROM base AS deps
# Check https://github.com/nodejs/docker-node/tree/main#nodealpine to understand
# why libc6-compat might be needed.
RUN apk add --no-cache libc6-compat
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

# libc6-compat: sharp (Next.js image optimisation) is a native module.
# tini: reaps zombies and forwards SIGTERM so container drains are graceful.
RUN apk add --no-cache libc6-compat tini \
    && addgroup --system --gid 1001 nodejs \
    && adduser --system --uid 1001 nextjs

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=${PORT} \
    HOSTNAME=0.0.0.0

COPY --from=builder /app/public ./public

# Automatically leverage output traces to reduce image size
# https://nextjs.org/docs/advanced-features/output-file-tracing
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs

EXPOSE ${PORT}

HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
    CMD wget -q --spider "http://127.0.0.1:${PORT}/" || exit 1

STOPSIGNAL SIGTERM

# server.js is created by next build from the standalone output
# https://nextjs.org/docs/pages/api-reference/config/next-config-js/output
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "server.js"]
