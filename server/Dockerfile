# ---- Build ----
FROM swift:6.0-jammy AS build
WORKDIR /build

# Resolve deps first for a cached layer.
COPY ./Package.swift ./Package.swift
RUN swift package resolve

COPY . .
RUN swift build -c release --static-swift-stdlib -Xlinker -ljemalloc

RUN mkdir -p /staging \
 && cp "$(swift build --package-path /build -c release --show-bin-path)/App" /staging/ \
 && [ -d /build/Public ] && cp -R /build/Public /staging/Public || true

# ---- Run ----
FROM swift:6.0-jammy-slim
WORKDIR /app
RUN useradd --user-group --create-home --home-dir /app vapor
COPY --from=build --chown=vapor:vapor /staging /app
# The migration runner reads the shared SQL files; they are bind-mounted at
# /migrations by docker-compose.swift.yml.
USER vapor
EXPOSE 3000
ENTRYPOINT ["./App"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "3000"]
