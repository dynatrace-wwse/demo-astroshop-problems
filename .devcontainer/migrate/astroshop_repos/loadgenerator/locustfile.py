#!/usr/bin/python
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
"""
Workshop loadgen for Astroshop.

Produces traffic that the Dynatrace Site Reliability Guardian
("Astroshop - Staging - Quality gate") can measure: each request
carries a single header

    x-dynatrace-test: LSN=<load-session>;LTN=Astroshop;TSN=<step>;

which the monaco-deployed request-attribute configs
(`init_configs/request-attributes/{LTN,TSN,LSN}.json`) parse with
`extract substring BETWEEN '<NAME>=' AND ';'`. The result lands on
spans as `request_attribute.TSN`, `request_attribute.LTN`,
`request_attribute.LSN`, which the SRG's DQL queries filter on.

Each @task is one of the 12 named test steps the SRG evaluates. The
step naming + the trailing space on `"04 - ad service "` are
load-bearing — they're what the SRG DQL filters look for verbatim.
"""

import json
import os
import random
import logging
import sys

from locust import HttpUser, task, between

from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.jinja2 import Jinja2Instrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry.instrumentation.system_metrics import SystemMetricsInstrumentor
from opentelemetry.instrumentation.urllib3 import URLLib3Instrumentor

# ---------------------------------------------------------------------------
# OpenTelemetry wiring (kept light — server-side spans are captured by
# OneAgent; OTel here only adds client-side spans if a collector is
# reachable from the loadgen pod).
# ---------------------------------------------------------------------------
tracer_provider = TracerProvider()
trace.set_tracer_provider(tracer_provider)
try:
    tracer_provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
except Exception:
    pass  # no collector reachable → drop client spans, keep going

Jinja2Instrumentor().instrument()
RequestsInstrumentor().instrument()
SystemMetricsInstrumentor().instrument()
URLLib3Instrumentor().instrument()

logging.basicConfig(level=logging.INFO, stream=sys.stdout)

# ---------------------------------------------------------------------------
# Static test data
# ---------------------------------------------------------------------------
PRODUCT_IDS = [
    "0PUK6V6EV0", "1YMWWN1N4O", "2ZYFJ3GM2N", "66VCHSJNUP", "6E92ZMYYFZ",
    "9SIQT8TOJO", "L9ECAV7KIM", "LS4PSXUNUM", "OLJCESPC7Z", "HQTGWGPNH4",
]

try:
    with open("people.json") as f:
        PEOPLE = json.load(f)
except Exception:
    PEOPLE = []

import datetime

# LTN identifies the *load test run* — frozen at pod start so every
# request in this run shares a single value and the dashboard
# aggregates them in one bucket. Restart the pod to start a new run.
#
# Shape: "Astroshop Loadtest - CICD Workshop VU(10) Loops(0) - <date>"
TEST_TOOL  = os.environ.get("LTN_TOOL",  "Astroshop Loadtest")
TEST_NAME  = os.environ.get("LTN_NAME",  "CICD Workshop")
TEST_VU    = int(os.environ.get("LOCUST_USERS", "10"))
TEST_LOOPS = 0  # locust runs continuously; 0 = "no fixed iteration count"

_LAUNCH_TS = datetime.datetime.utcnow().strftime("%d %b %Y %H:%M:%S")
LOAD_TEST_NAME = (
    f"{TEST_TOOL} - {TEST_NAME} VU({TEST_VU}) Loops({TEST_LOOPS}) - {_LAUNCH_TS}"
)

LOAD_SESSION_NAME = os.environ.get("LSN", "Astroshop-Staging")

PRODUCT_A = "OLJCESPC7Z"   # National Park Foundation Explorascope
PRODUCT_B = "1YMWWN1N4O"   # any other product


def _ltn_headers(tsn: str) -> dict:
    """One `x-dynatrace-test` header carrying all the load-test fields.

    The monaco-deployed request-attribute extraction rules read this
    header and pull each field out by `<NAME>=...;` substring matching.
    The trailing `;` matters — it's the end-delimiter the extractor
    expects on the *last* field too.

    LTN is pinned at module load so every request in this pod's run
    shares a single load-test identifier — the dashboard buckets all
    of them under one row.
    """
    return {
        "x-dynatrace-test": f"LSN={LOAD_SESSION_NAME};LTN={LOAD_TEST_NAME};TSN={tsn};",
    }


class AstroshopWorkshopUser(HttpUser):
    """One user runs through the 12 SRG-aligned test steps."""

    wait_time = between(0.5, 1.5)

    # ----------------------------------------------------------------
    # The 12 named test steps the SRG evaluates
    # ----------------------------------------------------------------

    @task
    def t01_homepage(self):
        self.client.get("/",
                        headers=_ltn_headers("01 - homepage"),
                        name="01 - homepage")

    @task
    def t02_get_products(self):
        self.client.get("/api/products",
                        headers=_ltn_headers("02 - get products"),
                        name="02 - get products")

    @task
    def t03_get_currencies(self):
        self.client.get("/api/currency",
                        headers=_ltn_headers("03 - get currencies"),
                        name="03 - get currencies")

    @task
    def t04_ad_service(self):
        # Trailing space on the TSN value is intentional — matches the SRG
        # DQL `request_attribute.TSN == "04 - ad service "`.
        self.client.get("/api/data?contextKeys=binoculars",
                        headers=_ltn_headers("04 - ad service "),
                        name="04 - ad service ")

    @task
    def t05_add_product_a(self):
        payload = {
            "item": {"productId": PRODUCT_A, "quantity": 1},
            "userId": "demo-user-a",
        }
        self.client.post("/api/cart",
                         json=payload,
                         headers=_ltn_headers("05 - add product A"),
                         name="05 - add product A")

    @task
    def t06_get_recommendations(self):
        self.client.get("/api/recommendations?productIds=" + PRODUCT_A,
                        headers=_ltn_headers("06 - get recommendations"),
                        name="06 - get recommendations")

    @task
    def t07_get_cart_in_b(self):
        self.client.get("/api/cart?sessionId=cart-B",
                        headers=_ltn_headers("07 - get cart in B"),
                        name="07 - get cart in B")

    @task
    def t08_empty_cart(self):
        self.client.delete("/api/cart",
                           headers=_ltn_headers("08 - empty cart"),
                           name="08 - empty cart")

    @task
    def t09_add_product_b(self):
        payload = {
            "item": {"productId": PRODUCT_B, "quantity": 1},
            "userId": "demo-user-b",
        }
        self.client.post("/api/cart",
                         json=payload,
                         headers=_ltn_headers("09 - add product B"),
                         name="09 - add product B")

    @task
    def t10_get_cart_in_a(self):
        self.client.get("/api/cart?sessionId=cart-A",
                        headers=_ltn_headers("10 - get cart in A"),
                        name="10 - get cart in A")

    @task
    def t11_checkout(self):
        if PEOPLE:
            person = random.choice(PEOPLE)
            addr = person.get("address", {})
            cc = person.get("creditCard", {})
            email = person.get("email", "demo@example.com")
            user  = person.get("userId", "demo-user")
            cur   = person.get("userCurrency", "USD")
        else:
            person, addr, cc = {}, {}, {}
            email, user, cur = "demo@example.com", "demo-user", "USD"

        payload = {
            "userId":       user,
            "userCurrency": cur,
            "email":        email,
            "address": {
                "streetAddress": addr.get("streetAddress", "1600 Amphitheatre Pkwy"),
                "city":          addr.get("city", "Mountain View"),
                "state":         addr.get("state", "CA"),
                "country":       addr.get("country", "United States"),
                "zipCode":       str(addr.get("zipCode", "94043")),
            },
            "creditCard": {
                "creditCardNumber":          str(cc.get("creditCardNumber", "4111111111111111")),
                "creditCardCvv":             int(cc.get("creditCardCvv", 123)),
                "creditCardExpirationYear":  int(cc.get("creditCardExpirationYear", 2030)),
                "creditCardExpirationMonth": int(cc.get("creditCardExpirationMonth", 12)),
            },
        }
        self.client.post("/api/checkout",
                         json=payload,
                         headers=_ltn_headers("11 - checkout"),
                         name="11 - checkout")

    @task
    def t12_get_empty_cart(self):
        self.client.get("/api/cart?sessionId=fresh-" + str(random.randint(1, 1_000_000)),
                        headers=_ltn_headers("12 - get empty cart"),
                        name="12 - get empty cart")
