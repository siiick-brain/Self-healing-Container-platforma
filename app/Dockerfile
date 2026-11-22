FROM golang:1.25-bookworm AS build
WORKDIR /src
COPY go.mod *.go ./
ARG LAB_CANARY=stable
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X main.labCanary=${LAB_CANARY}" -o /out/resilient-app .

FROM gcr.io/distroless/static-debian12:nonroot
LABEL org.opencontainers.image.source="https://github.com/siiick-brain/Self-healing-Container-platforma"
COPY --from=build /out/resilient-app /resilient-app
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["/resilient-app"]
