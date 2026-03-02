FROM python:3.12-alpine

# Outils système + Ansible
RUN apk add --no-cache \
      openssh-client \
      sshpass \
      git \
      wget \
      ca-certificates && \
    pip install --no-cache-dir ansible

# Certificat CA self-signed de votre instance GitLab
# Remplacez ca.crt par votre fichier de certificat réel
COPY ca.crt /usr/local/share/ca-certificates/custom-ca.crt
RUN update-ca-certificates
