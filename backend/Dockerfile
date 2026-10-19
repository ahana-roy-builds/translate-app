# Supply an allowlisted immutable reference, for example
# --build-arg NODE_IMAGE=node:22-bookworm-slim@sha256:<approved-digest>.
# There is intentionally no mutable default.
ARG NODE_IMAGE
FROM ${NODE_IMAGE} AS build
WORKDIR /app
COPY package*.json tsconfig.json ./
COPY scripts/apply-storekit-ocsp-patch.mjs ./scripts/apply-storekit-ocsp-patch.mjs
RUN npm ci --ignore-scripts && node scripts/apply-storekit-ocsp-patch.mjs
COPY src ./src
RUN npm run build && npm prune --omit=dev

FROM ${NODE_IMAGE}
ENV NODE_ENV=production RUNTIME_MODE=production PORT=8080
WORKDIR /app
USER node
COPY --from=build --chown=node:node /app/package.json ./package.json
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist
EXPOSE 8080
CMD ["node", "dist/server.js"]
