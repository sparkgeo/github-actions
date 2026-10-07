# Clean multi-stage Dockerfile: every real base image is digest-pinned,
# stage aliases and scratch are allowed, and an ARG default carries a digest.
ARG BASE=cgr.dev/chainguard/python:latest@sha256:0000000000000000000000000000000000000000000000000000000000000000
FROM --platform=$BUILDPLATFORM ${BASE} AS build
WORKDIR /app
COPY app.py .

FROM build AS test
RUN ["python", "-m", "compileall", "app.py"]

FROM scratch AS artifact
COPY --from=build /app/app.py /app.py

FROM cgr.dev/chainguard/static:latest@sha256:1111111111111111111111111111111111111111111111111111111111111111
COPY --from=build /app/app.py /app.py
USER 65532
ENTRYPOINT ["/app.py"]
