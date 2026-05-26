# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Workshop loadgen image — locust HttpUser hitting Astroshop with LTN/TSN
# HTTP headers, so the Dynatrace SRG sees test-step request attributes.
# No Playwright (the new locustfile.py uses HttpUser, not PlaywrightUser).

FROM python:3.12-slim-bookworm AS base

FROM base AS builder
RUN apt-get -qq update \
    && apt-get install -y --no-install-recommends g++ \
    && rm -rf /var/lib/apt/lists/*

COPY ./requirements.txt .
RUN pip install --prefix="/reqs" -r requirements.txt

FROM base
WORKDIR /usr/src/app/
COPY --from=builder /reqs /usr/local
COPY ./locustfile.py .
COPY ./people.json .
# python:3.12-slim no longer bundles setuptools, and setuptools >=81 removed
# pkg_resources entirely. opentelemetry-instrumentation packages still
# `from pkg_resources import ...`, so pin to the last version that ships it.
RUN pip install --no-cache-dir 'setuptools<81'
ENTRYPOINT ["locust", "--skip-log-setup"]
