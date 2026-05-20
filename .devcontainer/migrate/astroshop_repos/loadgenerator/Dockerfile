# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0


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
# LOCUST_PLAYWRIGHT env var removed — locust-plugins no longer bundles trio,
# so the toggle is a no-op and triggered import surprises in older versions.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers
RUN playwright install --with-deps chromium
ENTRYPOINT ["locust", "--skip-log-setup"]
