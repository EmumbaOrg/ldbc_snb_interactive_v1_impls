#!/bin/bash
###############################################################################
# setup-vm.sh
# Bootstrap script for setting up a VM to run the LDBC SNB Interactive v1
# Apache AGE benchmark implementation.
#
# Tested on: Ubuntu 22.04 / 24.04 LTS
#
# What this script does:
#   1. Installs system dependencies (git, curl, build-essential)
#   2. Installs OpenJDK 11
#   3. Installs Maven 3.9+
#   4. Builds the common and age Maven packages
#   5. Checks for Python 3.13; installs if not present
#   6. Creates a .venv in the age/ folder using Python 3.13
#   7. Activates the .venv and installs Python dependencies
#   8. Installs PostgreSQL client tools (psql) for index creation scripts
###############################################################################

set -euo pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGE_DIR="${SCRIPT_DIR}/age"
PYTHON_VERSION="3.13"
VENV_DIR="${AGE_DIR}/.venv"

echo "=============================================="
echo " LDBC SNB Interactive v1 - AGE VM Setup"
echo "=============================================="

###############################################################################
# 1. System dependencies
###############################################################################
echo ""
echo "[1/8] Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
  git curl wget build-essential software-properties-common \
  libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
  libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev \
  libffi-dev liblzma-dev

###############################################################################
# 2. Install OpenJDK 11
###############################################################################
echo ""
echo "[2/8] Installing OpenJDK 11..."
if java -version 2>&1 | grep -q "11\." ; then
  echo "  OpenJDK 11 already installed."
else
  sudo apt-get install -y -qq openjdk-11-jdk
  # Set JAVA_HOME if not already set
  export JAVA_HOME="/usr/lib/jvm/java-11-openjdk-amd64"
  echo "export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64" >> ~/.bashrc
  echo "  OpenJDK 11 installed."
fi
java -version

###############################################################################
# 3. Install Maven
###############################################################################
echo ""
echo "[3/8] Installing Maven..."
if command -v mvn &>/dev/null; then
  echo "  Maven already installed: $(mvn --version | head -1)"
else
  sudo apt-get install -y -qq maven
  echo "  Maven installed."
fi
mvn --version | head -1

###############################################################################
# 4. Build common and age packages
###############################################################################
echo ""
echo "[4/8] Building Maven packages (common + age)..."
cd "${SCRIPT_DIR}"

echo "  Building common module..."
mvn install -pl common -am -DskipTests -q

echo "  Building age module..."
cd "${AGE_DIR}"
mvn clean package -DskipTests -q

echo "  Build complete: age/target/age-1.2.0-SNAPSHOT.jar"
cd "${SCRIPT_DIR}"

###############################################################################
# 5. Check / Install Python 3.13
###############################################################################
echo ""
echo "[5/8] Checking Python ${PYTHON_VERSION}..."

PYTHON_BIN=""
# Check if python3.13 is already available
if command -v "python${PYTHON_VERSION}" &>/dev/null; then
  PYTHON_BIN="python${PYTHON_VERSION}"
  echo "  Python ${PYTHON_VERSION} found: $(${PYTHON_BIN} --version)"
else
  echo "  Python ${PYTHON_VERSION} not found. Installing via deadsnakes PPA..."
  sudo add-apt-repository -y ppa:deadsnakes/ppa
  sudo apt-get update -qq
  sudo apt-get install -y -qq "python${PYTHON_VERSION}" "python${PYTHON_VERSION}-venv" "python${PYTHON_VERSION}-dev"
  PYTHON_BIN="python${PYTHON_VERSION}"
  echo "  Python ${PYTHON_VERSION} installed: $(${PYTHON_BIN} --version)"
fi

###############################################################################
# 6. Create .venv in age/ folder
###############################################################################
echo ""
echo "[6/8] Creating Python virtual environment at ${VENV_DIR}..."
if [ -d "${VENV_DIR}" ]; then
  echo "  .venv already exists. Removing and recreating..."
  rm -rf "${VENV_DIR}"
fi
${PYTHON_BIN} -m venv "${VENV_DIR}"
echo "  .venv created."

###############################################################################
# 7. Activate venv and install Python dependencies
###############################################################################
echo ""
echo "[7/8] Activating .venv and installing Python packages..."
source "${VENV_DIR}/bin/activate"

pip install --upgrade pip -q
pip install \
  psycopg2-binary \
  agefreighter \
  -q

echo "  Installed packages:"
pip list --format=columns | grep -E "psycopg2|agefreighter"

###############################################################################
# 8. Install PostgreSQL client tools
###############################################################################
echo ""
echo "[8/8] Installing PostgreSQL client tools (psql)..."
if command -v psql &>/dev/null; then
  echo "  psql already installed: $(psql --version)"
else
  sudo apt-get install -y -qq postgresql-client
  echo "  psql installed."
fi

###############################################################################
# Done
###############################################################################
echo ""
echo "=============================================="
echo " Setup complete!"
echo "=============================================="
echo ""
echo "Summary:"
echo "  Java:    $(java -version 2>&1 | head -1)"
echo "  Maven:   $(mvn --version | head -1)"
echo "  Python:  $(${PYTHON_BIN} --version)"
echo "  venv:    ${VENV_DIR}"
echo "  JAR:     ${AGE_DIR}/target/age-1.2.0-SNAPSHOT.jar"
echo ""
echo "Next steps:"
echo "  1. Ensure PostgreSQL + AGE extension is running"
echo "  2. Activate the venv:  source ${VENV_DIR}/bin/activate"
echo "  3. Load data:          bash age/scripts/load-data.sh --sf 0.1"
echo "  4. Run validation:     See age/README.md"
echo ""
