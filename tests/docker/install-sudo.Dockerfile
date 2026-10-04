# Installer test as a regular user with passwordless sudo (Debian, nothing else).
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends sudo && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash tester && echo 'tester ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/tester
USER tester
ENV SHELL=/bin/bash
WORKDIR /home/tester
