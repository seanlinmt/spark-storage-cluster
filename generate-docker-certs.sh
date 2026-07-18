#!/bin/bash
set -e

mkdir -p docker-certs
cd docker-certs

echo "Generating CA..."
openssl genrsa -out ca-key.pem 4096
openssl req -new -x509 -days 3650 -key ca-key.pem -sha256 -out ca.pem -subj "/CN=Docker-CA"

echo "Generating Server Cert for ai..."
openssl genrsa -out ai-server-key.pem 4096
openssl req -subj "/CN=ai.clearpixels.org" -sha256 -new -key ai-server-key.pem -out ai-server.csr
cat > extfile-ai.cnf <<EOF
subjectAltName = DNS:ai.clearpixels.org,DNS:ai,IP:192.168.20.63,IP:192.168.177.11,IP:127.0.0.1
extendedKeyUsage = serverAuth
EOF
openssl x509 -req -days 3650 -sha256 -in ai-server.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out ai-server-cert.pem -extfile extfile-ai.cnf

echo "Generating Server Cert for ai2..."
openssl genrsa -out ai2-server-key.pem 4096
openssl req -subj "/CN=ai2.clearpixels.org" -sha256 -new -key ai2-server-key.pem -out ai2-server.csr
cat > extfile-ai2.cnf <<EOF
subjectAltName = DNS:ai2.clearpixels.org,DNS:ai2,IP:192.168.20.229,IP:192.168.177.12,IP:127.0.0.1
extendedKeyUsage = serverAuth
EOF
openssl x509 -req -days 3650 -sha256 -in ai2-server.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out ai2-server-cert.pem -extfile extfile-ai2.cnf

echo "Generating Client Cert..."
openssl genrsa -out client-key.pem 4096
openssl req -subj "/CN=client" -new -key client-key.pem -out client.csr
cat > extfile-client.cnf <<EOF
extendedKeyUsage = clientAuth
EOF
openssl x509 -req -days 3650 -sha256 -in client.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out client-cert.pem -extfile extfile-client.cnf

# Fix permissions
chmod 0400 *-key.pem
chmod 0444 *.pem

echo "Done generating certs."
ls -l
