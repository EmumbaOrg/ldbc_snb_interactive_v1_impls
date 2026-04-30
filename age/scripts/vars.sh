cd "$( cd "$( dirname "${BASH_SOURCE[0]:-${(%):-%x}}" )" >/dev/null 2>&1 && pwd )"
cd ..

export AGE_DATABASE_NAME=${AGE_DATABASE_NAME:-ldbcsnb}
export AGE_GRAPH_NAME=${AGE_GRAPH_NAME:-ldbcsnb}
export AGE_HOST=${AGE_HOST:-localhost}
export AGE_PORT=${AGE_PORT:-5432}
export AGE_USER=${AGE_USER:-postgres}
export AGE_PASSWORD=${AGE_PASSWORD:-mysecretpassword}
export AGE_CONNECTION_STRING="postgresql://${AGE_USER}:${AGE_PASSWORD}@${AGE_HOST}:${AGE_PORT}/${AGE_DATABASE_NAME}"

export LDBC_CSV_POSTFIX=_0_0.csv
export LDBC_SF=${LDBC_SF:-1}
