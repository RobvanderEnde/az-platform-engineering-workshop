# ── Stage 1: Build ────────────────────────────────────────────────────────────
FROM mcr.microsoft.com/azurelinux/base/nodejs:24 AS build
WORKDIR /app

# Copy package files first for layer caching
COPY package.json package-lock.json* ./
RUN if [ -f package-lock.json ]; then npm ci; else npm install; fi

# Copy remaining source and build
COPY . .
RUN npm run build

# ── Stage 2: Runtime ─────────────────────────────────────────────────────────
FROM mcr.microsoft.com/azurelinux/base/nginx:1.28 AS runtime

# Copy built SPA assets to the nginx html directory
COPY --from=build /app/dist /usr/share/nginx/html

# Copy nginx config template and entrypoint (envsubst replaces BACKEND_FQDN at startup)
COPY nginx/default.conf.template /etc/nginx/conf.d/default.conf.template
COPY nginx/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80
ENTRYPOINT ["/entrypoint.sh"]
