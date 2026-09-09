# syntax=docker/dockerfile:1

FROM node:22-alpine AS base
WORKDIR /app
COPY package.json package-lock.json ./

# ── dev: all deps (incl. nodemon). Source is baked in so the image runs
#    standalone, but the compose bind-mount overlays it for hot reload. ──
FROM base AS dev
RUN npm ci
COPY . .
ENV NODE_ENV=development
EXPOSE 3000
CMD ["npm", "run", "dev"]

# ── prod deps only ──
FROM base AS prod-deps
RUN npm ci --omit=dev

# ── prod: lean, non-root, deploy-ready (built on demand, not used by compose) ──
FROM node:22-alpine AS prod
WORKDIR /app
ENV NODE_ENV=production
COPY --from=prod-deps /app/node_modules ./node_modules
COPY . .
RUN chown -R node:node /app
USER node
EXPOSE 3000
CMD ["node", "index.js"]
