FROM quay.io/skopeo/stable:latest

# Outils nécessaires pour manipuler les tarballs RKE2
RUN dnf install -y wget zstd jq tar && dnf clean all

# Certificat CA self-signed de votre instance GitLab
# Remplacez ca.crt par votre fichier de certificat réel
COPY ca.crt /etc/pki/ca-trust/source/anchors/custom-ca.crt
RUN update-ca-trust extract
