# syntax=docker/dockerfile:1

# --- builder: install all deps, compile TS, drop dev deps ---
FROM node:22-alpine AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build && npm prune --omit=dev

# --- runtime: lean prod-only image, non-root ---
FROM node:22-alpine AS runtime
ENV NODE_ENV=production
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY package.json ./
USER node
EXPOSE 8080
# Healthcheck lives in docker-compose.yml (deployment-level), not here — one definition only.
CMD ["node", "dist/index.js"]
