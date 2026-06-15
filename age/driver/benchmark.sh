#!/bin/bash

set -eu
set -o pipefail

cd "$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd ..

BENCHMARK_PROPERTIES_FILE=${1:-driver/benchmark.properties}

java --add-opens java.base/sun.nio.ch=ALL-UNNAMED \
     -cp target/age-1.2.0-SNAPSHOT.jar org.ldbcouncil.snb.driver.Client -P ${BENCHMARK_PROPERTIES_FILE}
