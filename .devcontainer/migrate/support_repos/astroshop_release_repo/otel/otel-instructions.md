
# Installing the Open Telemtry Collector
## Requirements
Generate Dynatrace Access Tokens
    Dynatrace API token (DT_API_TOKEN)
        openTelemetryTrace.ingest
        metrics.ingest
        logs.ingest


helm repo add jetstack https://charts.jetstack.io --force-update

helm install
cert-manager jetstack/cert-manager
--namespace cert-manager
--create-namespace
--version v1.15.3
--set crds.enabled=true

helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

helm install opentelemetry-operator open-telemetry/opentelemetry-operator --set "manager.collectorImage.repository=hcr.io/dynatrace/dynatrace-otel-collector/dynatrace-otel-collector:0.14.0" --create-namespace --namespace opentelemetry-operator-system --version 0.67.0

helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator --set "manager.collectorImage.repository=ghcr.io/dynatrace/dynatrace-otel-collector/dynatrace-otel-collector" --set "manager.collectorImage.tag=0.14.0" --create-namespace --namespace opentelemetry-operator-system --version 0.70.0


kubectl create secret generic dynatrace-otelcol-dt-api-credentials --from-literal=DT_ENDPOINT=$DT_ENDPOINT --from-literal=DT_API_TOKEN=$DT_API_TOKEN --namespace staging-astroshop

kubectl apply -f otel_collector_gateway.yaml --namespace staging-astroshop

kubectl apply -f otel_k8s_enrichment.yaml


dynatrace-otel-gateway

kubectl delete opentelemetrycollectors.opentelemetry.io --all --grace-period=0 --force

kubectl get opentelemetrycollectors.opentelemetry.io

kubectl get opentelemetrycollectors.opentelemetry.io <resource-name> -o yaml

kubectl patch opentelemetrycollectors.opentelemetry.io dynatrace-otel-gateway -p '{"metadata":{"finalizers":[]}}' --type=merge

kubectl get pods -n opentelemetry-operator-system
kubectl get svc -n opentelemetry-operator-system
kubectl delete -f https://github.com/open-telemetry/opentelemetry-operator/releases/download/v0.14.0/opentelemetry-operator.yaml
hg 