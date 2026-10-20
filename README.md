# nextjs-docker-image

Production-ready Docker setup for a Next.js application: a multi-stage
`Dockerfile` that runs anywhere containers run, a `Dockerfile.lambda` variant for
AWS Lambda, and a `docker-compose.yml` for local orchestration.

---

## Prerequisites

**1. Your `next.config.js` must enable standalone output.** The `Dockerfile`
copies `.next/standalone`, which `next build` only produces when you ask for it.
Without this the build fails:

```js
// next.config.js
module.exports = {
  output: 'standalone',
};
```

**2. Commit a lockfile.** The image detects your package manager from it —
`yarn.lock` → `yarn install --frozen-lockfile`, `package-lock.json` → `npm ci`,
`pnpm-lock.yaml` → `pnpm install --frozen-lockfile`. If none is present the build
fails rather than silently resolving fresh dependency versions.

**pnpm users:** also set `packageManager` in `package.json` (e.g.
`"packageManager": "pnpm@10.18.0"`), or Corepack downloads whatever pnpm is latest
at build time and your builds stop being reproducible. pnpm 10+ also refuses to
continue when a dependency's build script was skipped
(`ERR_PNPM_IGNORED_BUILDS`) — declare the ones you trust under
`pnpm.onlyBuiltDependencies`.

A `public/` directory is *not* required.

---

## Build and run

```sh
docker build -t nextjs-app .
docker run -p 3000:3000 nextjs-app
```

The port is configurable in two independent ways:

```sh
# At build time: changes the default and the EXPOSE metadata
docker build --build-arg PORT=8080 -t nextjs-app .

# At runtime: no rebuild needed. The HEALTHCHECK follows it automatically.
docker run -e PORT=8080 -p 8080:8080 nextjs-app
```

Other build args: `NODE_VERSION` (default `22-bookworm-slim`; pass
`22-bookworm-slim@sha256:...` to pin the base image by digest for reproducible builds).

### Multi-architecture builds

```sh
docker buildx build --platform linux/amd64,linux/arm64 -t <registry>/nextjs-app:latest --push .
```

Build for `linux/amd64` explicitly when deploying from an Apple Silicon machine
to a platform that only runs x86_64 — a native arm64 image fails to start there
with an exec format error.

---

## Dockerfile details

| Stage | Does |
|---|---|
| `base` | `node:22-bookworm-slim` (Debian, glibc), shared by every other stage |
| `deps` | Detects the package manager, installs dependencies from the lockfile |
| `builder` | Copies source, runs the build with a BuildKit cache mount on `.next/cache` |
| `runner` | Minimal production layer: standalone output, non-root user, `tini`, healthcheck |

Runtime characteristics worth knowing before you deploy:

- **Non-root.** Runs as `nextjs` (uid 1001, gid 1001).
- **Listens on `0.0.0.0`** via `HOSTNAME`, so platform health probes can reach it.
  A Next.js server left on `localhost` is the most common cause of "container
  failed to start" on managed platforms.
- **`HEALTHCHECK`** polls `$HEALTHCHECK_PATH` (default `/`) on the current `$PORT`
  using Node's built-in `fetch`, so no `curl`/`wget` is installed. Set
  `-e HEALTHCHECK_PATH=/api/health` if your app has a dedicated route.
- **`tini` as PID 1** with `STOPSIGNAL SIGTERM`, so signals are forwarded and
  zombies reaped. Next.js 15's standalone server handles `SIGTERM` on its own, so
  this is defence in depth rather than a fix for a specific failure.
- **`sharp` works** out of the box: the Debian base uses glibc, so prebuilt
  native modules load without Alpine's `libc6-compat` shim.

---

## docker-compose.yml

```sh
docker compose up --build        # http://localhost:3000
PORT=8080 docker compose up --build
```

`PORT` is passed as both a build arg and a runtime variable, and drives the port
mapping. The service restarts unless explicitly stopped, and `docker compose ps`
surfaces the image's healthcheck. To supply runtime configuration, uncomment the
`env_file` block — never `COPY` an env file into an image.

---

## Cloud deployment

### One image for almost everywhere

The main `Dockerfile` deploys unchanged to every container platform below. They
all inject a `PORT` environment variable and expect the process to bind
`0.0.0.0`, which the image already does.

| Platform | Notes |
|---|---|
| Google Cloud Run | Injects `PORT` (default `8080`). Push to Artifact Registry. Build `linux/amd64`. |
| AWS ECS / Fargate / App Runner | Set the container port in the task definition. amd64 and arm64 both supported. |
| Azure Container Apps | Set the target port on the ingress config. Nothing else needed. |
| Azure App Service for Containers | Also set the **`WEBSITES_PORT`** app setting to your port, or the platform probes 80 and the deployment is marked unhealthy. |
| DigitalOcean App Platform | Injects `PORT` (default `8080`); set `http_port` in the app spec if you use something else. |
| Kubernetes (EKS/GKE/AKS/DOKS) | Use the `HEALTHCHECK` path `/` for your readiness and liveness probes. |
| Fly.io, Render, Railway, Heroku | Honour the injected `PORT`; no image changes. |

Only two platform-specific settings exist in that whole table: Azure App
Service's `WEBSITES_PORT`, and Cloud Run's amd64-only requirement. Neither needs
a different image.

### AWS Lambda — `Dockerfile.lambda`

Lambda is the one target that genuinely cannot share the image. A container on
Lambda must speak the Lambda Runtime API; an HTTP server alone never receives an
invocation. `Dockerfile.lambda` adds the
[AWS Lambda Web Adapter](https://github.com/awslabs/aws-lambda-web-adapter) as an
internal extension, which translates invocations into ordinary HTTP requests
against the same `node server.js`.

Four constraints make this image incompatible with the universal one:

1. The adapter binary in `/opt/extensions/` is dead weight on every other platform.
2. **Lambda does not accept multi-architecture manifest lists.** Build one
   architecture, and pass `--provenance=false` so buildx emits a plain manifest.
3. The filesystem is read-only except `/tmp`, so `.next/cache` — used by ISR and
   the image optimiser — is symlinked there and created at boot.
4. No `EXPOSE`, no `HEALTHCHECK`, no init process: Lambda manages the lifecycle.

```sh
# Build (match --platform to the function's architecture)
docker buildx build -f Dockerfile.lambda \
  --platform linux/arm64 --provenance=false \
  -t <acct>.dkr.ecr.<region>.amazonaws.com/nextjs-app:latest --load .

# Push to ECR in the same account and region as the function
aws ecr get-login-password --region <region> \
  | docker login --username AWS --password-stdin <acct>.dkr.ecr.<region>.amazonaws.com
docker push <acct>.dkr.ecr.<region>.amazonaws.com/nextjs-app:latest
```

Then create the function from the image URI, give it a Function URL or API
Gateway trigger, and allow a generous timeout and 1–2 GB of memory for cold
starts. Useful adapter settings: `AWS_LWA_INVOKE_MODE=response_stream` for
streaming responses, and `AWS_LWA_READINESS_CHECK_PATH` if `/` is not a cheap
route to probe.

Test locally with the Runtime Interface Emulator before deploying:

```sh
curl -sSL -o aws-lambda-rie \
  https://github.com/aws/aws-lambda-runtime-interface-emulator/releases/latest/download/aws-lambda-rie-arm64
chmod +x aws-lambda-rie
docker run -d -p 9000:8080 -v "$PWD/aws-lambda-rie":/aws-lambda-rie:ro \
  --entrypoint /aws-lambda-rie nextjs-lambda \
  sh -c 'mkdir -p /tmp/next-cache && exec node server.js'
curl -XPOST "http://localhost:9000/2015-03-31/functions/function/invocations" \
  -d '{"version":"2.0","rawPath":"/","requestContext":{"http":{"method":"GET","path":"/"}},"headers":{"host":"localhost"},"isBase64Encoded":false}'
```

A `"statusCode":200` in the response means the image is wired up correctly.

### Serverless functions platforms other than Lambda

Azure Functions and GCP Cloud Functions both require their own runtime inside
the image rather than a web server, and neither offers an adapter comparable to
LWA. For a Next.js container, deploy to **Azure Container Apps** or **Cloud Run**
instead — both scale to zero and need no image changes.

---

## Notes

- `.dockerignore` excludes `.env*` and `*.pem` so secrets are never baked into a
  layer. Supply configuration at runtime. `.env.example` is deliberately allowed
  through.
- For development, prefer a bind mount and `next dev` over this image; it is
  built for production.
- See the [Next.js Docker documentation](https://nextjs.org/docs/app/getting-started/deploying#docker)
  for upstream guidance.

---

## Further Reading

For a more detailed guide on Dockerising your Next.js app, see this article:
[Dockerising Your Next.js App](https://richinmedia.co.uk/articles/dockerising-your-nextjs-app)
