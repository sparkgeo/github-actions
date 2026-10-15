# Deliberately bad: unpinned latest tag, tag without digest, unpinned pip,
# and an ARG-based base whose default has no digest.
ARG BASE=python:3.12
FROM python:latest
RUN pip install flask
FROM ${BASE} AS build
FROM alpine:3.19
COPY . /app
