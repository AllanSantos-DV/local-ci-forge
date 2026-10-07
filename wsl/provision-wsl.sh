#!/usr/bin/env bash
# Installs in WSL (Ubuntu) what GitHub's ubuntu-latest ships and workflows use without a setup-* step:
# official Apache Maven, pwsh, gh, zip/unzip, python -> python3, SQLite headers, build tools. Java,
# Node and Python versions come from the workflows' own setup-* steps. Idempotent.
# Usage: provision-wsl.sh [maven-version]
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
MAVEN_VERSION="${1:-3.9.16}"

. /etc/os-release
sudo apt-get update -qq
sudo apt-get install -y -qq ca-certificates curl wget gpg zip unzip build-essential libsqlite3-dev \
  python-is-python3 python3-venv jq >/dev/null

# Official Maven, NOT the apt package: its default maven-compiler-plugin (3.1) compiles as Java 5 and
# JDK 25 refuses it ("Source option 5 is no longer supported"). /usr/local/bin comes before /usr/bin
# in the runners' PATH.
if ! /opt/apache-maven-"$MAVEN_VERSION"/bin/mvn -v >/dev/null 2>&1; then
  base="https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/$MAVEN_VERSION/apache-maven-$MAVEN_VERSION-bin.tar.gz"
  wget -q "$base" -O /tmp/maven.tgz
  echo "$(wget -qO- "$base.sha512" | cut -d' ' -f1)  /tmp/maven.tgz" | sha512sum -c --quiet
  sudo tar -xzf /tmp/maven.tgz -C /opt
  rm /tmp/maven.tgz
fi
sudo ln -sf /opt/apache-maven-"$MAVEN_VERSION"/bin/mvn /usr/local/bin/mvn
sudo apt-get remove -y -qq maven >/dev/null 2>&1 || true

# PowerShell (Microsoft repo): https://learn.microsoft.com/powershell/scripting/install/install-ubuntu
if ! command -v pwsh >/dev/null; then
  wget -q "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" -O /tmp/ms-prod.deb
  sudo dpkg -i /tmp/ms-prod.deb >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq powershell >/dev/null
fi

# GitHub CLI (official repo): https://github.com/cli/cli/blob/trunk/docs/install_linux.md
if ! command -v gh >/dev/null; then
  sudo mkdir -p -m 755 /etc/apt/keyrings
  wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq gh >/dev/null
fi

# Parallel jobs on this one machine run `sudo apt-get update/install` at the same time and the second one
# dies with "Could not get lock /var/lib/apt/lists/lock" (DPkg::Lock::Timeout does not cover that lock).
# This wrapper comes before /usr/bin in sudo's secure_path and queues the calls with flock.
sudo tee /usr/local/sbin/apt-get >/dev/null <<'WRAP'
#!/bin/sh
exec flock /var/lock/local-ci-forge-apt.lock /usr/bin/apt-get "$@"
WRAP
sudo chmod 755 /usr/local/sbin/apt-get

missing=""
for t in git mvn pwsh gh zip unzip gcc python; do
  printf '%-7s ' "$t"; if command -v "$t" >/dev/null; then echo ok; else echo MISSING; missing="$missing $t"; fi
done
printf '%-7s ' docker; command -v docker >/dev/null && echo ok || echo "missing (only needed by jobs with service containers; enable Docker Desktop WSL integration)"
[ -z "$missing" ] || { echo "ERROR: missing tools:$missing"; exit 1; }
sudo -n true 2>/dev/null || echo "WARNING: sudo asks for a password; jobs that run 'sudo apt-get' will hang. Configure NOPASSWD for your user."
