# nextjs-docker-image

## Overview

This project provides a Docker setup for running a Next.js application in a production-ready container. It includes a multi-stage `Dockerfile` for efficient builds and a `docker-compose.yml` for easy local orchestration.

---

## Dockerfile Details

The `Dockerfile` uses multiple stages to optimize the final image size and security:

- **Base Stage:** Uses `node:22-alpine` for a lightweight Node.js environment.
- **Deps Stage:** Installs dependencies and `libc6-compat` for compatibility.
- **Builder Stage:** Copies source code and builds the Next.js app with `yarn build`.
- **Runner Stage:** Prepares the production image, sets up a non-root user, and copies only the necessary files for running the app.
- Uses Next.js [standalone output](https://nextjs.org/docs/pages/api-reference/config/next-config-js/output) for minimal runtime footprint.
- Exposes the port defined by the `PORT` environment variable (default: 3000).
- Entrypoint runs `server.js` using Node.js.

### Build and Run with Docker

```sh
docker build -t nextjs-app .
docker run -p 3000:3000 nextjs-app
```

You can override the port by setting the `PORT` environment variable.

---

## docker-compose.yml Details

The `docker-compose.yml` file defines a single service:

- **web-app:**
  - Builds from the local context using the Dockerfile.
  - Maps port 3000 on your machine to port 3000 in the container.
  - Sets the `PORT` environment variable to 3000.

### Start with Docker Compose

```sh
docker-compose up --build
```

This will build the image and start the Next.js app at [http://localhost:3000](http://localhost:3000).

---

## Notes

- The Dockerfile is optimized for production and uses a non-root user for security.
- For development, you may want to adjust the Dockerfile or use bind mounts in `docker-compose.yml`.
- See [Next.js Docker documentation](https://nextjs.org/docs/deployment#docker-image) for more details.

---

## Further Reading

For a more detailed guide on Dockerising your Next.js app, see this article: [Dockerising Your Next.js App](https://richinmedia.co.uk/articles/dockerising-your-nextjs-app)
