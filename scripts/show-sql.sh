#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

printf 'HTTP check: curl -L http://127.0.0.1:8090\n'
curl --fail --silent --show-error -L http://127.0.0.1:8090
printf '\n\n'

# Keep the password out of the host shell history and screenshot.
DB_CONTAINER=$(sudo docker compose ps -q db)
sudo docker exec -ti "$DB_CONTAINER" sh -c \
  'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --table --verbose \
  -e "show databases; use \`$MYSQL_DATABASE\`; show tables; SELECT * from requests LIMIT 10;"'
