#!/bin/bash
# Generate self-signed TLS serving certificate for openshift-apiserver
set -euo pipefail

CERT_DIR="${1:-.}"

openssl req -x509 -newkey rsa:2048 \
  -keyout "$CERT_DIR/tls.key" \
  -out "$CERT_DIR/tls.crt" \
  -days 365 -nodes \
  -subj "/CN=openshift-apiserver" \
  -addext "subjectAltName=DNS:api.openshift-apiserver.svc,DNS:api.openshift-apiserver.svc.cluster.local,IP:127.0.0.1"

echo "Generated $CERT_DIR/tls.crt and $CERT_DIR/tls.key"
