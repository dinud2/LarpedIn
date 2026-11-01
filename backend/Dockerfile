FROM oven/bun:1 AS build
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile
COPY . .
RUN bun run build

# The Nitro build in .output is self-contained, so the runtime image only needs bun + ffmpeg.
FROM oven/bun:1-slim
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/.output ./.output
ENV NODE_ENV=production
# Render and Railway inject PORT; Nitro listens on it. 3000 is the local fallback.
ENV PORT=3000
EXPOSE 3000
CMD ["bun", ".output/server/index.mjs"]
