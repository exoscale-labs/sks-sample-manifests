# Build the exegress controller as a static binary on a distroless base.
FROM golang:1.25 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG TARGETOS TARGETARCH
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/controller ./cmd/controller

FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/controller /controller
USER 65532:65532
ENTRYPOINT ["/controller"]
