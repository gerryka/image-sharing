# syntax=docker/dockerfile:1.7
FROM golang:1.26-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/imgshare .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /out/imgshare /imgshare
USER nonroot:nonroot
EXPOSE 47000
HEALTHCHECK --interval=60s --timeout=6s --start-period=10s --retries=3 CMD ["/imgshare", "healthcheck"]
ENTRYPOINT ["/imgshare"]
